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
assert_contains "dead" "$body" "12. list marks non-running pid as dead"
rm -f "$STATE/alpha.spawn"

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

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
