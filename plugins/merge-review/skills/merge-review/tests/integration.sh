#!/usr/bin/env bash
# Real-condition test: drives the actual hooks (prompt-hook.py, prepush-hook.py) with real payloads in a
# real repo — exercising baseline stamping and the pre-push gate end to end, exactly as Claude Code would.
set -u
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"          # plugins/merge-review
PROMPT="$PLUGIN/hooks/prompt-hook.py"
PREPUSH="$PLUGIN/hooks/prepush-hook.py"
RV="$PLUGIN/skills/merge-review/scripts/review.py"
PY="$(command -v python3)"
ROOT="$(mktemp -d)"; PASS=0; FAIL=0
. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1   # this suite pins the AUTO lanes; the explicit default is pinned in its own block
export CLAUDE_PLUGIN_ROOT="$PLUGIN"

mkrepo(){ d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q -u origin main 2>/dev/null; }

echo "merge-review · real hooks"

d="$ROOT/repo"; mkrepo "$d"; git -C "$d" checkout -q -b feat
# 1. UserPromptSubmit baseline, then the session does work
echo "{\"cwd\":\"$d\",\"session_id\":\"itest\"}" | CLAUDE_PLUGIN_ROOT="$PLUGIN" "$PY" "$PROMPT"
[ -f "$d/.git/merge-review-session.json" ] && ok "prompt-hook: stamped the session baseline" || ko "prompt-hook baseline"
echo "feature code" >> "$d/app.txt"; git -C "$d" add -A; git -C "$d" commit -qm "feat: add"

PUSH="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push -u origin feat\"},\"cwd\":\"$d\",\"session_id\":\"itest\"}"

# 2. pre-push gate denies the unreviewed push
out=$(echo "$PUSH" | "$PY" "$PREPUSH")
case "$out" in *'"permissionDecision": "deny"'*) ok "prepush-hook: unreviewed push → deny";; *) ko "prepush deny [$out]";; esac
case "$out" in *merge-readiness*) ok "prepush-hook: reason asks for the review";; *) ko "prepush reason";; esac

# 3. same head again → advisory, lets it through (no wall)
[ -z "$(echo "$PUSH" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: second attempt same head → allow" || ko "prepush dedup"

# 4. a recorded passing review clears the gate
"$PY" "$RV" record --repo "$d" --session itest --score 90 --passed >/dev/null
[ -z "$(echo "$PUSH" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: after passing review → allow" || ko "prepush post-record"

# 5. a non-push Bash command is ignored
NB="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"$d\",\"session_id\":\"itest\"}"
[ -z "$(echo "$NB" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: non-push command → ignored" || ko "prepush non-push"

# 6. a non-Bash tool is ignored
NT="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"x\"},\"cwd\":\"$d\",\"session_id\":\"itest\"}"
[ -z "$(echo "$NT" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: non-Bash tool → ignored" || ko "prepush non-bash"

# 7. a session that produced no work is never gated
d2="$ROOT/repo2"; mkrepo "$d2"; git -C "$d2" checkout -q -b feat
echo "{\"cwd\":\"$d2\",\"session_id\":\"itest\"}" | CLAUDE_PLUGIN_ROOT="$PLUGIN" "$PY" "$PROMPT"   # baseline only, no work
P2="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push -u origin feat\"},\"cwd\":\"$d2\",\"session_id\":\"itest\"}"
[ -z "$(echo "$P2" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: no work this session → not gated" || ko "prepush no-work"

# 8. a branch DELETION is never gated, even on an engaged+unreviewed head (a real push there would deny)
d3="$ROOT/repo3"; mkrepo "$d3"; git -C "$d3" checkout -q -b feat
echo "{\"cwd\":\"$d3\",\"session_id\":\"itest\"}" | CLAUDE_PLUGIN_ROOT="$PLUGIN" "$PY" "$PROMPT"
echo w >> "$d3/x.txt"; git -C "$d3" add -A; git -C "$d3" commit -qm w   # engaged, HEAD unreviewed
DEL="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $d3 push origin --delete feat\"},\"cwd\":\"$d3\",\"session_id\":\"itest\"}"
[ -z "$(echo "$DEL" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: branch deletion (--delete) → never gated" || ko "prepush delete"
REAL="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $d3 push -u origin feat\"},\"cwd\":\"$d3\",\"session_id\":\"itest\"}"
case "$(echo "$REAL" | "$PY" "$PREPUSH")" in *deny*) ok "prepush-hook: real push to that head → deny (control)";; *) ko "prepush delete control";; esac

# 9. a non-push git command whose TEXT contains "push" (e.g. a commit message) is NOT gated
CM="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $d3 commit -m 'add pre-push gate'\"},\"cwd\":\"$d3\",\"session_id\":\"itest\"}"
[ -z "$(echo "$CM" | "$PY" "$PREPUSH")" ] && ok "prepush-hook: 'git commit' mentioning push → not gated" || ko "prepush commit-text false-positive"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
