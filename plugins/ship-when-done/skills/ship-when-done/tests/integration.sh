#!/usr/bin/env bash
# Real-condition test: drives the actual Stop hook (hooks/stop-hook.py) with a real Stop payload and a
# real transcript, in a real repo with a bare remote and a stubbed gh. Exercises payload parsing,
# transcript parsing (goal / last message / TodoWrite state), and the full engage→commit→push→draft-PR
# chain — everything except the Claude Code process that runs the command (reproduced identically).
set -u
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"          # plugins/ship-when-done
HOOK="$PLUGIN/hooks/stop-hook.py"
SHIP="$PLUGIN/skills/ship-when-done/scripts/ship.py"
ROOT="$(mktemp -d)"; GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"; PASS=0; FAIL=0
. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1   # this suite pins the AUTO lanes; the explicit default is pinned in its own block

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "pr merge") echo MERGE >> "$GH_LOG"; exit 0;;
  "pr view") echo "no pull requests found" >&2; exit 1;;
  "pr create") echo "https://example.test/pr/1"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh"; export PATH="$ROOT/bin:$PATH"

mkrepo(){ local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init; }

# real transcript: goal + TodoWrite (all completed) + a completion message
tp="$ROOT/transcript.jsonl"
cat > "$tp" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"ZV-77 add a greeting to hello.txt"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"add greeting","status":"completed"},{"content":"verify","status":"completed"}]}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done — added the greeting and verified, all green."}]}}
J

echo "real-condition Stop-hook test"

# 1. opt-in repo: agent did work → the hook drives the whole chain
d="$ROOT/repo"; mkrepo "$d"
git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
git -C "$d" config remote.origin.pushurl "$d.git"                    # real pushes land on the bare repo
git -C "$d" config remote.origin.url https://github.com/test/repo.git  # forge detection reads the fetch URL
git -C "$d" push -q -u origin main 2>/dev/null
git -C "$d" checkout -q -b zv-77-greeting
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
python3 "$SHIP" baseline --repo "$d" --session itest >/dev/null    # UserPromptSubmit: turn-start baseline
echo "hello world" > "$d/hello.txt"            # the "agent" did this (the tree now changes vs baseline)
echo "{\"cwd\":\"$d\",\"session_id\":\"itest\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK"
[ "$(git -C "$d" rev-list --count zv-77-greeting)" -eq 2 ] && ok "hook committed the agent's work" || ko "hook committed the work"
git -C "$d.git" rev-parse --verify -q zv-77-greeting >/dev/null && ok "hook pushed the branch to the remote" || ko "hook pushed the branch"
{ grep -q 'pr create' "$GH_LOG" && grep -q -- '--draft' "$GH_LOG"; } && ok "hook opened a draft PR (gate green + todos + message)" || ko "hook opened a draft PR"
git -C "$d" log -1 --pretty=%B | grep -q 'ZV-77' && ok "commit references the ticket (ZV-77)" || ko "commit references the ticket"
grep -q MERGE "$GH_LOG" && ko "GUARDRAIL: never merged" || ok "GUARDRAIL: never merged"
git -C "$d" diff --quiet && ok "working tree clean after the hook" || ko "working tree clean"

# 2. re-entrance: nested-eval env set → hook is a hard no-op (would otherwise re-commit)
d2="$ROOT/repo2"; mkrepo "$d2"; git -C "$d2" checkout -q -b feat
printf '{}' > "$d2/.ship-when-done.json"; echo x > "$d2/a.txt"; b=$(git -C "$d2" rev-list --count feat)
echo "{\"cwd\":\"$d2\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}" | SHIP_WHEN_DONE_EVAL=1 CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK"
[ "$(git -C "$d2" rev-list --count feat)" -eq "$b" ] && ok "re-entrance env → hook no-op" || ko "re-entrance env → hook no-op"

# 3. work but NO baseline (the session doesn't own this branch) → hook stays silent
d3="$ROOT/repo3"; mkrepo "$d3"; git -C "$d3" checkout -q -b feat
echo x > "$d3/a.txt"; b=$(git -C "$d3" rev-list --count feat)
echo "{\"cwd\":\"$d3\",\"session_id\":\"itest\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK"
[ "$(git -C "$d3" rev-list --count feat)" -eq "$b" ] && ok "not engaged (no baseline) → hook silent" || ko "not engaged → hook silent"

# 4. stop_hook_active set → hook bails immediately (no re-entrancy loop)
echo "{\"cwd\":\"$d3\",\"transcript_path\":\"$tp\",\"stop_hook_active\":true}" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK"
[ "$(git -C "$d3" rev-list --count feat)" -eq "$b" ] && ok "stop_hook_active → hook bails" || ko "stop_hook_active → hook bails"

# 5. GitLab repo, no glab CLI → the hook drives commit + push-with-MR-option (forge resilience, real chain)
PY="$(command -v python3)"; mkdir -p "$ROOT/realbin"
ln -sf "$(command -v git)" "$ROOT/realbin/git"; ln -sf "$(command -v bash)" "$ROOT/realbin/bash"
d5="$ROOT/repo5"; mkrepo "$d5"
git init -q --bare "$d5.git"; git -C "$d5.git" config receive.advertisePushOptions true
git -C "$d5" remote add origin "$d5.git"
git -C "$d5" config remote.origin.pushurl "$d5.git"
git -C "$d5" config remote.origin.url https://gitlab.com/test/repo.git
git -C "$d5" push -q -u origin main 2>/dev/null
git -C "$d5" checkout -q -b zv-77-greeting
printf '{"gate":"true"}' > "$d5/.git/ship-when-done.json"
python3 "$SHIP" baseline --repo "$d5" --session itest >/dev/null
echo "hello world" > "$d5/hello.txt"
out=$(echo "{\"cwd\":\"$d5\",\"session_id\":\"itest\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}" | env PATH="$ROOT/realbin" CLAUDE_PLUGIN_ROOT="$PLUGIN" "$PY" "$HOOK")
[ "$(git -C "$d5" rev-list --count zv-77-greeting)" -eq 2 ] && ok "gitlab: hook committed the work" || ko "gitlab: hook committed"
git -C "$d5.git" rev-parse --verify -q zv-77-greeting >/dev/null && ok "gitlab: hook pushed the branch" || ko "gitlab: hook pushed"
case "$out" in *pr:gitlab-mr*) ok "gitlab: MR requested via push options (no glab)";; *) ko "gitlab: MR via push options — got [$out]";; esac

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
