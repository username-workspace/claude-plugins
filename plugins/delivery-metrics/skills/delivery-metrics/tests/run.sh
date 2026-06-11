#!/usr/bin/env bash
# delivery-metrics test suite — drives collect-metrics.py over throwaway git repos
# with hand-controlled history (fixed authors/dates) and asserts the computed metrics.
set -u
COLLECT="$(cd "$(dirname "$0")/.." && pwd)/scripts/collect-metrics.py"
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }

git_init(){ # $1=dir  [$2=branch, default main]
  local b="${2:-main}"; mkdir -p "$1"; git -C "$1" init -q -b "$b"
  git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false
}
commit_as(){ # $1=dir $2=name $3=email $4=iso-date $5=subject $6=content
  git -C "$1" config user.name "$2"; git -C "$1" config user.email "$3"
  export GIT_AUTHOR_DATE="$4T10:00:00+0000" GIT_COMMITTER_DATE="$4T10:00:00+0000"
  printf '%s\n%s\n' "$6" "$5" > "$1/file.txt"; git -C "$1" add -A; git -C "$1" commit -qm "$5"
}
collect(){ python3 "$COLLECT" "$@" 2>/dev/null; }

# jq-free field reader: get(json, py-expr-on-`o`)
get(){ python3 -c "import json,sys; o=json.load(sys.stdin); print($1)"; }

echo "delivery-metrics tests"

# ─────────────────────────────────────────────────────────────────────────────
# 1. empty repo (unborn HEAD) → no developers, weeks still computed
d="$ROOT/empty"; git_init "$d"
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "{}" "$(printf '%s' "$J" | get "json.dumps(o['developers'])")" "1. empty repo → no developers"
assert_eq "5"  "$(printf '%s' "$J" | get "o['metadata']['weeks']")" "1. empty repo → 5 weeks computed"
assert_eq "0"  "$(printf '%s' "$J" | get "len(o['weekly']['commits'])")" "1. empty repo → empty weekly series"

# ─────────────────────────────────────────────────────────────────────────────
# 2. single commit → counts, lines, ticket, active days, tiny classification
d="$ROOT/single"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 first" "$(seq 1 3)"
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
A="o['developers']['Alice']"
assert_eq "1"   "$(printf '%s' "$J" | get "$A['commits']")"             "2. one commit_main"
assert_eq "1"   "$(printf '%s' "$J" | get "$A['commits_all_branches']")" "2. one commit_all_branches"
assert_eq "4"   "$(printf '%s' "$J" | get "$A['insertions']")"          "2. 4 insertions (3 content + subject line)"
assert_eq "0"   "$(printf '%s' "$J" | get "$A['deletions']")"           "2. 0 deletions"
assert_eq "1"   "$(printf '%s' "$J" | get "$A['tickets']")"             "2. one ticket (ZV-1)"
assert_eq "1"   "$(printf '%s' "$J" | get "$A['active_days']")"         "2. one active day"
assert_eq "1"   "$(printf '%s' "$J" | get "$A['tiny_commits']")"        "2. <5 lines → tiny"
assert_eq "0"   "$(printf '%s' "$J" | get "$A['big_commits']")"         "2. not big"
assert_eq "4.0" "$(printf '%s' "$J" | get "$A['mean_lines_per_commit']")" "2. mean lines/commit = 4"
assert_eq "1.0" "$(printf '%s' "$J" | get "$A['mean_files_per_commit']")" "2. mean files/commit = 1"
assert_eq "."   "$(printf '%s' "$J" | get "$A['primary_repo']")"        "2. primary repo = ."

# ─────────────────────────────────────────────────────────────────────────────
# 3. lines added/removed/churn across an edit (delete + add)
d="$ROOT/churn"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 seed" "$(seq 1 6)"
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-2 rewrite" "$(seq 10 14)"
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "13" "$(printf '%s' "$J" | get "$A['insertions']")" "3. insertions = 7 seed + 6 rewrite"
assert_eq "7"  "$(printf '%s' "$J" | get "$A['deletions']")"  "3. deletions = 7 lines replaced"
assert_eq "2"  "$(printf '%s' "$J" | get "$A['commits']")"    "3. two commits"
assert_eq "10.0" "$(printf '%s' "$J" | get "$A['mean_lines_per_commit']")" "3. churn 20 / 2 commits = 10"

# ─────────────────────────────────────────────────────────────────────────────
# 4. quality signals: fix / revert / no-ticket / big / tiny / fix-ratio across 2 authors
d="$ROOT/signals"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 add feature" "$(seq 1 10)"
commit_as "$d" Alice a@a.a 2026-01-06 "fix login bug"    "$(seq 1 12)"
commit_as "$d" Alice a@a.a 2026-01-07 "no ticket here"   "$(seq 1 14)"
commit_as "$d" Bob   b@b.b 2026-01-08 "Revert ZV-1 add feature" "$(seq 1 5)"
commit_as "$d" Bob   b@b.b 2026-01-09 "ZV-2 hotfix something"    "$(seq 1 1000)"
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
AL="o['developers']['Alice']"; BO="o['developers']['Bob']"
assert_eq "2"    "$(printf '%s' "$J" | get "len(o['developers'])")" "4. two distinct authors"
assert_eq "1"    "$(printf '%s' "$J" | get "$AL['fix_commits']")"       "4. Alice 1 fix commit"
assert_eq "33.3" "$(printf '%s' "$J" | get "$AL['fix_ratio_pct']")"     "4. Alice fix-ratio 1/3"
assert_eq "2"    "$(printf '%s' "$J" | get "$AL['no_ticket_commits']")" "4. Alice 2 no-ticket commits"
assert_eq "0"    "$(printf '%s' "$J" | get "$AL['revert_commits']")"    "4. Alice no reverts"
assert_eq "2"    "$(printf '%s' "$J" | get "$AL['tiny_commits']")"      "4. Alice 2 tiny (small overlapping diffs)"
assert_eq "1"    "$(printf '%s' "$J" | get "$BO['revert_commits']")"    "4. Bob 1 revert"
assert_eq "1"    "$(printf '%s' "$J" | get "$BO['fix_commits']")"       "4. Bob 1 fix (hotfix)"
assert_eq "1"    "$(printf '%s' "$J" | get "$BO['big_commits']")"       "4. Bob 1 big commit (>500)"
assert_eq "0"    "$(printf '%s' "$J" | get "$BO['tiny_commits']")"      "4. Bob revert is 5 lines → NOT tiny (<5 strict)"
assert_eq "50.0" "$(printf '%s' "$J" | get "$BO['fix_ratio_pct']")"     "4. Bob fix-ratio 1/2"
assert_eq "1"    "$(printf '%s' "$J" | get "$BO['tickets']")"           "4. revert does not credit ZV-1 — Bob delivers only ZV-2"
assert_eq "1"    "$(printf '%s' "$J" | get "$BO['tickets_touched_total']")" "4. the reverted ticket is not 'touched' delivery either"
# team total is the UNION of delivered tickets, not the sum of per-dev sets (no double-count)
assert_eq "2"    "$(printf '%s' "$J" | get "o['metadata']['team_tickets_delivered']")" "4. team delivered = {ZV-1 Alice, ZV-2 Bob} = 2"

# ─────────────────────────────────────────────────────────────────────────────
# 4c. a ticket two devs both commit on counts ONCE team-wide (sum would double it)
d="$ROOT/shared"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-9 part one" "$(seq 1 6)"
commit_as "$d" Bob   b@b.b 2026-01-06 "ZV-9 part two" "$(seq 1 6)"
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "1" "$(printf '%s' "$J" | get "o['developers']['Alice']['tickets']")" "4c. Alice delivers ZV-9"
assert_eq "1" "$(printf '%s' "$J" | get "o['developers']['Bob']['tickets']")"   "4c. Bob also commits ZV-9"
assert_eq "1" "$(printf '%s' "$J" | get "o['metadata']['team_tickets_delivered']")" "4c. team total = 1 (union), not 2 (sum)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. merge commits are excluded (--no-merges)
d="$ROOT/merge"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 base" base
git -C "$d" checkout -q -b feat
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-2 feat" feat
git -C "$d" checkout -q main
export GIT_AUTHOR_DATE="2026-01-07T10:00:00+0000" GIT_COMMITTER_DATE="2026-01-07T10:00:00+0000"
git -C "$d" merge -q --no-ff feat -m "Merge branch feat" >/dev/null 2>&1
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "2" "$(printf '%s' "$J" | get "$A['commits']")" "5. merge commit excluded → 2 real commits"

# ─────────────────────────────────────────────────────────────────────────────
# 6. WIP: commit only on a feature branch → counted on all-branches, not main
d="$ROOT/wip"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 base" base
git -C "$d" checkout -q -b feat
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-2 wip work" wip
git -C "$d" checkout -q main
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "1" "$(printf '%s' "$J" | get "$A['commits_main']")"          "6. only base on main"
assert_eq "2" "$(printf '%s' "$J" | get "$A['commits_all_branches']")"  "6. base + wip across branches"
assert_eq "1" "$(printf '%s' "$J" | get "$A['tickets']")"              "6. ZV-1 delivered on main"
assert_eq "1" "$(printf '%s' "$J" | get "$A['tickets_in_progress']")"  "6. ZV-2 in progress (not on main)"
assert_eq "2" "$(printf '%s' "$J" | get "$A['tickets_touched_total']")" "6. both tickets touched"

# ─────────────────────────────────────────────────────────────────────────────
# 7. email canonicalization: one email, two display names → most-frequent wins
d="$ROOT/canon"; git_init "$d"
commit_as "$d" "Jane Doe" jane@x.com 2026-01-05 "ZV-1 a" a
commit_as "$d" "Jane Doe" jane@x.com 2026-01-06 "ZV-2 b" b
commit_as "$d" "jane"     jane@x.com 2026-01-07 "ZV-3 c" c
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq '["Jane Doe"]' "$(printf '%s' "$J" | get "json.dumps(sorted(o['developers']))")" "7. one canonical author"
assert_eq "3" "$(printf '%s' "$J" | get "o['developers']['Jane Doe']['commits']")" "7. all 3 commits merged"

# ─────────────────────────────────────────────────────────────────────────────
# 8. multiple contributors → independent breakdown
d="$ROOT/multi"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 a" a
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-2 b" b
commit_as "$d" Bob   b@b.b 2026-01-07 "ZV-3 c" c
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "2" "$(printf '%s' "$J" | get "o['developers']['Alice']['commits']")" "8. Alice 2 commits"
assert_eq "1" "$(printf '%s' "$J" | get "o['developers']['Bob']['commits']")"   "8. Bob 1 commit"

# ─────────────────────────────────────────────────────────────────────────────
# 9. date-window boundary: commits before/after the window are excluded
d="$ROOT/bound"; git_init "$d"
commit_as "$d" Alice a@a.a 2025-12-20 "ZV-0 before" x
commit_as "$d" Alice a@a.a 2026-01-10 "ZV-1 inside" x
commit_as "$d" Alice a@a.a 2026-01-20 "ZV-2 inside" x
commit_as "$d" Alice a@a.a 2026-02-15 "ZV-3 after"  x
J="$(collect "$d" 2026-01-01 2026-02-01 3m)"
assert_eq "2" "$(printf '%s' "$J" | get "$A['commits']")" "9. only the 2 in-window commits counted"
assert_eq "2" "$(printf '%s' "$J" | get "$A['tickets']")" "9. only in-window tickets"

# ─────────────────────────────────────────────────────────────────────────────
# 10. weekly buckets — Monday-keyed series + the always-empty 'in-progress week' tail
d="$ROOT/weekly"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-1 wk2 a" x   # Tue of week 2026-01-05
commit_as "$d" Alice a@a.a 2026-01-08 "ZV-2 wk2 b" x   # Thu of same week
commit_as "$d" Alice a@a.a 2026-01-13 "ZV-3 wk3"   x   # Tue of week 2026-01-12
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq '["2025-12-29", "2026-01-05", "2026-01-12", "2026-01-19", "2026-01-26"]' \
  "$(printf '%s' "$J" | get "json.dumps(o['weekly']['weeks'])")" "10. five Monday-keyed weeks"
assert_eq '[0, 2, 1, 0, 0]' "$(printf '%s' "$J" | get "json.dumps(o['weekly']['commits']['Alice'])")" "10. weekly commit series"
assert_eq '[0, 2, 1, 0, 0]' "$(printf '%s' "$J" | get "json.dumps(o['weekly']['tickets']['Alice'])")" "10. weekly ticket series"

# ─────────────────────────────────────────────────────────────────────────────
# 11. utilization & velocity derive from active-days / workdays-available
#     window monday_of(2026-01-01)=2025-12-29 .. 2026-01-31 → 25 workdays
d="$ROOT/util"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 a" a
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-2 b" b
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "25.0" "$(printf '%s' "$J" | get "$A['workdays_available']")"          "11. 25 workdays in window"
assert_eq "2"    "$(printf '%s' "$J" | get "$A['active_days']")"                 "11. 2 active days"
assert_eq "8.0"  "$(printf '%s' "$J" | get "$A['utilization_pct']")"             "11. utilization 2/25"
assert_eq "0.08" "$(printf '%s' "$J" | get "$A['velocity_tickets_per_workday']")" "11. velocity 2 tickets / 25 wd"

# ─────────────────────────────────────────────────────────────────────────────
# 12. config (explicit path): alias + custom ticket pattern + holiday + leave
d="$ROOT/cfg"; git_init "$d"
commit_as "$d" Jane jane@x.com 2026-01-05 "PROJ-1 work" a
commit_as "$d" Jane jane@x.com 2026-01-06 "PROJ-2 work" b
commit_as "$d" Bob  b@b.b      2026-01-07 "PROJ-3 work" c
cat > "$ROOT/cfg.json" <<'EOF'
{
  "ticket_pattern": "\\b(PROJ-\\d+)\\b",
  "author_aliases": {"Jane": "Jane Doe"},
  "holidays": ["2026-01-01"],
  "leaves": [{"author": "Jane Doe", "start": "2026-01-12", "end": "2026-01-16", "fraction": 1.0}]
}
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m "$ROOT/cfg.json")"
assert_eq '["Bob", "Jane Doe"]' "$(printf '%s' "$J" | get "json.dumps(sorted(o['developers']))")" "12. alias applied → Jane Doe"
assert_eq "2"    "$(printf '%s' "$J" | get "o['developers']['Jane Doe']['tickets']")"           "12. custom PROJ- pattern matched"
assert_eq "19.0" "$(printf '%s' "$J" | get "o['developers']['Jane Doe']['workdays_available']")" "12. 25 − 1 holiday − 5 leave"
assert_eq "5.0"  "$(printf '%s' "$J" | get "o['developers']['Jane Doe']['leave_days']")"         "12. 5 leave days counted"
assert_eq "24.0" "$(printf '%s' "$J" | get "o['developers']['Bob']['workdays_available']")"      "12. Bob 25 − 1 holiday"
assert_eq "0.0"  "$(printf '%s' "$J" | get "o['developers']['Bob']['leave_days']")"              "12. Bob no leave"
assert_eq "true" "$(printf '%s' "$J" | get "str(o['metadata']['availability']).lower()")"        "12. availability flag set"
assert_eq '["2026-01-01"]' "$(printf '%s' "$J" | get "json.dumps(o['metadata']['holidays'])")"   "12. holiday surfaced in metadata"

# ─────────────────────────────────────────────────────────────────────────────
# 13. partial leave fraction (0.5) → half a workday reclaimed per leave day
d="$ROOT/half"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 a" a
cat > "$ROOT/half.json" <<'EOF'
{ "leaves": [{"author": "Alice", "start": "2026-01-12", "end": "2026-01-16", "fraction": 0.5}] }
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m "$ROOT/half.json")"
assert_eq "22.5" "$(printf '%s' "$J" | get "$A['workdays_available']")" "13. 25 − (5 × 0.5) half-leave"
assert_eq "2.5"  "$(printf '%s' "$J" | get "$A['leave_days']")"         "13. 2.5 leave-days at 0.5 fraction"

# ─────────────────────────────────────────────────────────────────────────────
# 14. config auto-loaded from <root>/.delivery-metrics.json
d="$ROOT/autocfg"; git_init "$d"
commit_as "$d" Jane jane@x.com 2026-01-05 "PROJ-9 work" a
cat > "$d/.delivery-metrics.json" <<'EOF'
{ "ticket_pattern": "\\b(PROJ-\\d+)\\b", "author_aliases": {"Jane": "Jane Doe"} }
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq '["Jane Doe"]' "$(printf '%s' "$J" | get "json.dumps(sorted(o['developers']))")" "14. auto-loaded alias"
assert_eq "1" "$(printf '%s' "$J" | get "o['developers']['Jane Doe']['tickets']")" "14. auto-loaded ticket pattern"

# 14b. SECURITY: availability_command in the AUTO-LOADED repo config is never executed
d="$ROOT/autocmd"; git_init "$d"
commit_as "$d" Jane jane@x.com 2026-01-05 "PROJ-1 work" a
printf '{ "availability_command": "touch pwned; echo {}" }' > "$d/.delivery-metrics.json"
collect "$d" 2026-01-01 2026-01-31 3m >/dev/null
[ ! -f "$d/pwned" ] && ok "14b. auto-loaded availability_command NOT executed (RCE blocked)" || ko "14b. auto-loaded availability_command executed (RCE)"
cat > "$ROOT/avcfg.json" <<'EOF'
{ "availability_command": "printf '{\"holidays\":[\"2026-01-01\"],\"leaves\":[]}'" }
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m "$ROOT/avcfg.json")"
assert_eq '["2026-01-01"]' "$(printf '%s' "$J" | get "json.dumps(o['metadata']['holidays'])")" "14b. explicit-config availability_command still runs"

# ─────────────────────────────────────────────────────────────────────────────
# 15. submodule-workspace mode: detect repos via .gitmodules + aggregate
d="$ROOT/ws"; mkdir -p "$d"
git_init "$d/repoA"; git_init "$d/repoB"
commit_as "$d/repoA" Alice a@a.a 2026-01-05 "ZV-1 in A" a
commit_as "$d/repoB" Alice a@a.a 2026-01-06 "ZV-2 in B" b
commit_as "$d/repoB" Alice a@a.a 2026-01-07 "ZV-3 in B" c
cat > "$d/.gitmodules" <<'EOF'
[submodule "repoA"]
	path = repoA
	url = ./repoA
[submodule "repoB"]
	path = repoB
	url = ./repoB
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq '["repoA", "repoB"]' "$(printf '%s' "$J" | get "json.dumps(o['metadata']['repos'])")" "15. submodules detected"
assert_eq "3"      "$(printf '%s' "$J" | get "$A['commits']")"                  "15. commits aggregated across repos"
assert_eq "repoB"  "$(printf '%s' "$J" | get "$A['primary_repo']")"            "15. primary = repo with most commits"
assert_eq '{"repoA": 1, "repoB": 2}' "$(printf '%s' "$J" | get "json.dumps(dict(sorted($A['repos_touched'].items())))")" "15. per-repo breakdown"

# ─────────────────────────────────────────────────────────────────────────────
# 16. noise_floor → repos_touched_count only counts repos at/above the floor
d="$ROOT/nf"; mkdir -p "$d"
git_init "$d/repoA"; git_init "$d/repoB"
commit_as "$d/repoA" Alice a@a.a 2026-01-05 "ZV-1 a" a
for i in 2 3 4 5 6; do commit_as "$d/repoB" Alice a@a.a "2026-01-0$i" "ZV-$i b" "$i"; done
cat > "$d/.gitmodules" <<'EOF'
[submodule "repoA"]
	path = repoA
	url = ./repoA
[submodule "repoB"]
	path = repoB
	url = ./repoB
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "5" "$(printf '%s' "$J" | get "$A['repos_touched']['repoB']")"     "16. repoB has 5 in-window commits"
assert_eq "1" "$(printf '%s' "$J" | get "$A['repos_touched']['repoA']")"     "16. repoA has 1"
assert_eq "1" "$(printf '%s' "$J" | get "$A['repos_touched_count']")"        "16. only repoB clears noise_floor (5)"

# ─────────────────────────────────────────────────────────────────────────────
# 17. non-main trunk (develop) is the default branch → its commits count as main
d="$ROOT/develop"; git_init "$d" develop
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 on develop" a
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq "1" "$(printf '%s' "$J" | get "$A['commits_main']")" "17. develop trunk counted as main"
assert_eq "0" "$(printf '%s' "$J" | get "$A['tickets_in_progress']")" "17. nothing in progress on trunk"

# ─────────────────────────────────────────────────────────────────────────────
# 18. exclude list is surfaced in metadata but developer is still retained
d="$ROOT/excl"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 a" a
commit_as "$d" "CI Bot" ci@ci.ci 2026-01-06 "ZV-2 b" b
cat > "$ROOT/excl.json" <<'EOF'
{ "exclude": ["CI Bot"] }
EOF
J="$(collect "$d" 2026-01-01 2026-01-31 3m "$ROOT/excl.json")"
assert_eq '["CI Bot"]' "$(printf '%s' "$J" | get "json.dumps(o['metadata']['hidden_from_charts'])")" "18. exclude surfaced in metadata"
assert_eq "1" "$(printf '%s' "$J" | get "int('CI Bot' in o['developers'])")" "18. excluded dev still present in raw developers"

# ─────────────────────────────────────────────────────────────────────────────
# 19. until-clamp: a future 'until' is clamped to the last complete week
d="$ROOT/clamp"; git_init "$d"
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 a" a
J="$(collect "$d" 2026-01-01 2099-12-31 3m)"
EXPECTED_CLAMP="$(python3 - <<'PY'
from datetime import datetime, timedelta
def monday_of(d): return d - timedelta(days=d.weekday())
today = datetime.now().date(); m = monday_of(today)
print((m if today.weekday() <= 4 else m + timedelta(days=7)).isoformat())
PY
)"
assert_eq "$EXPECTED_CLAMP" "$(printf '%s' "$J" | get "o['metadata']['until']")" "19. future until clamped to last complete week"
assert_eq "1" "$(printf '%s' "$J" | get "int(o['metadata']['until'] < '2099-12-31')")" "19. clamp strictly before requested until"

# ─────────────────────────────────────────────────────────────────────────────
# 20. robustness: a non-git root yields valid empty output (no crash, exit 0)
d="$ROOT/notgit"; mkdir -p "$d"
if J="$(collect "$d" 2026-01-01 2026-01-31 3m)"; then
  assert_eq "{}" "$(printf '%s' "$J" | get "json.dumps(o['developers'])")" "20. non-git root → empty developers"
  assert_eq '["."]' "$(printf '%s' "$J" | get "json.dumps(o['metadata']['repos'])")" "20. defaults to ['.']"
else
  ko "20. non-git root → crashed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 21. usage error when called with too few args → exit 1
if python3 "$COLLECT" "$ROOT" 2026-01-01 >/dev/null 2>&1; then
  ko "21. missing args should exit nonzero"
else
  ok "21. missing args → exit 1"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 22. no origin/HEAD + feature checkout → fallback to current branch is WARNED, not silent
# (otherwise WIP commits silently read as delivered)
d="$ROOT/nohead"; git_init "$d" main
commit_as "$d" Alice a@a.a 2026-01-05 "ZV-1 shipped" base
git -C "$d" checkout -q -b feature/wip
commit_as "$d" Alice a@a.a 2026-01-06 "ZV-2 wip" wip   # stays on feature/wip at collect time
err=$(python3 "$COLLECT" "$d" 2026-01-01 2026-01-31 3m 2>&1 >/dev/null)
assert_contains 'no origin/HEAD' "$err" "22. fallback emits a stderr warning"
assert_contains 'WIP as delivered' "$err" "22. warning explains the risk"
J="$(collect "$d" 2026-01-01 2026-01-31 3m)"
assert_eq '["."]' "$(printf '%s' "$J" | get "json.dumps(o['metadata']['default_branch_fallback'])")" "22. fallback recorded in metadata"
# a repo on main (origin/HEAD still absent but current branch IS the trunk) must not warn-as-error,
# but it is still a fallback → also recorded; the warning is informational
d2="$ROOT/onmain"; git_init "$d2" main
commit_as "$d2" Bob b@b.b 2026-01-05 "ZV-3 x" x
err2=$(python3 "$COLLECT" "$d2" 2026-01-01 2026-01-31 3m 2>&1 >/dev/null)
assert_contains 'no origin/HEAD' "$err2" "22. on-main repo without origin/HEAD also warns (current=trunk, still a guess)"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
