#!/usr/bin/env bash
# find-session test suite — exercises query decomposition, cross-match ranking, project-awareness
# and edge cases against a throwaway transcript store (CLAUDE_PROJECTS_DIR), never the real ~/.claude.
set -u
FS="$(cd "$(dirname "$0")/.." && pwd)/scripts/find_session.py"
ROOT="$(mktemp -d)"
PROJECTS="$ROOT/projects"
PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

# the script slugs Path.cwd() (symlinks already resolved) — derive the project dir the same way
slug_of(){ python3 -c "import re; from pathlib import Path; print(re.sub(r'[^a-zA-Z0-9]','-',str(Path.cwd())))"; }
jsonl(){ d="$1"; n="$2"; shift 2; mkdir -p "$d"; : > "$d/$n.jsonl"; for ln in "$@"; do printf '{"text":%s}\n' "\"$ln\"" >> "$d/$n.jsonl"; done; }
firstline(){ printf '%s\n' "$1" | head -1; }
fs(){ env CLAUDE_PROJECTS_DIR="$PROJECTS" python3 "$FS" "$@" 2>&1; }

echo "find-session tests"

# 1. ranking — strong cross-match (more matching lines) beats a weak one
d="$ROOT/work/t1"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" strong "kubernetes deployment ZV-1001" "kubernetes deployment ZV-1001" "kubernetes deployment ZV-1001"
jsonl "$HERE" weak "kubernetes deployment once"
out=$(fs kubernetes deployment)
assert_contains 'Best match: strong' "$out" "1. strongest cross-match ranks first"
assert_contains 'claude --resume strong' "$out" "1. ready resume command for the winner"
assert_contains 'weak' "$out" "1. weaker match listed as a candidate"
rm -rf "$PROJECTS"

# 2. session id + resume command are exactly the file stem (uuid-style)
d="$ROOT/work/t2"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
sid="3f9a1c20-dead-beef-0001-aaaabbbbcccc"
jsonl "$HERE" "$sid" "payment webhook retry logic" "payment webhook retry logic"
out=$(fs payment webhook)
assert_contains "Best match: $sid" "$out" "2. session id is the file stem"
assert_contains "claude --resume $sid" "$out" "2. resume command carries the exact id"
rm -rf "$PROJECTS"

# 3. query decomposition — cross-match: a file missing ANY concept is excluded
d="$ROOT/work/t3"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" both "redis cache invalidation" "redis cache strategy"
jsonl "$HERE" onlyone "redis redis redis" "redis only here"
out=$(fs redis cache)
assert_contains 'Best match: both' "$out" "3. file with all concepts wins"
assert_absent 'onlyone' "$out" "3. file missing a concept is excluded (cross-match)"
rm -rf "$PROJECTS"

# 4. tokenization — one concept as an a|b regex variant matches either spelling
d="$ROOT/work/t4"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" depl "deployment pipeline ran" "deployment pipeline ran"
jsonl "$HERE" rel "release pipeline ran" "release pipeline ran"
out=$(fs 'deploy|release' pipeline)
assert_contains 'depl' "$out" "4. variant concept matches the 'deploy' transcript"
assert_contains 'rel' "$out" "4. variant concept matches the 'release' transcript"
rm -rf "$PROJECTS"

# 5. project-awareness — run from inside a project: only that project's transcripts are scanned
d="$ROOT/work/t5"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" mine "alpha beta gamma" "alpha beta again"
jsonl "$PROJECTS/-some-other-project" bigger "alpha beta x" "alpha beta x" "alpha beta x" "alpha beta x"
out=$(fs alpha beta)
assert_contains 'Best match: mine' "$out" "5. current project wins even though another has more hits"
assert_absent 'bigger' "$out" "5. other project's transcript not scanned from inside a project"
rm -rf "$PROJECTS"

# 6. project-awareness — auto-widen when the current project has no match, banner + project column
d="$ROOT/work/t6"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" unrelated "totally different topic"
jsonl "$PROJECTS/-elsewhere" found "needle haystack" "needle haystack"
out=$(fs needle haystack)
assert_contains 'widened to all projects' "$out" "6. widen banner shown when current project is empty"
assert_contains 'Best match: found' "$out" "6. cross-project match surfaced after widening"
assert_contains 'project -elsewhere' "$out" "6. project column shown once widened"
rm -rf "$PROJECTS"

# 7. --all forces an all-projects scan from inside a matching project
d="$ROOT/work/t7"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" local_hit "widget assembly notes" "widget assembly notes"
jsonl "$PROJECTS/-other" remote_hit "widget assembly notes" "widget assembly notes" "widget assembly notes"
out=$(fs --all widget assembly)
assert_contains 'remote_hit' "$out" "7. --all reaches other projects"
assert_contains 'project' "$out" "7. --all surfaces the project column"
rm -rf "$PROJECTS"

# 8. tie-break — equal total matches, the more recent transcript wins
d="$ROOT/work/t8"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" older "foo bar" "foo bar"
jsonl "$HERE" newer "foo bar" "foo bar"
touch -t 202601010000 "$HERE/older.jsonl"
touch -t 202606080000 "$HERE/newer.jsonl"
out=$(fs foo bar)
assert_eq 'Best match: newer' "$(firstline "$out")" "8. equal totals → newer transcript wins"
rm -rf "$PROJECTS"

# 9. --recent flips the ordering: recency outranks a higher match total
d="$ROOT/work/t9"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" bigolder "foo bar" "foo bar" "foo bar" "foo bar"
jsonl "$HERE" smallnewer "foo bar" "foo bar"
touch -t 202601010000 "$HERE/bigolder.jsonl"
touch -t 202606080000 "$HERE/smallnewer.jsonl"
assert_eq 'Best match: bigolder' "$(firstline "$(fs foo bar)")" "9. default → higher total wins"
assert_eq 'Best match: smallnewer' "$(firstline "$(fs --recent foo bar)")" "9. --recent → recency wins"
rm -rf "$PROJECTS"

# 10. --since cutoff filters out transcripts older than the date
d="$ROOT/work/t10"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" stale "foo bar" "foo bar" "foo bar" "foo bar"
jsonl "$HERE" fresh "foo bar" "foo bar"
touch -t 202601010000 "$HERE/stale.jsonl"
touch -t 202606080000 "$HERE/fresh.jsonl"
out=$(fs --since 2026-06-01 foo bar)
assert_contains 'Best match: fresh' "$out" "10. --since keeps the recent transcript"
assert_absent 'stale' "$out" "10. --since drops transcripts before the cutoff"
rm -rf "$PROJECTS"

# 11. ticket key signal — the most frequent ticket-style token is surfaced
d="$ROOT/work/t11"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" tkt "migrate schema ZV-4242" "more work ZV-4242" "still ZV-4242 and one ABC-1"
out=$(fs migrate schema)
assert_contains 'key ZV-4242 (x3)' "$out" "11. dominant ticket key reported with count"
rm -rf "$PROJECTS"

# 11b. tech tokens (UTF-8, SHA-256, GPT-4) are not ticket keys — real keys still surface
d="$ROOT/work/t11b"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" noisy "encode UTF-8 and SHA-256 digest ZV-7" "GPT-4 prompt UTF-8 encode ZV-7" "UTF-8 digest again"
out=$(fs encode digest)
assert_absent 'key UTF-8' "$out" "11b. UTF-8 is not a ticket key"
assert_absent 'key SHA-256' "$out" "11b. SHA-256 is not a ticket key"
assert_absent 'key GPT-4' "$out" "11b. GPT-4 is not a ticket key"
assert_contains 'key ZV-7 (x2)' "$out" "11b. the real ticket key still dominates"
rm -rf "$PROJECTS"

# 12. no match — all concepts required, none qualifies → friendly message, exit 0
d="$ROOT/work/t12"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" only "needle present here"
out=$(fs needle absentword); rc=$?
assert_contains 'No session matches all of: needle, absentword' "$out" "12. no-match message lists the concepts"
assert_eq 0 "$rc" "12. no match exits 0 (not an error)"
rm -rf "$PROJECTS"

# 13. empty store — project dir exists but holds no transcripts
d="$ROOT/work/t13"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"; mkdir -p "$HERE"
out=$(fs anything); rc=$?
assert_contains 'No session matches all of: anything' "$out" "13. empty store → no-match message"
assert_eq 0 "$rc" "13. empty store exits 0"
rm -rf "$PROJECTS"

# 14. projects root absent entirely → explicit message, exit 1
d="$ROOT/work/t14"; mkdir -p "$d"; cd "$d"
out=$(env CLAUDE_PROJECTS_DIR="$ROOT/nope" python3 "$FS" anything 2>&1); rc=$?
assert_contains 'No Claude Code transcripts found' "$out" "14. missing root → explicit message"
assert_eq 1 "$rc" "14. missing root exits 1"

# 15. malformed transcript — a binary/non-utf8 file is skipped, the good one still wins (not fatal)
d="$ROOT/work/t15"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"; mkdir -p "$HERE"
printf '\x00\x01\xff\xfe garbage not-utf8 \x80\x81\n' > "$HERE/broken.jsonl"
jsonl "$HERE" good "needle haystack found" "needle haystack found"
out=$(fs needle haystack); rc=$?
assert_contains 'Best match: good' "$out" "15. malformed transcript skipped, good one wins"
assert_eq 0 "$rc" "15. malformed transcript is not fatal"
rm -rf "$PROJECTS"

# 16. tie-breaking with comparable matches — both surface, deterministic order, no crash
d="$ROOT/work/t16"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" cand_a "topic one keyword" "topic one keyword"
jsonl "$HERE" cand_b "topic one keyword" "topic one keyword"
touch -t 202606080000 "$HERE/cand_a.jsonl"
touch -t 202606080000 "$HERE/cand_b.jsonl"
out=$(fs topic keyword)
assert_contains 'cand_a' "$out" "16. comparable match A surfaced"
assert_contains 'cand_b' "$out" "16. comparable match B surfaced"
assert_contains 'Other candidates:' "$out" "16. runner-up listed under candidates"
rm -rf "$PROJECTS"

# 17. arg validation — bad --since, no concept, and an invalid regex each exit 2 with a usage error
d="$ROOT/work/t17"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"; jsonl "$HERE" x "foo"
fs --since notadate foo >/dev/null 2>&1; assert_eq 2 "$?" "17. invalid --since → exit 2"
fs >/dev/null 2>&1; assert_eq 2 "$?" "17. no concept → exit 2"
out=$(fs '[unclosed'); assert_contains 'invalid concept pattern' "$out" "17. invalid regex → helpful error"
rm -rf "$PROJECTS"

# 18. cross-project match → the resume command must change directory first: `claude --resume <id>`
# only resolves ids of the project it is launched from, so the bare command fails as-is
d="$ROOT/work/t18"; mkdir -p "$d"; cd "$d"
mkdir -p "$PROJECTS/$(slug_of)"
OTHER="$PROJECTS/-Users-someone-elsewhere-app"; mkdir -p "$OTHER"
printf '{"cwd":"/Users/someone/elsewhere/app","text":"stripe webhook retry saga"}\n{"cwd":"/Users/someone/elsewhere/app","text":"stripe webhook retry saga"}\n' > "$OTHER/3f9a1c20-dead-beef-0018-aaaabbbbcccc.jsonl"
out=$(fs stripe webhook)
assert_contains 'widened to all projects' "$out" "18. match found by widening"
assert_contains "cd /Users/someone/elsewhere/app && claude --resume 3f9a1c20-dead-beef-0018-aaaabbbbcccc" "$out" "18. cross-project resume changes directory first"
HERE="$PROJECTS/$(slug_of)"
jsonl "$HERE" local-one "stripe webhook retry saga" "stripe webhook retry saga" "stripe webhook retry saga"
out=$(fs stripe webhook)
assert_contains 'resume:  claude --resume local-one' "$out" "18. same-project match keeps the bare resume (no cd)"
rm -rf "$PROJECTS"

# 19. perf: the cross-match pre-gate detail-counts only the survivors, not every file scanned
d="$ROOT/work/t19"; mkdir -p "$d"; cd "$d"; HERE="$PROJECTS/$(slug_of)"
for i in $(seq 1 30); do jsonl "$HERE" "noise$i" "totally unrelated chatter line" "more noise"; done
jsonl "$HERE" winner "kubernetes deployment saga" "kubernetes deployment saga"
stats=$(env CLAUDE_PROJECTS_DIR="$PROJECTS" python3 - "$FS" <<'PY'
import importlib.util as u, sys
sp = u.spec_from_file_location("fs", sys.argv[1]); m = u.module_from_spec(sp); sp.loader.exec_module(m)
import re
from pathlib import Path
dirs = m.all_dirs()
m.scan(dirs, [re.compile("kubernetes", re.I), re.compile("deployment", re.I)], "")
print(m.SCAN_STATS["files_seen"], m.SCAN_STATS["files_counted"])
PY
)
assert_eq "31 1" "$stats" "19. pre-gate: 31 files seen, only the 1 cross-match survivor detail-counted"
rm -rf "$PROJECTS"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
