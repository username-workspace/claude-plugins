#!/usr/bin/env bash
# E2E lane entry point — NOT discovered by scripts/run-tests.sh (it talks to a real forge and takes
# minutes). Run it deliberately: before a release, after harness changes, or on a schedule.
#   bash tests/e2e/run.sh [--seed N] [--count N] [--scenario flow:gate:ci]
set -u
command -v gh >/dev/null || { echo "gh CLI required (authenticated on the sandbox forge)"; exit 1; }
exec env -u CLAUDE_PLUGIN_ROOT -u SHIP_WHEN_DONE_EVAL python3 "$(dirname "$0")/e2e.py" "$@"
