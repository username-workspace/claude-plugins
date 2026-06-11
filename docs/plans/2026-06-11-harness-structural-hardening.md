# Harness Structural Hardening — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the harness's structural weaknesses — intent inferred from state deltas, self-review, state-file fragility, gate latency, and the untested turn-boundary gap — replacing each inference rule with an observed fact or an enforced invariant, and deleting the dead code each replacement orphans.

**Architecture:** Five phases, each an independent PR shipped through the harness itself (probe → fix → gate → mark-done → review → push → PR → watcher → merge). Phase 1 hardens the state substrate every other phase builds on (atomic writes, versioned schema, multi-session). Phase 2 replaces engagement inference with event provenance. Phase 3 makes the review gate independent of its author. Phase 4 keeps the Stop-hook gate under its 120 s budget as suites grow. Phase 5 closes the turn-boundary test gap that produced all three real incidents.

**Tech Stack:** stdlib Python 3 + bash + git only (repo rule). macOS/BSD-safe. Hermetic suites pin `CLAUDE_PLUGIN_ROOT`.

---

## Repo conventions that bind every task (from `CLAUDE.md`)

- **Evidence-first**: behaviour changes get a failing probe BEFORE code — `python3 plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py record --cmd '<suite>'` (accepted only if red), fix, `repro.py check` (same probe green), repro stays as a permanent test. One active repro at a time.
- Gate: `bash scripts/run-tests.sh` — all 13 suites green before any commit lands.
- Versions bump together: `plugins/<n>/.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json`. README is generated (`python3 scripts/readme.py`); never hand-edit the table.
- Conventional Commits, never commit on `main`, no AI attribution. Squash-merge with the PR title set BEFORE merging.
- **Ship ritual per phase** (referenced below as "SHIP"): `ship.py mark-done --repo . --summary "<line>" --type <t>` → end turn → Stop hook runs gate + holds push → LOCAL merge-review (`review.py context` / adversarial re-read / `verify` / `record --score N --passed` for the EXACT HEAD) → end turn → push + draft PR → launch `watch.py run` with `run_in_background=true` → on green: set PR title, `gh pr ready`, `gh pr merge --squash --delete-branch`.

## Decisions taken (flag to Benjamin if disagreeing)

1. **Provenance = Edit/Write/NotebookEdit events only.** Bash-generated files (codegen, builds) cannot be attributed reliably; the branch-delta signal stays as the branch-scoped complement. The fragile author-date anchor is DELETED (its job is taken over by provenance ∩ branch-content).
2. **Subagent review is the documented default** in merge-review LOCAL mode; `.git/merge-review.json` `{"inline_review": true}` opts out (offline/cheap runs). Trusted-source-only, like every gate knob.
3. **State schema v1 migrates on first write**; legacy readers are kept ONE minor version, then removed (tracked as a final cleanup task).
4. Phases land in order 1→5; each is independently shippable and useful.

---

# Phase 1 — State substrate v1 (atomic, versioned, multi-session)

**Why:** every plugin's substance is `.git/*.json`. Today: torn writes possible (`json.dump` straight to the file), no schema version (the 1.4.0 work-state hash change had no migration story), and `swd-session.json` holds ONE session — the last baseliner wins, so two concurrent sessions steal each other's engagement. ship's `stamp_sibling` writes INTO merge-review's and mr-watchdog's session files, so the schema change is **lockstep across the three plugins, one PR**.

**Versions:** ship-when-done 1.4.0→1.5.0 · merge-review 1.1.2→1.2.0 · mr-watchdog 2.1.3→2.2.0 (+ proof-of-fix 1.0.0→1.0.1, atomic write only).

### Task 1.1: failing probe — two concurrent sessions must not steal engagement

**Files:** Modify: `plugins/ship-when-done/skills/ship-when-done/tests/run.sh` (after test 11g block)

**Step 1 — write the failing test** (uses existing helpers `new_repo`, `eng`, `ok/ko/assert_eq`):

```bash
# 11i. two concurrent sessions on one repo: each keeps its OWN baseline — the second baseliner
# must not erase the first session's engagement state (multi-session map, not last-writer-wins)
d="$ROOT/t11i"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session SA >/dev/null
echo a > "$d/a.txt"                                   # SA's work
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session SB >/dev/null   # SB arrives, tree already dirty
assert_eq "yes" "$(eng "$d" SA)" "11i. SA still engaged after SB baselined"
assert_eq "no"  "$(eng "$d" SB)" "11i. SB (baselined on the dirty tree) NOT engaged"
```

**Step 2 — record the probe (must fail):**
Run: `python3 plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py record --cmd 'bash plugins/ship-when-done/skills/ship-when-done/tests/run.sh'`
Expected: `✓ failing repro recorded` (SA's baseline was overwritten by SB → SA reads "no").

### Task 1.2: atomic write + v1 session map in ship.py

**Files:** Modify: `plugins/ship-when-done/skills/ship-when-done/scripts/ship.py` (`read_session`/`write_session`/`cmd_baseline`/`engaged`/`stamp_sibling`, ~lines 656–730 + 787–806)

**Step 1 — helpers** (place next to `session_path`):

```python
def write_json(path, data):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


SESSION_GC_DAYS = 7


def read_sessions(repo):
    """v1 multi-session map. A legacy single-session file is migrated in place on first write,
    so a session live across the upgrade keeps its baseline."""
    try:
        st = json.load(open(session_path(repo)))
    except Exception:
        return {"v": 1, "sessions": {}}
    if "v" not in st:
        sid = st.get("session", "")
        return {"v": 1, "sessions": {sid: {"started": st.get("started"), "branches": st.get("branches", {})}}}
    return st


def write_sessions(repo, st):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SESSION_GC_DAYS)).isoformat()
    st["sessions"] = {k: v for k, v in st["sessions"].items() if (v.get("started") or cutoff) >= cutoff}
    try:
        write_json(session_path(repo), st)
    except OSError:
        pass
```

(`timedelta` joins the existing `datetime, timezone` import.)

**Step 2 — rewire `cmd_baseline` and `engaged`** to `st = read_sessions(repo)` / `sess = st["sessions"].setdefault(args.session, {"started": now, "branches": {}})` — same per-branch entries as today, one level deeper. `engaged()` looks up ONLY its own session id; everything else unchanged.

**Step 3 — `stamp_sibling`** (writes `merge-review-session.json` / `mr-watchdog-session.json`): emit the v1 shape — `{"v": 1, "sessions": {sid: {"branches": {branch: entry}}}}` merged into the existing map (read with the same migration rule).

**Step 4 — delete dead code:** the legacy `read_session`/`write_session` pair once no caller remains (`grep -n 'read_session\|write_session' ship.py` must only hit the new names).

### Task 1.3: same schema in merge-review and mr-watchdog

**Files:** Modify: `plugins/merge-review/skills/merge-review/scripts/review.py` (its `baseline`/`engaged`/session IO), `plugins/mr-watchdog/skills/mr-watchdog/scripts/watch.py` (session read). Tests: mirror Task 1.1 in each suite (`tests/run.sh`: two-session case + legacy-migration case).

Legacy-migration test (both suites):

```bash
# legacy single-session file is read as that one session, then upgraded on next write
printf '{"session":"OLD","started":"2026-06-11T00:00:00+00:00","branches":{"feat":{"engaged":true}}}' > "$d/.git/merge-review-session.json"
[ "$("$PY" "$RV" engaged --repo "$d" --session OLD)" = yes ] && ok "legacy file still honoured" || ko "legacy file still honoured"
```

### Task 1.4: prove, gate, ship

- `repro.py check` → green. Full gate green.
- Bump the four versions (plugin.json ×4 + marketplace.json), `python3 scripts/readme.py`.
- Commit: `fix(harness): versioned multi-session state, atomic writes (lockstep schema v1)` — body tells the last-writer-wins hazard honestly. **SHIP**.

---

# Phase 2 — Provenance by events (kills the inference class)

**Why:** all three real incidents came from inferring session intent out of state deltas sampled at turn boundaries. Replace inference with observation: a PostToolUse hook records which paths THIS session actually edited; engagement becomes *"the branch carries paths this session touched"* — branch-scoped AND observed. The author-date anchor (the most permissive rule: it would engage a teammate's freshly-authored branch checked out mid-turn) is deleted.

**Version:** ship-when-done 1.5.0→1.6.0.

### Task 2.1: failing probe — the teammate-branch false positive

**Files:** Modify: `plugins/ship-when-done/skills/ship-when-done/tests/run.sh`

```bash
# 11j. a branch whose recent commits this session merely CHECKED OUT (no file it touched) must
# NOT engage — provenance, not author dates, decides ownership
d="$ROOT/t11j"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S6 >/dev/null
git -C "$d" checkout -q -b teammate
echo t > "$d/their.txt"; git -C "$d" add -A; git -C "$d" commit -qm "teammate work, authored now"
assert_eq "no" "$(eng "$d" S6)" "11j. fresh-authored teammate branch, zero session provenance → NOT engaged"
# 11k. the mid-turn branch DOES engage via provenance (no baseline, no author-date rule)
d="$ROOT/t11k"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S7 >/dev/null
git -C "$d" checkout -q -b feat-midturn
echo x > "$d/mine.txt"; git -C "$d" add -A; git -C "$d" commit -qm work
printf '{"v":1,"sessions":{"S7":{"paths":["mine.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "yes" "$(eng "$d" S7)" "11k. branch carrying session-touched paths → engaged (provenance)"
```

Record probe (red: 11j fails — author-date anchor engages the teammate branch; 11k fails — no provenance reader yet).

### Task 2.2: the PostToolUse hook

**Files:** Create: `plugins/ship-when-done/hooks/posttool-hook.py` · Modify: `plugins/ship-when-done/hooks/hooks.json`

```python
#!/usr/bin/env python3
"""PostToolUse(Edit|Write|NotebookEdit): record the file's repo + path as THIS session's work.
Provenance is observed, never inferred — it is what `engaged` trusts first."""
import json, os, sys

sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "skills", "ship-when-done", "scripts"))
import importlib.util as _u
_sp = _u.spec_from_file_location("ship", os.path.join(sys.path[0], "ship.py"))
ship = _u.module_from_spec(_sp); _sp.loader.exec_module(_sp and ship)

PROVENANCE_CAP = 500

def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    fp = ((payload.get("tool_input") or {}).get("file_path") or "").strip()
    sid = payload.get("session_id") or ""
    if not fp or not sid:
        return
    repo = ship.git_toplevel(os.path.dirname(os.path.abspath(fp)))
    if not repo:
        return
    rel = os.path.relpath(os.path.abspath(fp), repo)
    if rel.startswith(".."):
        return
    p = os.path.join(ship.git_dir(repo), "swd-provenance.json")
    try:
        st = json.load(open(p))
    except Exception:
        st = {"v": 1, "sessions": {}}
    paths = st["sessions"].setdefault(sid, {"paths": []})["paths"]
    if rel not in paths:
        paths.append(rel)
        del paths[:-PROVENANCE_CAP]
        ship.write_json(p, st)

main()
```

`hooks.json`: add a `PostToolUse` entry, matcher `Edit|Write|NotebookEdit`, command `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/posttool-hook.py"`, timeout 5.

### Task 2.3: `engaged()` v2 — provenance ∩ branch content; delete the anchor

**Files:** Modify: `plugins/ship-when-done/skills/ship-when-done/scripts/ship.py` (`engaged`, ~line 693)

```python
def provenance_paths(repo, sid):
    try:
        st = json.load(open(os.path.join(git_dir(repo), "swd-provenance.json")))
    except Exception:
        return set()
    return set((st.get("sessions", {}).get(sid) or {}).get("paths", []))
```

In `engaged()`: keep (a) sibling/ladder stamp, (b) baseline-delta check. REPLACE the whole `started`/rev-list block with:

```python
    prov = provenance_paths(repo, session)
    if prov:
        base, _ = default_branch(repo, remote_name(repo))
        rc, names, _ = run(["git", "diff", "--name-only", f"{base}...HEAD"], repo)
        carried = set(names.splitlines()) | {p for _, p in porcelain_status(repo)}
        if prov & carried:
            st["sessions"].setdefault(session, {}).setdefault("branches", {}).setdefault(branch, {})["engaged"] = True
            write_sessions(repo, st)
            return True
    return False
```

**Dead code to delete with this task:** the author-date anchor block in `engaged()` (the `--since` rev-list), test 11e/11g rewritten onto provenance (the *scenarios* stay — single-turn and mid-turn branches engage — the *mechanism* asserted changes; pre-session guards 11f/11h stay as-is and must still pass). `st["started"]` remains only as the GC key.

### Task 2.4: done-marker per branch (closes the two-branch ambiguity)

**Files:** Modify: `ship.py` `cmd_mark_done` (store `"branch": cur_branch(repo)`) and `read_marker` consumer (ignore + keep the marker when the branch differs). Test: mark-done on `feat-a`, switch to `feat-b`, engage → no PR for `feat-b`, marker intact.

### Task 2.5: prove, gate, ship

`repro.py check` green → full gate → bump 1.6.0 (+marketplace, README) → commit `feat(ship-when-done): event provenance replaces engagement inference (v1.6.0)` → **SHIP**.

---

# Phase 3 — Review integrity (fresh eyes + incremental staleness)

**Why:** LOCAL mode is self-review — the context that wrote the diff scores it. And any new commit voids the whole-branch pass, making long branches O(n²) review cost.

**Version:** merge-review 1.2.0→1.3.0.

### Task 3.1: `context --packet` (self-contained payload for a clean-context subagent)

**Files:** Modify: `plugins/merge-review/skills/merge-review/scripts/review.py` (cmd_context) · Test: `tests/run.sh`

Failing test first:

```bash
out=$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$t" --packet)
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["diff"] and d["commits"] and "threshold" in d and "rubric" in d' \
  && ok "packet: self-contained (diff text + commits + threshold + rubric pointer)" || ko "packet self-contained"
```

Implementation: `--packet` adds the *materialized* diff text (`git diff <base>...HEAD`, capped at 400 KB with an honest `"truncated": true`), commit subjects, prior-pass state, threshold, and the SKILL.md §1–§4 rubric path. The packet is DATA for the subagent — the asymmetric trust note rides inside it.

### Task 3.2: SKILL.md LOCAL flow — review happens in a spawned subagent

**Files:** Modify: `plugins/merge-review/skills/merge-review/SKILL.md` (§0a Bootstrap — Local Mode)

New flow: (1) `context --packet`; (2) spawn a **fresh-context subagent** (Agent tool) whose prompt = packet + rubric and explicitly EXCLUDES this session's reasoning ("you did not write this diff; re-derive everything"); (3) the main session arbitrates contestable findings, applies attested fixes, runs `verify`, `record`. Opt-out: `.git/merge-review.json` `{"inline_review": true}` (trusted sources only — document next to the GATE_FIELDS note). Hermetic tests cover the packet (the model-side flow is covered by the E2E lane, Phase 5).

### Task 3.3: incremental staleness — delta obligation when the passed head is an ancestor

**Files:** Modify: `review.py` (cmd_context, gate reason) · Test first:

```bash
"$PY" "$RV" record --repo "$g" --session s1 --score 90 --passed >/dev/null
echo more > "$g/more.txt"; git -C "$g" add -A; git -C "$g" commit -qm more
case "$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$g")" in
  *'"diff_cmd": "git diff '*'..HEAD"'*) ok "incremental: ancestor pass → delta diff_cmd";; *) ko "incremental delta";; esac
```

Implementation: if `state.passed` and `git merge-base --is-ancestor <state.head> HEAD` → `diff_cmd = git diff <state.head>..HEAD` (else full `base...HEAD` as today). The gate still denies until a NEW record at the current HEAD — only the *obligation* shrinks, never the gate.

### Task 3.4: prove, gate, ship — `feat(merge-review): fresh-eyes subagent review + incremental delta obligation (v1.3.0)`.

---

# Phase 4 — Gate scaling (impacted-suite selection)

**Why:** the full gate (~74 s, growing with every incident test) runs inside a 120 s Stop-hook budget. Crossing it means either timeout noise on every Stop or 2-minute turn-ends.

### Task 4.1: extract a testable selector

**Files:** Create: `scripts/impacted.py` · Test: `tests/harness/run.sh` (new cases)

Failing tests first (pure function, hermetic):

```bash
sel(){ python3 scripts/impacted.py "$@"; }
assert_eq "plugins/find-session" "$(sel plugins/find-session/skills/find-session/scripts/x.py)" "impacted: plugin file → its plugin"
assert_eq "FULL" "$(sel scripts/readme.py)" "impacted: shared script → full run"
assert_eq "FULL" "$(sel .claude-plugin/marketplace.json plugins/find-session/web.json)" "impacted: mixed shared+plugin → full"
assert_eq "plugins/a
plugins/b" "$(sel plugins/a/x plugins/b/y)" "impacted: two plugins → both"
```

```python
#!/usr/bin/env python3
"""stdin/argv: changed paths → the plugin dirs whose suites must run, or FULL.
Conservative by construction: any path outside plugins/<name>/ forces the full gate."""
import re, sys

def impacted(paths):
    plugins = set()
    for p in paths:
        m = re.match(r"plugins/([^/]+)/", p)
        if not m:
            return None
        plugins.add(m.group(1))
    return sorted(plugins) or None

names = impacted([p for p in sys.argv[1:] if p.strip()])
print("FULL" if names is None else "\n".join(f"plugins/{n}" for n in names))
```

### Task 4.2: `run-tests.sh --impacted`

**Files:** Modify: `scripts/run-tests.sh`

`--impacted [<base>]`: changed = `git diff --name-only <base:-main>...HEAD` + `git status --porcelain` paths → `impacted.py` → run only those plugins' suites **plus `tests/harness/run.sh` always** (cross-plugin coupling) ; `FULL` → current behaviour. CI workflow stays on the full run (no workflow change).

Test (in `tests/harness/run.sh`, against a sandbox copy with two stub plugin suites): impacted run executes exactly the touched plugin's run.sh + harness, full fallback on shared paths.

### Task 4.3: switch the local gate

`.git/ship-when-done.json` → `{"gate": "bash scripts/run-tests.sh --impacted"}` (local, never committed — document the recipe in ship's SKILL.md Configure section). Gate, **SHIP**: `feat(scripts): impacted-suite gate selection — full gate stays the CI truth`.

---

# Phase 5 — Turn simulator (closes the gap that produced every incident)

**Why:** hermetic suites idealize turn boundaries; the E2E lane drives CLIs, not turn sequences. All three incidents lived exactly in between.

### Task 5.1: hermetic turn sequencer

**Files:** Create: `tests/harness/turns.sh` (auto-discovered by `run-tests.sh`)

A `turn` helper replays the REAL hook wire-format against throwaway repos, `CLAUDE_PLUGIN_ROOT` pinned:

```bash
SID="turnsim-$$"
prompt(){ printf '{"session_id":"%s","cwd":"%s","prompt":"x"}' "$SID" "$1" | CLAUDE_PLUGIN_ROOT="$SWD_ROOT" python3 "$SWD_ROOT/hooks/prompt-hook.py"; }
posttool(){ printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$SID" "$1" | CLAUDE_PLUGIN_ROOT="$SWD_ROOT" python3 "$SWD_ROOT/hooks/posttool-hook.py"; }
stop(){ printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$1" | CLAUDE_PLUGIN_ROOT="$SWD_ROOT" python3 "$SWD_ROOT/hooks/stop-hook.py"; }
```

Scenarios encoded as turn scripts (each asserts on git state + hook JSON output):
- **T1 single-turn**: prompt → branch+edit+commit (posttool fires) → stop ⇒ engages, commits nothing twice.
- **T2 background writer**: prompt → claim path (`ship.py claim`) → dirty claimed file → stop ⇒ no sweep, no engagement churn; release → stop ⇒ swept.
- **T3 mid-turn branch**: prompt on main → checkout -b + posttool + commit → stop ⇒ engaged via provenance.
- **T4 two sessions**: SA prompt/edit/stop interleaved with SB prompt/stop ⇒ SA ships, SB silent.
- **T5 teammate branch**: prompt → checkout existing branch (no posttool) → stop ⇒ silent no-op.

Each scenario is the permanent regression test for one incident class. (T1–T3 reproduce the three 2026-06-11 incidents end-to-end at the hook level — write T1 RED first against a temporarily reverted `engaged` to validate the rig catches the class, then assert green on current code.)

### Task 5.2: E2E twists

**Files:** Modify: `tests/e2e/e2e.py` (TWISTS) — add `two-sessions` and `bg-writer` twists against the real forge (the bg-writer one replays the original coverage.json incident with a live writer process). Run `bash tests/e2e/run.sh --twists` once, deliberately, before merging (real forge, minutes — excluded from the gate as usual).

### Task 5.3: gate, **SHIP**: `test(harness): turn simulator — the turn-boundary class is now regression-tested`.

---

# Final cleanup task (one PR after Phase 5)

- Delete legacy single-session readers (Phase 1 kept them one minor): drop the `"v" not in st` migration branch from the three plugins; bump patches.
- Dead-symbol audit on every touched script: for each `def`, `grep -n '<name>' <script> tests/` — delete orphans WITH their imports. Known check-list: `ship.py` legacy `read_session`/`write_session` (gone in 1.5.0), the author-date anchor (gone in 1.6.0), any `summarize_changes` helper left unused after provenance.
- `review.py work_state`: align its porcelain hash on the raw-parse helper if (and only if) Phase 1 didn't already — consistency, not behaviour.
- Re-run the full E2E lane (`--fill --twists --projects`) and record the ledger before tagging the marketplace state in the project memory.

## Success criteria (whole plan)

1. The three 2026-06-11 incident scenarios pass as turn-simulator tests T1–T3 — and `engaged()` contains zero date-based rules.
2. Two concurrent sessions on one repo never steal each other's state (11i + T4).
3. A teammate's fresh branch checked out mid-turn never engages (11j + T5).
4. A push is gated by a review whose findings were re-derived in a context that did not write the diff.
5. Stop-hook gate wall-time on a single-plugin change < 30 s; full gate unchanged in CI.
6. Every state file under `.git/` is versioned (`"v": 1`) and written atomically.
