#!/usr/bin/env bash
# Run every plugin test suite (tests/run.sh + tests/integration.sh). Stdlib + git + bash only.
# --impacted [<base>]: run only the suites of plugins touched since <base> (default main) plus the
# cross-plugin harness suite — any changed path outside plugins/<name>/, or any doubt (unknown base,
# failing git), falls back to the FULL run. CI stays on the full run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCOPE="FULL"
if [ "${1:-}" = "--impacted" ]; then
  base="${2:-main}"
  # --no-renames / status.renames=false: a rename must feed BOTH sides — collapsing it would skip the
  # donor plugin's suite. Each lane's exit status is checked on its own: any git failure → FULL.
  if committed="$(git -C "$ROOT" diff --name-only --no-renames "$base...HEAD" 2>/dev/null)" &&
     worktree="$(git -C "$ROOT" -c status.renames=false status --porcelain 2>/dev/null)"; then
    SCOPE="$({ printf '%s\n' "$committed"; printf '%s\n' "$worktree" | cut -c4-; } | python3 "$ROOT/scripts/impacted.py")"
  fi
fi

suites(){
  if [ "$SCOPE" = "FULL" ]; then
    find "$ROOT/plugins" "$ROOT/tests" -type f \( -name run.sh -o -name integration.sh \) -path '*tests*' ! -path '*e2e*' | sort
  else
    { printf '%s\n' "$SCOPE" | while IFS= read -r d; do
        [ -n "$d" ] && [ -d "$ROOT/$d" ] && find "$ROOT/$d" -type f \( -name run.sh -o -name integration.sh \) -path '*tests*' ! -path '*e2e*'
      done
      find "$ROOT/tests" -type f \( -name run.sh -o -name integration.sh \) -path '*tests*' ! -path '*e2e*'; } | sort
  fi
}

[ "$SCOPE" = "FULL" ] || printf 'impacted scope: %s + harness\n' "$(printf '%s' "$SCOPE" | tr '\n' ' ')"
LOG="$(mktemp)"
fail=0
found=0
while IFS= read -r s; do
  found=$((found + 1))
  rel="${s#"$ROOT"/}"
  # </dev/null: the loop's stdin is the suite list — a suite that reads stdin must never eat it
  if env -u CLAUDE_PLUGIN_ROOT -u SHIP_WHEN_DONE_EVAL -u HARNESS_AUTO_ENGAGE bash "$s" >"$LOG" 2>&1 </dev/null; then
    printf '\033[32m✓\033[0m %-64s %s\n' "$rel" "$(grep -oE 'PASS=[0-9]+ FAIL=[0-9]+' "$LOG" | tail -1)"
  else
    printf '\033[31m✗ %s\033[0m\n' "$rel"
    cat "$LOG"
    fail=1
  fi
done < <(suites)
rm -f "$LOG"
[ "$found" -gt 0 ] || { echo "no test suites found"; exit 1; }
echo
[ "$fail" -eq 0 ] && echo "all $found suite(s) green" || echo "FAILURES above"
exit "$fail"
