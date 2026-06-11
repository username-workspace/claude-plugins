#!/usr/bin/env bash
set -u
DRIVER="$(cd "$(dirname "$0")/.." && pwd)/driver.sh"
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

# --- stub claude on PATH ---
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "stubbed-1.0"
exit 0
EOF
chmod +x "$ROOT/bin/claude"
# stub script(1) so spawn never opens a real PTY — record the claude command line it would run
cat > "$ROOT/bin/script" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/script.cap"
exit 0
EOF
chmod +x "$ROOT/bin/script"
export PATH="$ROOT/bin:$PATH"

# --- helpers ---
ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected [$2] to contain [$1]";; esac; }
assert_nonzero(){ [ "$1" -ne 0 ] && ok "$2" || ko "$2 — expected nonzero exit, got 0"; }

# Shared env: point STATE_DIR and CLAUDE_PROJECTS_DIR at isolated temp dirs.
STATE="$ROOT/headless"; mkdir -p "$STATE"
PROJECTS="$ROOT/projects"; mkdir -p "$PROJECTS"

run(){ CRS_CLAUDE_BIN="$ROOT/bin/claude" CRS_HEADLESS_STATE="$STATE" CLAUDE_PROJECTS_DIR="$PROJECTS" \
       bash "$DRIVER" "$@" 2>&1; }
run_rc(){ CRS_CLAUDE_BIN="$ROOT/bin/claude" CRS_HEADLESS_STATE="$STATE" CLAUDE_PROJECTS_DIR="$PROJECTS" \
          bash "$DRIVER" "$@" 2>&1; echo "$?"; }

echo "claude-remote-spawn driver.sh tests"

# 1. syntax
bash -n "$DRIVER" 2>/dev/null
assert_eq 0 "$?" "1. bash -n — script is syntactically valid"

# 2. no args → exit 2 + usage
out=$(run_rc)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 2 "$rc" "2. no args → exit 2"
assert_contains "usage:" "$body" "2. no args → prints usage"

# 3. -h → exit 2 + usage
out=$(run_rc -h)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 2 "$rc" "3. -h → exit 2"
assert_contains "usage:" "$body" "3. -h → prints usage"

# 4. --help → exit 2 + usage
out=$(run_rc --help)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 2 "$rc" "4. --help → exit 2"
assert_contains "usage:" "$body" "4. --help → prints usage"

# 5. unknown subcommand → exit 1 + clear message
out=$(run_rc foobar)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 1 "$rc" "5. unknown subcommand → exit 1"
assert_contains "unknown subcommand" "$body" "5. unknown subcommand → clear error"

# 6. stop with no name → exit 1
out=$(run_rc stop)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 1 "$rc" "6. stop (no name) → exit 1"
assert_contains "stop needs a <name>" "$body" "6. stop (no name) → clear message"

# 7. stop with non-existent session → exit 1
out=$(run_rc stop ghost-session)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 1 "$rc" "7. stop (no such session) → exit 1"
assert_contains "no session ghost-session" "$body" "7. stop (no such session) → clear message"

# 8. resume with no id → exit 1
out=$(run_rc resume)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 1 "$rc" "8. resume (no id) → exit 1"
assert_contains "resume needs a <session-id>" "$body" "8. resume (no id) → clear message"

# 9. resume with unknown flag → exit 1
out=$(run_rc resume --bogus-flag)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 1 "$rc" "9. resume (unknown flag) → exit 1"
assert_contains "unknown flag" "$body" "9. resume (unknown flag) → clear message"

# 10. resume with id but no matching transcript → exit 1
out=$(run_rc resume abc-123-no-such-session)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 1 "$rc" "10. resume (no transcript) → exit 1"
assert_contains "no transcript for session" "$body" "10. resume (no transcript) → clear message"

# 11. list with empty STATE_DIR → "(no sessions)", exit 0
out=$(run_rc list)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 0 "$rc" "11. list (empty) → exit 0"
assert_contains "(no sessions)" "$body" "11. list (empty) → reports no sessions"

# 12. list shows live/dead entries from .spawn files
printf 'name=alpha\ncwd=/tmp\nstarted=2026-01-01T00:00:00Z\nsubshell=99999999\n' > "$STATE/alpha.spawn"
out=$(run_rc list)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 0 "$rc" "12. list (with session) → exit 0"
assert_contains "alpha" "$body" "12. list shows session name"
assert_contains "dead" "$body" "12. list marks a session with no live PTY process as dead"
rm -f "$STATE/alpha.spawn"

# 12b. liveness follows the REAL process, not the (tail-kept-alive) wrapper subshell
( exec -a "remote-control livetest stub" sleep 30 ) & lpid=$!
printf 'name=livetest\ncwd=/tmp\nstarted=x\nsubshell=%s\npgid=%s\n' "$lpid" "$lpid" > "$STATE/livetest.spawn"
sleep 0.3
lt=$(run_rc list); lt="${lt%$'\n'*}"; lt=$(printf '%s\n' "$lt" | grep livetest)
case "$lt" in *live*) ok "12b. a running remote-control process → live";; *) ko "12b. expected live — got [$lt]";; esac
kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
sleep 0.2
lt=$(run_rc list); lt="${lt%$'\n'*}"; lt=$(printf '%s\n' "$lt" | grep livetest)
case "$lt" in *dead*) ok "12b. process gone → dead (no tail-kept-alive false positive)";; *) ko "12b. expected dead — got [$lt]";; esac
rm -f "$STATE/livetest.spawn"

# 13. check → exit 0, reports stub claude version
out=$(run_rc check)
rc="${out##*$'\n'}"
body="${out%$'\n'*}"
assert_eq 0 "$rc" "13. check → exit 0"
assert_contains "claude" "$body" "13. check → reports claude"
assert_contains "script" "$body" "13. check → reports script"
assert_contains "perms" "$body" "13. check → reports perms"

# 14. CRS_HEADLESS_DANGEROUS → PERM reflects --dangerously-skip-permissions
out=$(CRS_CLAUDE_BIN="$ROOT/bin/claude" CRS_HEADLESS_STATE="$STATE" CLAUDE_PROJECTS_DIR="$PROJECTS" \
      CRS_HEADLESS_DANGEROUS=1 bash "$DRIVER" check 2>&1)
assert_contains "dangerously-skip-permissions" "$out" "14. CRS_HEADLESS_DANGEROUS sets perm flag"

# 15. CRS_HEADLESS_PERM_FLAGS="" → PERM is blank (no flag)
out=$(CRS_CLAUDE_BIN="$ROOT/bin/claude" CRS_HEADLESS_STATE="$STATE" CLAUDE_PROJECTS_DIR="$PROJECTS" \
      CRS_HEADLESS_PERM_FLAGS="" bash "$DRIVER" check 2>&1)
perm_line="$(echo "$out" | grep '^perms')"
assert_eq "perms  : " "$perm_line" "15. CRS_HEADLESS_PERM_FLAGS='' → empty perm"

# 16. spawn --model with no value → exit 1 + clear message
out=$(run_rc spawn --model)
rc="${out##*$'\n'}"; body="${out%$'\n'*}"
assert_eq 1 "$rc" "16. spawn --model (no value) → exit 1"
assert_contains "--model needs a value" "$body" "16. spawn --model (no value) → clear message"

# 17. resume <id> --model with no value → exit 1 (flag parsed before transcript lookup)
out=$(run_rc resume someid --model)
rc="${out##*$'\n'}"; body="${out%$'\n'*}"
assert_eq 1 "$rc" "17. resume --model (no value) → exit 1"
assert_contains "--model needs a value" "$body" "17. resume --model (no value) → clear message"

# 18. spawn --model <m> passes '--model <m>' straight to claude, records it, reports it
: > "$ROOT/script.cap"
out=$(run spawn modeltest --model claude-fable-5)
for _ in $(seq 1 50); do [ -s "$ROOT/script.cap" ] && break; sleep 0.1; done   # the launch is backgrounded
assert_contains "modeltest" "$out" "18. spawn --model → returns the handle"
assert_contains "model: claude-fable-5" "$out" "18. spawn --model → reports the model"
assert_contains "--model claude-fable-5" "$(cat "$ROOT/script.cap" 2>/dev/null)" "18. --model passed through to claude"
assert_contains "model=claude-fable-5" "$(cat "$STATE/modeltest.spawn" 2>/dev/null)" "18. model recorded in session state"
# cleanup the backgrounded stdin-keeper so nothing lingers
sp="$(sed -n 's/^subshell=//p' "$STATE/modeltest.spawn" 2>/dev/null | head -1)"
[ -n "$sp" ] && { pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null; }
run stop modeltest >/dev/null 2>&1 || true

# 18b. spawn --prompt '<text>' hands the initial instruction to claude as the trailing positional
: > "$ROOT/script.cap"
out=$(run spawn promptest --prompt "execute the plan, phase by phase")
for _ in $(seq 1 50); do [ -s "$ROOT/script.cap" ] && break; sleep 0.1; done
assert_contains "execute the plan, phase by phase" "$(cat "$ROOT/script.cap" 2>/dev/null)" "18b. --prompt passed through to claude"
sp="$(sed -n 's/^subshell=//p' "$STATE/promptest.spawn" 2>/dev/null | head -1)"
[ -n "$sp" ] && { pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null; }
run stop promptest >/dev/null 2>&1 || true
out=$(run_rc spawn --prompt)
rc="${out##*$'\n'}"; body="${out%$'\n'*}"
assert_eq 1 "$rc" "18b. spawn --prompt (no value) → exit 1"
assert_contains "--prompt needs a value" "$body" "18b. spawn --prompt (no value) → clear message"

# 19. spawn without --model passes NO --model flag (default model)
: > "$ROOT/script.cap"
out=$(run spawn nomodel)
for _ in $(seq 1 50); do [ -s "$ROOT/script.cap" ] && break; sleep 0.1; done
cap="$(cat "$ROOT/script.cap" 2>/dev/null)"
{ [ -n "$cap" ] && case "$cap" in *--model*) false;; *) true;; esac; } && ok "19. no --model flag when omitted (claude default)" || ko "19. no --model when omitted — cap=[$cap]"
sp="$(sed -n 's/^subshell=//p' "$STATE/nomodel.spawn" 2>/dev/null | head -1)"
[ -n "$sp" ] && { pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null; }
run stop nomodel >/dev/null 2>&1 || true

# 20. resume happy path — transcript WITH aiTitle → name recovered from the title
mkdir -p "$PROJECTS/-tmp-proj"
printf '{"cwd":"/tmp","aiTitle": "Fix The Payload Hash"}\n' > "$PROJECTS/-tmp-proj/sess-with-title.jsonl"
: > "$ROOT/script.cap"
out=$(run resume sess-with-title)
for _ in $(seq 1 50); do [ -s "$ROOT/script.cap" ] && break; sleep 0.1; done
assert_contains "fix-the-payload-hash" "$out" "20. resume → handle slugified from aiTitle"
assert_contains "--resume sess-with-title" "$(cat "$ROOT/script.cap" 2>/dev/null)" "20. resume → claude --resume <id>"
assert_contains "--fork-session" "$(cat "$ROOT/script.cap" 2>/dev/null)" "20. resume → forks by default"
sp="$(sed -n 's/^subshell=//p' "$STATE/fix-the-payload-hash.spawn" 2>/dev/null | head -1)"
[ -n "$sp" ] && { pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null; }
run stop fix-the-payload-hash >/dev/null 2>&1 || true

# 21. resume happy path — transcript WITHOUT aiTitle → falls back to a NATO name (regression:
# a grep miss under pipefail used to kill the script before the fallback ran)
printf '{"cwd":"/tmp"}\n' > "$PROJECTS/-tmp-proj/sess-no-title.jsonl"
: > "$ROOT/script.cap"
out=$(run resume sess-no-title); rc=$?
assert_eq 0 "$rc" "21. resume without aiTitle → exit 0 (no pipefail death)"
assert_contains "resumed sess-no-title" "$out" "21. resume without aiTitle → resumes with fallback name"
handle="$(echo "$out" | head -1)"
sp="$(sed -n 's/^subshell=//p' "$STATE/$handle.spawn" 2>/dev/null | head -1)"
[ -n "$sp" ] && { pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null; }
run stop "$handle" >/dev/null 2>&1 || true

# 22. SECURITY: user-supplied name is slugified — no path traversal out of STATE_DIR
out=$(run spawn "../outside/evil")
handle="$(echo "$out" | head -1)"
assert_eq "outside-evil" "$handle" "22. hostile name slugified"
[ ! -e "$ROOT/outside" ] && ok "22. nothing written outside STATE_DIR" || ko "22. path traversal: wrote outside STATE_DIR"
sp="$(sed -n 's/^subshell=//p' "$STATE/$handle.spawn" 2>/dev/null | head -1)"
[ -n "$sp" ] && { pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null; }
run stop "$handle" >/dev/null 2>&1 || true

# 23. stop kills the WHOLE process group — the immortal `tail -f /dev/null` does not leak
: > "$ROOT/script.cap"
out=$(run spawn leaktest)
handle="$(echo "$out" | head -1)"
for _ in $(seq 1 50); do [ -s "$STATE/$handle.spawn" ] && break; sleep 0.1; done
pg="$(sed -n 's/^pgid=//p' "$STATE/$handle.spawn" 2>/dev/null | head -1)"
sleep 0.3
{ [ -n "$pg" ] && pgrep -g "$pg" >/dev/null 2>&1; } && ok "23. spawn → its process group is populated" || ko "23. spawn → process group populated (pg=$pg)"
run stop "$handle" >/dev/null 2>&1 || true
sleep 0.3
pgrep -g "$pg" >/dev/null 2>&1 && ko "23. group survived stop — tail/process leaked" || ok "23. stop kills the whole group (no tail leak)"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
