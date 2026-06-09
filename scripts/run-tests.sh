#!/usr/bin/env bash
# Run every plugin test suite (tests/run.sh + tests/integration.sh). Stdlib + git + bash only.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp)"
fail=0
found=0
while IFS= read -r s; do
  found=$((found + 1))
  rel="${s#"$ROOT"/}"
  if bash "$s" >"$LOG" 2>&1; then
    printf '\033[32m✓\033[0m %-64s %s\n' "$rel" "$(grep -oE 'PASS=[0-9]+ FAIL=[0-9]+' "$LOG" | tail -1)"
  else
    printf '\033[31m✗ %s\033[0m\n' "$rel"
    cat "$LOG"
    fail=1
  fi
done < <(find "$ROOT/plugins" -type f \( -name run.sh -o -name integration.sh \) -path '*/tests/*' | sort)
rm -f "$LOG"
[ "$found" -gt 0 ] || { echo "no test suites found"; exit 1; }
echo
[ "$fail" -eq 0 ] && echo "all $found suite(s) green" || echo "FAILURES above"
exit "$fail"
