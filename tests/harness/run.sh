#!/usr/bin/env bash
# Delivery-harness composition suite — ship-when-done × merge-review × mr-watchdog on real throwaway
# repos, driven through the real hooks. Encodes the end-to-end contract the three plugins promise
# together: single-shot deliveries are reviewed and watched, the gate runs once per work-state, every
# user-facing outcome reaches a rendered channel, and block-continuations advance the pipeline without
# a human prompt (bounded — never an infinite Stop loop).
set -u
ROOT="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIP="$REPO_ROOT/plugins/ship-when-done/skills/ship-when-done/scripts/ship.py"
WATCH="$REPO_ROOT/plugins/mr-watchdog/skills/mr-watchdog/scripts/watch.py"
REVIEW="$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py"
SHIP_HOOK="$REPO_ROOT/plugins/ship-when-done/hooks/stop-hook.py"
SHIP_PLUGIN="$REPO_ROOT/plugins/ship-when-done"
GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1   # this suite pins the AUTO lanes; the explicit default is pinned in its own block

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
key="\$(pwd | tr '/' '_')"
case "\$1 \$2" in
  "pr merge") echo "MERGE-CALLED" >> "$GH_LOG"; exit 0;;
  "pr view") if [ -f "$ROOT/pr-\$key-\$3" ]; then echo '{"state":"OPEN"}'; exit 0; else echo "no pull requests found" >&2; exit 1; fi;;
  "pr checks") echo '[{"bucket":"pending"}]'; exit 0;;
  "pr create")
     head=""; while [ \$# -gt 0 ]; do [ "\$1" = "--head" ] && head="\$2"; shift; done
     [ -n "\$head" ] && touch "$ROOT/pr-\$key-\$head"
     echo "https://example.test/pr/1"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir  [$2=--remote]  [$3=forge-host, default github.com]
  local d="$1" host="${3:-github.com}"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  if [ "${2:-}" = "--remote" ]; then
    git init -q --bare "$d.git"; git -C "$d.git" config receive.advertisePushOptions true
    git -C "$d" remote add origin "$d.git"
    git -C "$d" config remote.origin.pushurl "$d.git"
    git -C "$d" config remote.origin.url "https://$host/test/repo.git"
    git -C "$d" push -q -u origin main 2>/dev/null
  fi
}
stop_payload(){ printf '{"cwd":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$1" "$2" "$3" "$4"; }
prompt_baselines(){ python3 "$SHIP" baseline --repo "$1" --session "$2" >/dev/null
  python3 "$REVIEW" baseline --repo "$1" --session "$2" >/dev/null
  python3 "$WATCH" baseline --repo "$1" --session "$2" >/dev/null; }
pr_creates(){ grep -c 'pr create' "$GH_LOG" || true; }

tp="$ROOT/transcript.jsonl"
cat > "$tp" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"ZV-9 ship the gizmo"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done — gizmo shipped and verified."}]}}
J

echo "delivery-harness composition tests"

# --- 1. B1: the quality gate runs once per work-state, not on every Stop ---------------------------
d="$ROOT/b1"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"gate":"echo run >> %s"}' "$ROOT/gate1.log" > "$d/.git/ship-when-done.json"; : > "$ROOT/gate1.log"
python3 "$SHIP" baseline --repo "$d" --session s1 >/dev/null
echo work > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. first engage with work → gate ran once"
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "1. work committed"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. idle Stops with unchanged work-state → gate NOT re-run"
echo more > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. work-state changed → gate runs again"

# --- 2. B2: single-shot branch-first delivery is held for review (not silently shipped) ------------
d="$ROOT/ss"; new_repo "$d" --remote
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
prompt_baselines "$d" ss
echo gizmo > "$d/gizmo.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "ship the gizmo" --type feat >/dev/null
before=$(pr_creates)
out=$(stop_payload "$d" ss "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$out" "2. single-shot done → Stop blocks with a review request"
assert_contains 'merge-review' "$out" "2. the block asks for the merge-review pass"
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ko "2. nothing pushed before the review" || ok "2. nothing pushed before the review"
assert_eq "$before" "$(pr_creates)" "2. no PR opened before the review"
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "2. the work IS committed (anti-loss)"

# --- 3. B4: after the review pass, the re-entrant Stop ships it (no human prompt needed) ------------
python3 "$REVIEW" record --repo "$d" --score 95 --passed >/dev/null
out2=$(stop_payload "$d" ss "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ok "3. re-entrant Stop pushed the reviewed branch" || ko "3. re-entrant Stop pushed the reviewed branch"
assert_eq "$((before + 1))" "$(pr_creates)" "3. re-entrant Stop opened the PR"
grep -q 'MERGE-CALLED' "$GH_LOG" && ko "3. GUARDRAIL: never merged" || ok "3. GUARDRAIL: never merged"

# --- 4. B2b: the watchdog is handed the MR the pipeline just opened (no Stop-hook race) -------------
assert_contains 'run --repo' "$out2" "4. PR opened → the same Stop hands off the watcher launch"
assert_contains 'run_in_background' "$out2" "4. the launch instruction is the background-watch contract"
assert_eq "yes" "$(python3 "$WATCH" engaged --repo "$d" --session ss)" "4. watchdog engaged on the branch ship pushed"

# --- 5. loop safety: a re-entrant Stop with unchanged state never re-blocks (bounded continuation) --
out3=$(stop_payload "$d" ss "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_absent '"decision": "block"' "$out3" "5. same state again → no second block (no infinite Stop loop)"
assert_eq "$((before + 1))" "$(pr_creates)" "5. no duplicate PR"

# --- 6. loop safety: an unanswered review request is not re-blocked for the same work-state ---------
d6="$ROOT/b6"; new_repo "$d6" --remote
printf '{"gate":"true"}' > "$d6/.git/ship-when-done.json"
prompt_baselines "$d6" s6
echo w > "$d6/w.txt"
python3 "$SHIP" mark-done --repo "$d6" --summary w >/dev/null
o1=$(stop_payload "$d6" s6 "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
o2=$(stop_payload "$d6" s6 "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$o1" "6. first Stop → review block"
assert_absent '"decision": "block"' "$o2" "6. review not done, state unchanged → no re-block"

# --- 7. B3: a no-CLI forge surfaces the PR URL on a rendered channel (systemMessage), not bare stdout
d7="$ROOT/b3"; new_repo "$d7" --remote bitbucket.org; git -C "$d7" checkout -q -b feat
printf '{"gate":"true"}' > "$d7/.git/ship-when-done.json"
python3 "$SHIP" baseline --repo "$d7" --session s7 >/dev/null
echo x > "$d7/x.txt"
python3 "$SHIP" mark-done --repo "$d7" --summary "bb work" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d7" --session s7)
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "systemMessage" in d' 2>/dev/null \
  && ok "7. engage output is hook JSON with a systemMessage" || ko "7. engage output is hook JSON with a systemMessage — got [$out]"
assert_contains 'pull-requests/new' "$out" "7. the bitbucket PR-creation URL is in the rendered message"

# --- 8. visibility: done but NO gate detectable → the withheld PR is said out loud ------------------
d8="$ROOT/nogate"; new_repo "$d8" --remote; git -C "$d8" checkout -q -b feat
python3 "$SHIP" baseline --repo "$d8" --session s8 >/dev/null
echo x > "$d8/x.txt"
python3 "$SHIP" mark-done --repo "$d8" --summary "no gate here" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d8" --session s8)
assert_contains 'no-gate-detected' "$out" "8. no detectable gate → withheld reason names it"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "no-gate" in d.get("systemMessage","")' 2>/dev/null \
  && ok "8. the notice is on the rendered channel" || ko "8. the notice is on the rendered channel — got [$out]"

# --- 9. detect_gate is stack-horizontal, not a JS/PHP allowlist -------------------------------------
gd(){ python3 -c "
import sys, importlib.util as u
sp = u.spec_from_file_location('ship', '$SHIP'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
print(m.detect_gate(sys.argv[1], {'gate': None}) or 'NONE')" "$1"; }
g="$ROOT/g"; mkdir -p "$g/go" "$g/rust" "$g/py" "$g/mk" "$g/yarn" "$g/phpno" "$g/phpyes"
echo 'module t' > "$g/go/go.mod"
echo '[package]' > "$g/rust/Cargo.toml"
printf '[tool.pytest.ini_options]\n' > "$g/py/pyproject.toml"
printf 'test:\n\ttrue\n' > "$g/mk/Makefile"
printf '{"scripts":{"test":"jest"}}' > "$g/yarn/package.json"; : > "$g/yarn/yarn.lock"
printf '{"require":{}}' > "$g/phpno/composer.json"
printf '{"scripts":{"test":"phpunit"}}' > "$g/phpyes/composer.json"
assert_eq "go test ./..." "$(gd "$g/go")" "9. go.mod → go test"
assert_eq "cargo test" "$(gd "$g/rust")" "9. Cargo.toml → cargo test"
assert_contains "pytest" "$(gd "$g/py")" "9. pyproject pytest config → pytest"
assert_eq "make test" "$(gd "$g/mk")" "9. Makefile test target → make test"
assert_eq "yarn test" "$(gd "$g/yarn")" "9. yarn.lock → yarn, not npm"
assert_eq "NONE" "$(gd "$g/phpno")" "9. composer.json without a test script → no blind 'composer test'"
assert_eq "composer test" "$(gd "$g/phpyes")" "9. composer.json with a test script → composer test"

# --- 10. a timed-out gate is transient evidence: distinct reason, never cached ----------------------
d10="$ROOT/b10"; new_repo "$d10" --remote; git -C "$d10" checkout -q -b feat
printf '{"gate":"echo run >> %s; sleep 3","gate_timeout":1}' "$ROOT/gate10.log" > "$d10/.git/ship-when-done.json"; : > "$ROOT/gate10.log"
python3 "$SHIP" baseline --repo "$d10" --session s10 >/dev/null
echo w > "$d10/w.txt"
python3 "$SHIP" mark-done --repo "$d10" --summary w >/dev/null
out=$(python3 "$SHIP" engage --repo "$d10" --session s10)
assert_contains 'gate-timeout' "$out" "10. timed-out gate → distinct visible reason (not gate-not-green)"
python3 "$SHIP" engage --repo "$d10" --session s10 >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10.log" | tr -d ' ')" "10. timeout NOT cached → gate re-runs on the next Stop"

# --- 10b. real usage: a transient red gate self-heals — only GREEN verdicts are cached --------------
d="$ROOT/b10b"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"gate":"echo run >> %s; test -f %s"}' "$ROOT/gate10b.log" "$ROOT/healed" > "$d/.git/ship-when-done.json"
: > "$ROOT/gate10b.log"; rm -f "$ROOT/healed"
python3 "$SHIP" baseline --repo "$d" --session sb >/dev/null
echo w > "$d/w.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "transient" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d" --session sb)
assert_contains 'gate-not-green' "$out" "10b. red gate → PR withheld, visibly"
assert_contains '"verdict": "fail"' "$(cat "$d/.git/swd-gate.json" 2>/dev/null)" "10b. the gate run leaves evidence (verdict persisted)"
touch "$ROOT/healed"
before=$(pr_creates)
python3 "$SHIP" engage --repo "$d" --session sb >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10b.log" | tr -d ' ')" "10b. fail NOT cached → gate re-ran on the idle Stop and healed"
assert_eq "$((before + 1))" "$(pr_creates)" "10b. healed gate → the PR opens without any tree change"
python3 "$SHIP" engage --repo "$d" --session sb >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10b.log" | tr -d ' ')" "10b. green verdict IS cached → no re-run on the next idle Stop"

# --- 11. watchdog handoff survives the forge's check-registration window (silent first answer) ------
d="$ROOT/b11"; new_repo "$d"
cat > "$ROOT/fakewatch.py" <<EOF
import json, os
flag = os.path.join("$ROOT", "b11-second-call")
if os.path.exists(flag):
    print(json.dumps({"decision": "block", "reason": "launch run --repo X with run_in_background"}))
else:
    open(flag, "w").write("x")
EOF
printf '{"session":"s11","script":"%s","branches":{}}' "$ROOT/fakewatch.py" > "$d/.git/mr-watchdog-session.json"
out=$(python3 -c "
import importlib.util as u
sp = u.spec_from_file_location('ship', '$SHIP'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
print(m.watchdog_handoff('$d', 's11') or 'NONE')")
assert_contains 'run_in_background' "$out" "11. silent first answer (checks not registered yet) → retried, nudge captured"

# --- 12. impacted-suite selection: the gate runs only what the diff touches (FULL stays the truth) --
sel(){ python3 "$REPO_ROOT/scripts/impacted.py" "$@"; }
assert_eq "plugins/find-session" "$(sel plugins/find-session/skills/find-session/scripts/x.py)" "12. impacted: plugin file → its plugin"
assert_eq "FULL" "$(sel scripts/readme.py)" "12. impacted: shared script → full run"
assert_eq "FULL" "$(sel .claude-plugin/marketplace.json plugins/find-session/web.json)" "12. impacted: mixed shared+plugin → full"
assert_eq "plugins/a
plugins/b" "$(sel plugins/a/x plugins/b/y)" "12. impacted: two plugins → both"
assert_eq "FULL" "$(sel </dev/null)" "12. impacted: no changed paths → conservative full"
assert_eq "plugins/a" "$(printf 'plugins/a/x\nplugins/a/y\n' | python3 "$REPO_ROOT/scripts/impacted.py")" "12. impacted: stdin paths, deduped"

# sandbox repo: --impacted runs exactly the touched plugin's suite + the harness; shared path → full
sb="$ROOT/sandbox"; mkdir -p "$sb/scripts" "$sb/plugins/a/tests" "$sb/plugins/b/tests" "$sb/tests/harness"
cp "$REPO_ROOT/scripts/run-tests.sh" "$REPO_ROOT/scripts/impacted.py" "$sb/scripts/" 2>/dev/null
RUNLOG="$ROOT/impacted-ran.log"          # outside the sandbox repo — the log must not dirty it
printf '#!/usr/bin/env bash\necho a >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/plugins/a/tests/run.sh"
printf '#!/usr/bin/env bash\necho b >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/plugins/b/tests/run.sh"
printf '#!/usr/bin/env bash\necho h >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/tests/harness/run.sh"
echo lib > "$sb/plugins/a/lib.py"
git -C "$sb" init -q -b main; git -C "$sb" config user.email t@t.t; git -C "$sb" config user.name t; git -C "$sb" config commit.gpgsign false
git -C "$sb" add -A; git -C "$sb" commit -qm init
git -C "$sb" checkout -q -b feat
echo x > "$sb/plugins/a/file.py"; git -C "$sb" add -A; git -C "$sb" commit -qm "touch a"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
h" "$(sort "$RUNLOG")" "12. --impacted: exactly the touched plugin + the harness ran"
echo y > "$sb/scripts/shared.py"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: a dirty shared path forces the FULL run"
rm -f "$sb/scripts/shared.py"
# a broken base ref can never under-select: conservative full
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted no-such-base >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: unknown base → conservative FULL, never under-selects"
# INCIDENT (review): rename collapsing dropped the donor side — both feeds must see old AND new path
git -C "$sb" checkout -q -b mv-cross main
git -C "$sb" mv plugins/a/lib.py plugins/b/lib.py; git -C "$sb" commit -qm "move a→b"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: committed cross-plugin rename runs BOTH sides' suites"
git -C "$sb" checkout -q -b mv-shared main
echo s > "$sb/scripts/util.py"; git -C "$sb" add -A; git -C "$sb" commit -qm "shared util"
git -C "$sb" mv scripts/util.py plugins/b/util.py
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: staged rename OUT of scripts/ → FULL (the donor is shared)"
git -C "$sb" checkout -qf feat 2>/dev/null
# INCIDENT: a suite that reads stdin ate the gate's suite list — every suite sorting after it was
# silently skipped (the gate loop shared its stdin with the suites it ran)
git -C "$sb" checkout -qf main 2>/dev/null
printf '#!/usr/bin/env bash\ncat >/dev/null\necho a >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/plugins/a/tests/run.sh"
git -C "$sb" add -A; git -C "$sb" commit -qm "plugin a suite now slurps stdin"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. a stdin-eating suite can NOT swallow the suites after it"
git -C "$sb" checkout -qf feat 2>/dev/null

# INCIDENT (review): a failing `git status` was masked by the pipeline's exit status → under-selection
mkdir -p "$sb/shim"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = status ] && exit 128; done\nexec "%s" "$@"\n' "$(command -v git)" > "$sb/shim/git"
chmod +x "$sb/shim/git"
: > "$RUNLOG"; env PATH="$sb/shim:$PATH" bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: git status failure → FULL, never a silent under-selection"

# 13. the vendored kernel cannot silently diverge from lib/_kernel.py (the lockstep-patch incident class)
out=$(python3 "$REPO_ROOT/scripts/kernel-sync.py" --check 2>&1) \
  && ok "13. vendored kernel copies in sync with lib/_kernel.py" \
  || ko "13. vendored kernel drifted — $out"

# --- 14. INCIDENT (real usage): a branch created MID-TURN escaped the pre-push gate ------------------
# The session started on a detached HEAD (worktree pattern) so no baseline was ever stamped; the branch
# was created and pushed inside one turn → engaged()=false → two PRs pushed unreviewed. The session's
# work was observable all along in ship-when-done's provenance file: the gate must couple on it.
d="$ROOT/b14"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat
echo gizmo > "$d/g.txt"; echo sp > "$d/café.txt"; git -C "$d" add -A; git -C "$d" commit -qm work
printf '{"v":1,"sessions":{"s14":{"paths":["g.txt"]},"s-q":{"paths":["café.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. no-baseline branch + swd provenance carried by the branch → gate engaged"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s-q)" \
  "14. a carried path git C-quotes (non-ASCII) still intersects"
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s-other)" \
  "14. another session's provenance does not engage this one"
d="$ROOT/b14b"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat
echo x > "$d/x.txt"; git -C "$d" add -A; git -C "$d" commit -qm work
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. absent sibling provenance → inert (a teammate's branch is never gated)"
printf '{"v":1,"sessions":{"s14":{"paths":["other.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. disjoint provenance (prov ∩ carried = ∅) does NOT engage — intersection, not mere presence"
printf 'null' > "$d/.git/swd-provenance.json"
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. wrong-shape provenance (valid JSON, wrong schema) → inert, never a crash"
d="$ROOT/b14c"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat
echo dirty >> "$d/README.md"
echo new > "$d/café-dirty.txt"
printf '{"v":1,"sessions":{"s14":{"paths":["README.md"]},"s-qd":{"paths":["café-dirty.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. worktree-only edit (leading-space porcelain line) is carried evidence too"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s-qd)" \
  "14. untracked non-ASCII path (porcelain C-quotes it) is carried evidence too"

# --- 15. EXPLICIT MODE (the default — HARNESS_AUTO_ENGAGE unset): a DECLARED single-shot delivery
# flows through the whole pipeline exactly like AUTO. The prompt hooks still RECORD (presence files
# the siblings couple on — the review hold, the watcher handoff); engagement itself is never inferred,
# it comes from the mark-done declaration alone.
dE="$ROOT/bexp"; new_repo "$dE" --remote
printf '{"gate":"true"}' > "$dE/.git/ship-when-done.json"
prompt_baselines "$dE" se
echo gizmo > "$dE/gizmo.txt"
python3 "$SHIP" mark-done --repo "$dE" --summary "ship the gizmo" --type feat >/dev/null
beforeE=$(pr_creates)
outE=$(stop_payload "$dE" se "$tp" false | env -u HARNESS_AUTO_ENGAGE CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$outE" "15. declared delivery → Stop blocks for the review (engagement from the declaration alone)"
assert_eq "$beforeE" "$(pr_creates)" "15. no PR before the review"
python3 "$REVIEW" record --repo "$dE" --score 95 --passed >/dev/null
outE2=$(stop_payload "$dE" se "$tp" true | env -u HARNESS_AUTO_ENGAGE CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
git -C "$dE.git" rev-parse --verify -q zv-9-work >/dev/null && ok "15. reviewed → pushed" || ko "15. reviewed → pushed"
assert_eq "$((beforeE + 1))" "$(pr_creates)" "15. PR opened after the review"
assert_eq "yes" "$(env -u HARNESS_AUTO_ENGAGE python3 "$WATCH" engaged --repo "$dE" --session se)" \
  "15. watchdog engaged via ship's handoff stamp — no inference"
dF="$ROOT/bexp2"; new_repo "$dF" --remote; git -C "$dF" checkout -q -b feat
echo w > "$dF/w.txt"; git -C "$dF" add -A; git -C "$dF" commit -qm w
assert_eq "no" "$(env -u HARNESS_AUTO_ENGAGE python3 "$REVIEW" engaged --repo "$dF" --session sf)" \
  "15. no declaration → a manual push is never gated by default"
python3 "$SHIP" mark-done --repo "$dF" --summary w >/dev/null
assert_eq "yes" "$(env -u HARNESS_AUTO_ENGAGE python3 "$REVIEW" engaged --repo "$dF" --session sf)" \
  "15. declared delivery in flight → the pre-push gate arms"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
