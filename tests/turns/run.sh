#!/usr/bin/env bash
# Turn simulator — replays the REAL hook wire-format (UserPromptSubmit → PostToolUse → Stop) against
# throwaway repos, CLAUDE_PLUGIN_ROOT pinned per call. Hermetic suites idealize turn boundaries and
# the E2E lane drives CLIs, not turn sequences; every 2026-06-11 incident lived exactly in between.
# T1–T3 replay those incidents end-to-end at the hook level; T4/T5 pin the multi-session and
# teammate-branch guarantees. Each scenario is the permanent regression test for one incident class.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWD="$REPO_ROOT/plugins/ship-when-done"
SHIP="$SWD/skills/ship-when-done/scripts/ship.py"
ROOT="$(mktemp -d)"; GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"; PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "pr merge") echo "MERGE-CALLED" >> "$GH_LOG"; exit 0;;
  "pr view") echo "no pull requests found" >&2; exit 1;;
  "pr create") echo "https://example.test/pr/1"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir  [$2=--remote]
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  if [ "${2:-}" = "--remote" ]; then
    git init -q --bare "$d.git"
    git -C "$d" remote add origin "$d.git"
    git -C "$d" config remote.origin.pushurl "$d.git"
    git -C "$d" config remote.origin.url "https://github.com/test/repo.git"
    git -C "$d" push -q -u origin main 2>/dev/null
  fi
  printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
}

# the three turn events as the harness delivers them (minus transcript_path — every lane here is
# transcript-independent; the transcript lane is covered by tests/harness and integration.sh)
prompt(){   printf '{"session_id":"%s","cwd":"%s","prompt":"x"}' "$1" "$2" \
  | env -u SHIP_WHEN_DONE_EVAL CLAUDE_PLUGIN_ROOT="$SWD" python3 "$SWD/hooks/prompt-hook.py"; }
posttool(){ printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" \
  | env -u SHIP_WHEN_DONE_EVAL CLAUDE_PLUGIN_ROOT="$SWD" python3 "$SWD/hooks/posttool-hook.py"; }
stop(){     printf '{"session_id":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$2" \
  | env -u SHIP_WHEN_DONE_EVAL CLAUDE_PLUGIN_ROOT="$SWD" python3 "$SWD/hooks/stop-hook.py"; }
count(){ git -C "$1" rev-list --count HEAD 2>/dev/null || echo -1; }

echo "turn-simulator tests"

# --- T1. single-turn delivery (INCIDENT): prompt on main, branch+edit+commit in ONE turn, the branch
# --- is re-baselined clean before the Stop — provenance must still claim it; idle Stops stay no-ops
d="$ROOT/t1"; new_repo "$d" --remote
prompt T1 "$d"
git -C "$d" checkout -q -b feat-t1
echo one > "$d/one.txt"; posttool T1 "$d/one.txt"
git -C "$d" add -A; git -C "$d" commit -qm "one-turn work"
prompt T1 "$d"                                    # next turn: branch first seen already-ahead, clean
stop T1 "$d" >/dev/null
git -C "$d.git" rev-parse --verify -q feat-t1 >/dev/null && ok "T1. one-turn branch shipped (pushed)" || ko "T1. one-turn branch shipped (pushed)"
assert_eq 2 "$(count "$d")" "T1. nothing committed twice (tree was clean)"
stop T1 "$d" >/dev/null
assert_eq 2 "$(count "$d")" "T1. idle Stop → still nothing committed twice"

# --- T2. background writer (INCIDENT): a live writer's claimed file is mid-write at Stop — the
# --- delivery ships around it; after release the next Stop sweeps it
d="$ROOT/t2"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat-t2
prompt T2 "$d"
echo app > "$d/app.txt"; posttool T2 "$d/app.txt"
python3 "$SHIP" claim --repo "$d" --path ledger.json --pid $$ >/dev/null
echo partial > "$d/ledger.json"
stop T2 "$d" >/dev/null
assert_eq 2 "$(count "$d")" "T2. engaged work committed with the writer mid-flight"
case "$(git -C "$d" show --pretty= --name-only HEAD)" in *ledger*) ko "T2. half-written ledger NOT in the commit";; *) ok "T2. half-written ledger NOT in the commit";; esac
case "$(git -C "$d" status --porcelain)" in *ledger*) ok "T2. claimed change stays in the tree";; *) ko "T2. claimed change stays in the tree";; esac
python3 "$SHIP" release --repo "$d" --path ledger.json >/dev/null
stop T2 "$d" >/dev/null
case "$(git -C "$d" show --pretty= --name-only HEAD)" in *ledger*) ok "T2. released file swept on the NEXT Stop";; *) ko "T2. released file swept on the NEXT Stop";; esac

# --- T3. mid-turn branch (INCIDENT): branch created + committed manually mid-turn — the Stop fires
# --- BEFORE the branch has any baseline entry; provenance claims it
d="$ROOT/t3"; new_repo "$d" --remote
prompt T3 "$d"
git -C "$d" checkout -q -b feat-t3
echo mine > "$d/mine.txt"; posttool T3 "$d/mine.txt"
git -C "$d" add -A; git -C "$d" commit -qm "mid-turn work"
stop T3 "$d" >/dev/null
git -C "$d.git" rev-parse --verify -q feat-t3 >/dev/null && ok "T3. unbaselined mid-turn branch shipped via provenance" || ko "T3. unbaselined mid-turn branch shipped via provenance"
assert_eq 2 "$(count "$d")" "T3. no spurious commit"

# --- T4. two sessions on one repo: SB's turn starts on SA's dirty tree — SA ships, SB stays silent
d="$ROOT/t4"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat-t4
prompt SA "$d"
echo sa > "$d/sa.txt"; posttool SA "$d/sa.txt"
prompt SB "$d"
out_b=$(stop SB "$d")
assert_eq 1 "$(count "$d")" "T4. SB's Stop commits nothing (not its work)"
assert_eq "" "$out_b" "T4. SB's Stop is a silent no-op"
stop SA "$d" >/dev/null
assert_eq 2 "$(count "$d")" "T4. SA's Stop ships its work"
git -C "$d.git" rev-parse --verify -q feat-t4 >/dev/null && ok "T4. SA pushed (engagement survived SB's baseline)" || ko "T4. SA pushed (engagement survived SB's baseline)"

# --- T5. teammate branch: freshly-authored commits merely CHECKED OUT mid-turn — silent no-op
d="$ROOT/t5"; new_repo "$d" --remote
git -C "$d" checkout -q -b teammate
echo t > "$d/their.txt"; git -C "$d" add -A; git -C "$d" commit -qm "teammate work, authored now"
git -C "$d" checkout -q main
prompt T5 "$d"
git -C "$d" checkout -q teammate
out=$(stop T5 "$d")
assert_eq "" "$out" "T5. checked-out teammate branch → Stop is a silent no-op"
assert_eq 2 "$(count "$d")" "T5. no commit on the teammate's branch"
git -C "$d.git" rev-parse --verify -q teammate >/dev/null 2>&1 && ko "T5. nothing pushed" || ok "T5. nothing pushed"

# FINAL GUARDRAIL: no scenario may ever auto-merge
case "$(cat "$GH_LOG")" in *MERGE-CALLED*) ko "GUARDRAIL: never auto-merged";; *) ok "GUARDRAIL: never auto-merged";; esac

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
