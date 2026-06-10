#!/usr/bin/env bash
# repro-first test suite — the evidence-first loop on real throwaway git repos, driven through the
# real hooks: record refuses a passing probe, check proves with the same probe, the prompt hook
# nudges once per session on bug-shaped prompts, and the Stop hook re-runs an open repro itself
# (auto-prove on green, bounded block on red).
set -u
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
REPRO="$PLUGIN/skills/repro-first/scripts/repro.py"
PROMPT_HOOK="$PLUGIN/hooks/prompt-hook.py"
STOP_HOOK="$PLUGIN/hooks/stop-hook.py"
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

mkrepo(){ local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init; }
prompt_payload(){ printf '{"cwd":"%s","session_id":"%s","prompt":"%s"}' "$1" "$2" "$3"; }
stop_payload(){ printf '{"cwd":"%s","session_id":"%s"}' "$1" "$2"; }

echo "repro-first tests"

# --- 1. record refuses a probe that passes (a repro must FAIL) -------------------------------------
d="$ROOT/t1"; mkrepo "$d"
out=$(python3 "$REPRO" record --repo "$d" --cmd "true" 2>&1); rc=$?
assert_eq 1 "$rc" "1. passing probe → record refused (exit 1)"
assert_contains 'does not reproduce' "$out" "1. refusal says why"
[ -f "$d/.git/repro-first.json" ] && ko "1. no state written on refusal" || ok "1. no state written on refusal"

# --- 2. record accepts a failing probe; check fails until fixed, passes after ----------------------
out=$(python3 "$REPRO" record --repo "$d" --cmd "test -f fixed.txt" 2>&1); rc=$?
assert_eq 0 "$rc" "2. failing probe → recorded"
assert_contains 'failing repro recorded' "$out" "2. record confirms"
out=$(python3 "$REPRO" check --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "2. unfixed → check fails"
assert_contains 'still failing' "$out" "2. check says still failing"
touch "$d/fixed.txt"
out=$(python3 "$REPRO" check --repo "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "2. fixed → check passes"
assert_contains 'fix proven' "$out" "2. check proves the fix"
assert_contains '"status": "proven"' "$(python3 "$REPRO" status --repo "$d")" "2. status is proven"

# --- 3. prompt hook: bug-shaped prompt nudges once per session, silent otherwise -------------------
d3="$ROOT/t3"; mkrepo "$d3"
out=$(prompt_payload "$d3" s1 "fix the login bug, it crashes on empty email" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "3. bug prompt → protocol injected"
assert_contains 'record --repo' "$out" "3. the injected protocol carries the record command"
out=$(prompt_payload "$d3" s1 "still broken, please fix it again" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "3. same session → no second nudge"
out=$(prompt_payload "$d3" s2 "corrige la régression sur le panier" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "3. new session, french bug prompt → nudges again"
d3b="$ROOT/t3b"; mkrepo "$d3b"
out=$(prompt_payload "$d3b" s1 "add a dark-mode toggle to the settings page" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "3. feature prompt → silent"
out=$(prompt_payload "$ROOT/nogit" s1 "fix the bug" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "3. no git repo → silent"

# --- 4. stop hook: open repro re-run by the hook — block on red, auto-prove on green ----------------
d4="$ROOT/t4"; mkrepo "$d4"
python3 "$REPRO" record --repo "$d4" --cmd "test -f done.txt" >/dev/null 2>&1
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains '"decision": "block"' "$out" "4. open repro still red → Stop blocks"
assert_contains 'check --repo' "$out" "4. the block carries the check command"
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "4. same work-state → no re-block (no Stop loop)"
echo edit > "$d4/work.txt"
touch "$d4/done.txt"
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains 'systemMessage' "$out" "4. work-state changed, probe green → auto-proven"
assert_contains 'fix proven' "$out" "4. the auto-proof is announced"
assert_contains '"status": "proven"' "$(python3 "$REPRO" status --repo "$d4")" "4. state flipped to proven"
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "4. proven repro → Stop silent"

# --- 5. nag cap: an unconverging repro stops blocking after MAX_NAGS attempts -----------------------
d5="$ROOT/t5"; mkrepo "$d5"
python3 "$REPRO" record --repo "$d5" --cmd "false" >/dev/null 2>&1
blocks=0
for i in 1 2 3 4 5 6 7; do
  echo "edit $i" > "$d5/w$i.txt"
  out=$(stop_payload "$d5" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
  case "$out" in *'"decision": "block"'*) blocks=$((blocks+1));; esac
done
assert_eq 5 "$blocks" "5. blocks capped at 5 even across changing work-states"

# --- 6. opt-out, clear, root anchoring --------------------------------------------------------------
d6="$ROOT/t6"; mkrepo "$d6"
printf '{"enabled":false}' > "$d6/.repro-first.json"
out=$(prompt_payload "$d6" s1 "fix the bug" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "6. enabled:false → prompt hook silent"
rm "$d6/.repro-first.json"
python3 "$REPRO" record --repo "$d6" --cmd "false" >/dev/null 2>&1
printf '{"enabled":false}' > "$d6/.repro-first.json"
out=$(stop_payload "$d6" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "6. enabled:false → stop hook silent"
python3 "$REPRO" clear --repo "$d6" >/dev/null
[ -f "$d6/.git/repro-first.json" ] && ko "6. clear removes the state" || ok "6. clear removes the state"
d7="$ROOT/t7"; mkrepo "$d7"; mkdir -p "$d7/src/deep"
python3 "$REPRO" record --repo "$d7/src/deep" --cmd "false" >/dev/null 2>&1
[ -f "$d7/.git/repro-first.json" ] && ok "6. root-anchor: record from subdir → state at repo root" || ko "6. root-anchor subdir"

# --- 7. check without a recorded repro --------------------------------------------------------------
d8="$ROOT/t8"; mkrepo "$d8"
out=$(python3 "$REPRO" check --repo "$d8" 2>&1); rc=$?
assert_eq 1 "$rc" "7. check without record → fails"
assert_contains 'no recorded repro' "$out" "7. and says why"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
