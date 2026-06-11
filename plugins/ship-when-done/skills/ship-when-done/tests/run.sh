#!/usr/bin/env bash
# ship-when-done test suite — exercises the ladder + guardrails on real throwaway git repos.
# A stubbed `gh` records calls (and flags any `pr merge`); a bare repo acts as the remote.
set -u
SHIP="$(cd "$(dirname "$0")/.." && pwd)/scripts/ship.py"
ROOT="$(mktemp -d)"
GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"
PASS=0; FAIL=0
# mark a repo engaged (as if this session produced the work) so the ladder tests run; the engagement
# DETECTION itself (baseline → work) is exercised separately in test 11b.
arm(){ printf '{"v":1,"sessions":{"":{"branches":{"feat":{"engaged":true}}}}}' > "$1/.git/swd-session.json"; }

# --- stub gh on PATH ---
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
key="\$(pwd | tr '/' '_')"
case "\$1 \$2" in
  "pr merge") echo "MERGE-CALLED \$@" >> "$GH_LOG"; exit 0;;
  "pr view") if [ -f "$ROOT/pr-\$key-\$3" ]; then echo '{"state":"OPEN"}'; exit 0; else echo "no pull requests found" >&2; exit 1; fi;;
  "pr create")
     head=""; while [ \$# -gt 0 ]; do [ "\$1" = "--head" ] && head="\$2"; shift; done
     [ -n "\$head" ] && touch "$ROOT/pr-\$key-\$head"
     echo "https://example.test/pr/1"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

new_repo(){ # $1=dir  [$2=--remote]  [$3=forge-host, default github.com]
  local d="$1" host="${3:-github.com}"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  if [ "${2:-}" = "--remote" ]; then
    git init -q --bare "$d.git"; git -C "$d.git" config receive.advertisePushOptions true
    git -C "$d" remote add origin "$d.git"
    git -C "$d" config remote.origin.pushurl "$d.git"            # real pushes land on the bare repo
    git -C "$d" config remote.origin.url "https://$host/test/repo.git"   # forge detection reads the fetch URL
    git -C "$d" push -q -u origin main 2>/dev/null
  fi
}
ladder(){ python3 "$SHIP" ladder --repo "$1" --verdict "$2" --gate "$3" ${4:+--goal "$4"} ${5:+--config "$5"} 2>&1; }

# scoped PATHs so forge-CLI presence is deterministic regardless of the host machine
PY="$(command -v python3)"
mkdir -p "$ROOT/realbin"; ln -sf "$(command -v git)" "$ROOT/realbin/git"; ln -sf "$(command -v bash)" "$ROOT/realbin/bash"
GLAB_LOG="$ROOT/glab.log"; : > "$GLAB_LOG"; mkdir -p "$ROOT/glabbin"
cat > "$ROOT/glabbin/glab" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GLAB_LOG"
[ "\$1 \$2" = "mr create" ] && { echo "https://gitlab.test/mr/1"; exit 0; }
exit 0
EOF
chmod +x "$ROOT/glabbin/glab"
forge_ladder(){ env PATH="$2" "$PY" "$SHIP" ladder --repo "$1" --verdict '{"done":true,"summary":"add a"}' --gate pass 2>&1; }
count(){ git -C "$1" rev-list --count "$2" 2>/dev/null || echo -1; }

echo "ship-when-done tests"

# 1. nothing in flight → skip
d="$ROOT/t1"; new_repo "$d"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'nothing-in-flight' "$out" "1. clean repo → skipped"
assert_eq 1 "$(count "$d" HEAD)" "1. no commit made"

# 2. partial on feature branch + remote → commit + push, NO pr
d="$ROOT/t2"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"; before=$(wc -l < "$GH_LOG")
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'commit' "$out" "2. partial → commit"
assert_contains 'push' "$out" "2. partial → push"
assert_eq 2 "$(count "$d" HEAD)" "2. one new commit"
assert_eq "$before" "$(wc -l < "$GH_LOG")" "2. gh NOT called (no PR on partial)"
git -C "$d.git" rev-parse --verify -q feat >/dev/null && ok "2. branch pushed to remote" || ko "2. branch pushed to remote"

# 3. done + gate pass + remote → commit + push + DRAFT pr
d="$ROOT/t3"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":true,"summary":"add a"}' pass)
assert_contains 'pr:draft-pr' "$out" "3. done+green → draft PR"
last=$(tail -1 "$GH_LOG")
assert_contains 'pr create' "$last" "3. gh pr create called"
assert_contains '--draft' "$last" "3. PR is a draft"

# 4. done but gate FAIL → commit + push, NO pr
d="$ROOT/t4"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"; before=$(grep -c 'pr create' "$GH_LOG")
out=$(ladder "$d" '{"done":true}' fail)
assert_contains 'push' "$out" "4. still commits+pushes"
assert_contains 'pr-withheld:gate-not-green' "$out" "4. PR withheld on red gate"
assert_eq "$before" "$(grep -c 'pr create' "$GH_LOG")" "4. no PR created on red gate"

# 5. GUARDRAIL branch-first: dirty on main → branch + commit there, main untouched
d="$ROOT/t5"; new_repo "$d"; main_before=$(count "$d" main)
echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":false}' skip "ZV-4242 do the thing")
assert_contains 'branched:' "$out" "5. branched off main"
head=$(git -C "$d" rev-parse --abbrev-ref HEAD)
[ "$head" != main ] && ok "5. HEAD left main ($head)" || ko "5. HEAD left main"
assert_eq "$main_before" "$(count "$d" main)" "5. main has NO new commit (guardrail)"
assert_eq 2 "$(count "$d" HEAD)" "5. commit landed on the feature branch"

# 6. no remote → commit only, push skipped
d="$ROOT/t6"; new_repo "$d"; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'commit' "$out" "6. commit without remote"
assert_absent 'push' "$out" "6. no push (no remote)"
assert_absent 'pr:' "$out" "6. no PR (no remote)"

# 7. wip/ skip marker → untouched
d="$ROOT/t7"; new_repo "$d" --remote; git -C "$d" checkout -q -b wip/spike
echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'skip-marker' "$out" "7. wip/ branch skipped"
assert_eq 1 "$(count "$d" HEAD)" "7. nothing committed on wip/"

# 8. on_done=suggest → no gh call, surfaces the PR-creation URL
d="$ROOT/t8"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"; echo '{"on_done":"suggest"}' > "$ROOT/cfg-suggest.json"; before=$(grep -c 'pr create' "$GH_LOG")
out=$(ladder "$d" '{"done":true}' pass "" "$ROOT/cfg-suggest.json")
assert_contains 'suggest-pr' "$out" "8. suggest mode → no auto-open"
assert_contains 'compare/main...feat' "$out" "8. surfaces the PR-creation URL"
assert_eq "$before" "$(grep -c 'pr create' "$GH_LOG")" "8. gh pr create NOT invoked in suggest mode"

# 9. ticket commit convention → [TICKET] in message
d="$ROOT/t9"; new_repo "$d"; git -C "$d" checkout -q -b zv-1234-work
echo x > "$d/a.txt"; echo '{"commit_convention":"ticket"}' > "$ROOT/cfg-ticket.json"
ladder "$d" '{"done":false,"type":"feat","summary":"do x"}' skip "ZV-1234 do x" "$ROOT/cfg-ticket.json" >/dev/null
msg=$(git -C "$d" log -1 --pretty=%B)
assert_contains '[ZV-1234]' "$msg" "9. ticket convention → [ZV-1234] in commit"

# 10. idempotency → second run with nothing new = no commit, no duplicate PR
d="$ROOT/t10"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"; ladder "$d" '{"done":true}' pass >/dev/null; after1=$(count "$d" HEAD); prc1=$(grep -c 'pr create' "$GH_LOG")
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'pr:exists' "$out" "10. second run sees the existing PR"
assert_eq "$after1" "$(count "$d" HEAD)" "10. no duplicate commit"
assert_eq "$prc1" "$(grep -c 'pr create' "$GH_LOG")" "10. no duplicate PR created"

# 11. engage path — engaged (work this session) → runs; not engaged → silent no-op
d="$ROOT/t11"; new_repo "$d"; git -C "$d" checkout -q -b feat; arm "$d"
echo x > "$d/a.txt"; before=$(count "$d" HEAD)
python3 "$SHIP" engage --repo "$d" --goal "do x" >/dev/null 2>&1
[ "$(count "$d" HEAD)" -gt "$before" ] && ok "11. engaged repo → engage committed" || ko "11. engaged repo → engage committed"
d2="$ROOT/t11b"; new_repo "$d2"; git -C "$d2" checkout -q -b feat; echo x > "$d2/a.txt"; before=$(count "$d2" HEAD)
env -u SHIP_WHEN_DONE python3 "$SHIP" engage --repo "$d2" --goal "do x" --session NONE >/dev/null 2>&1
assert_eq "$before" "$(count "$d2" HEAD)" "11. not engaged (no session ownership) → engage is a silent no-op"

# 11b. engagement: only work THIS session produced engages (a pre-existing dirty tree does NOT)
eng(){ env -u SHIP_WHEN_DONE python3 "$SHIP" engaged --repo "$1" --session "$2"; }
SWD_PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
posttool(){ printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" \
  | CLAUDE_PLUGIN_ROOT="$SWD_PLUGIN" python3 "$SWD_PLUGIN/hooks/posttool-hook.py"; }
d="$ROOT/t11c"; new_repo "$d"; git -C "$d" checkout -q -b feat
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S >/dev/null
assert_eq "no" "$(eng "$d" S)" "11b. clean baseline, no work yet → not engaged"
echo work > "$d/new.txt"
assert_eq "yes" "$(eng "$d" S)" "11b. session edited the tree → engaged"
d=$ROOT/t11d; new_repo "$d"; git -C "$d" checkout -q -b feat
echo "leftover" >> "$d/README.md"                       # dirty BEFORE the session baselines
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S >/dev/null
assert_eq "no" "$(eng "$d" S)" "11b. pre-existing dirty tree, session adds nothing → NOT engaged"
assert_eq "no" "$(eng "$d" OTHER)" "11b. a different session → not engaged"
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S3 >/dev/null
printf '{"enabled":false}' > "$d/.ship-when-done.json"   # this edit would engage, but enabled:false wins
assert_eq "no" "$(eng "$d" S3)" "11b. enabled:false opts the repo out (even with fresh work)"

# 11e. single-turn delivery: all work committed in one turn on a branch created that turn — the branch
# is baselined only AFTER the work, so HEAD/tree never move since baseline, yet the work carries paths
# this session OBSERVABLY edited (PostToolUse provenance) → engaged (the blind spot found in real
# usage). Pre-existing branches (zero provenance) stay NOT engaged — the safety guard holds.
d="$ROOT/t11e"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S1 >/dev/null   # session starts on main
git -C "$d" checkout -q -b feat-oneturn
echo x > "$d/a.txt"; posttool S1 "$d/a.txt"                                          # the edit event fires
case "$(cat "$d/.git/swd-provenance.json" 2>/dev/null)" in *'"a.txt"'*) ok "11e. posttool hook recorded the repo-relative path";; *) ko "11e. posttool hook recorded the repo-relative path";; esac
git -C "$d" add -A; git -C "$d" commit -qm "ZV-1 done in one turn"
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S1 >/dev/null   # branch first seen already-ahead, clean
assert_eq "yes" "$(eng "$d" S1)" "11e. one-turn work on a fresh branch (clean tree) → engaged via provenance"

d="$ROOT/t11f"; new_repo "$d" --remote; git -C "$d" checkout -q -b preexisting
env GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00"   git -C "$d" commit -q --allow-empty -m "old work from before this session"
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S2 >/dev/null   # visiting: ahead, but old
assert_eq "no" "$(eng "$d" S2)" "11e. pre-existing branch (commits predate the session) → NOT engaged"

# 11g. INCIDENT: branch created + committed manually MID-turn — the Stop fires before the branch has
# any baseline entry; provenance (paths this session edited) claims it (pre-session work must not)
d="$ROOT/t11g"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S4 >/dev/null   # session starts on main
git -C "$d" checkout -q -b feat-midturn
echo x > "$d/a.txt"; posttool S4 "$d/a.txt"
git -C "$d" add -A; git -C "$d" commit -qm "authored this session"
assert_eq "yes" "$(eng "$d" S4)" "11g. unbaselined mid-turn branch, session-edited paths → engaged"
d="$ROOT/t11h"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S5 >/dev/null
git -C "$d" checkout -q -b preexisting-nobaseline
env GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
  git -C "$d" commit -q --allow-empty -m "old work from before this session"
assert_eq "no" "$(eng "$d" S5)" "11g. unbaselined branch, pre-session commits → NOT engaged"

# 11i. two concurrent sessions on one repo: each keeps its OWN baseline — the second baseliner
# must not erase the first session's engagement state (multi-session map, not last-writer-wins)
d="$ROOT/t11i"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session SA >/dev/null
echo a > "$d/a.txt"                                   # SA's work
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session SB >/dev/null   # SB arrives, tree already dirty
assert_eq "yes" "$(eng "$d" SA)" "11i. SA still engaged after SB baselined"
assert_eq "no"  "$(eng "$d" SB)" "11i. SB (baselined on the dirty tree) NOT engaged"
# sessions idle past the GC window are dropped on the next write; live ones survive
d="$ROOT/t11igc"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"v":1,"sessions":{"STALE":{"started":"2020-01-01T00:00:00+00:00","branches":{}}}}' > "$d/.git/swd-session.json"
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session FRESH >/dev/null
case "$(cat "$d/.git/swd-session.json")" in *STALE*) ko "11i. stale session GC'd on write";; *) ok "11i. stale session GC'd on write";; esac
case "$(cat "$d/.git/swd-session.json")" in *FRESH*) ok "11i. live session survives the GC";; *) ko "11i. live session survives the GC";; esac

# the legacy single-session migration window (one minor) is CLOSED: a pre-v1 file is ignored
d="$ROOT/t11L"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"session":"OLD","started":"2026-06-11T00:00:00+00:00","branches":{"feat":{"engaged":true}}}' > "$d/.git/swd-session.json"
assert_eq "no" "$(eng "$d" OLD)" "11L. legacy pre-v1 session file → ignored (migration window closed)"

# 11j. a branch whose recent commits this session merely CHECKED OUT (no file it touched) must
# NOT engage — provenance, not author dates, decides ownership
d="$ROOT/t11j"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S6 >/dev/null
git -C "$d" checkout -q -b teammate
echo t > "$d/their.txt"; git -C "$d" add -A; git -C "$d" commit -qm "teammate work, authored now"
assert_eq "no" "$(eng "$d" S6)" "11j. fresh-authored teammate branch, zero session provenance → NOT engaged"
# 11k. the mid-turn branch DOES engage via provenance (no baseline, no author-date rule)
d="$ROOT/t11k"; new_repo "$d" --remote
env -u SHIP_WHEN_DONE python3 "$SHIP" baseline --repo "$d" --session S7 >/dev/null
git -C "$d" checkout -q -b feat-midturn
echo x > "$d/mine.txt"; git -C "$d" add -A; git -C "$d" commit -qm work
printf '{"v":1,"sessions":{"S7":{"paths":["mine.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "yes" "$(eng "$d" S7)" "11k. branch carrying session-touched paths → engaged (provenance)"

# 12a. gate auto-detection from package.json (+ lockfile → runner)
d="$ROOT/t12"; new_repo "$d"
printf '{"scripts":{"ts:check":"tsc --noEmit","test":"vitest"}}' > "$d/package.json"; touch "$d/pnpm-lock.yaml"
g=$(python3 -c "import sys; sys.path.insert(0,'$(dirname "$SHIP")'); import ship; print(ship.detect_gate('$d', dict(ship.DEFAULTS)))")
assert_eq "pnpm ts:check" "$g" "12a. gate auto-detected (pnpm ts:check)"

# 12b. engage, FREE eval: gate green (config) + done signal → draft PR, no model call
d="$ROOT/t12b"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"; before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" mark-done --repo "$d" --summary "do x" >/dev/null
python3 "$SHIP" engage --repo "$d" --goal "ZV-1 do x" >/dev/null 2>&1
[ "$(grep -c 'pr create' "$GH_LOG")" -gt "$before" ] && ok "12b. engage gate-green + done → draft PR (free)" || ko "12b. engage gate-green + done → draft PR (free)"
assert_contains '--draft' "$(grep 'pr create' "$GH_LOG" | tail -1)" "12b. opened as draft"

# 12c. engage: red gate → commit + push, NO PR
d="$ROOT/t12c"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"false"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"; before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" mark-done --repo "$d" --summary x >/dev/null
python3 "$SHIP" engage --repo "$d" --goal x >/dev/null 2>&1
assert_eq "$before" "$(grep -c 'pr create' "$GH_LOG")" "12c. red gate → no PR"
[ "$(count "$d" HEAD)" -gt 1 ] && ok "12c. red gate still committed (anti-loss)" || ko "12c. red gate still committed"

# 13. re-entrance guard: a nested eval (SHIP_WHEN_DONE_EVAL set) is a hard no-op
d="$ROOT/t13"; new_repo "$d"; git -C "$d" checkout -q -b feat
printf '{}' > "$d/.ship-when-done.json"; echo x > "$d/a.txt"; before=$(count "$d" HEAD)
SHIP_WHEN_DONE_EVAL=1 python3 "$SHIP" engage --repo "$d" --goal x --last-message done >/dev/null 2>&1
assert_eq "$before" "$(count "$d" HEAD)" "13. re-entrance guard → no-op (no nested commit)"

# 14. mark-done marker drives done (no keyword, no todos) → draft PR, marker consumed
d="$ROOT/t14"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "did the thing" >/dev/null
[ -f "$d/.git/swd-done.json" ] && ok "14. mark-done wrote the marker (in .git)" || ko "14. mark-done wrote the marker"
before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" engage --repo "$d" --goal "ZV-9 x" >/dev/null 2>&1   # no --last-message: only the marker says done
[ "$(grep -c 'pr create' "$GH_LOG")" -gt "$before" ] && ok "14. marker → draft PR (no keyword, no model)" || ko "14. marker → draft PR"
[ ! -f "$d/.git/swd-done.json" ] && ok "14. marker consumed after PR" || ko "14. marker consumed after PR"

# 15. all-todos-complete signal drives done → draft PR
d="$ROOT/t15"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"; before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" engage --repo "$d" --goal x --todos-done >/dev/null 2>&1   # no marker, no keyword
[ "$(grep -c 'pr create' "$GH_LOG")" -gt "$before" ] && ok "15. todos-complete → draft PR" || ko "15. todos-complete → draft PR"

# 16. marker + RED gate → no PR, marker kept for next time
d="$ROOT/t16"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"false"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"
python3 "$SHIP" mark-done --repo "$d" --summary x >/dev/null; before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" engage --repo "$d" --goal x >/dev/null 2>&1
assert_eq "$before" "$(grep -c 'pr create' "$GH_LOG")" "16. marker + red gate → no PR"
[ -f "$d/.git/swd-done.json" ] && ok "16. marker kept when PR withheld" || ko "16. marker kept when PR withheld"

# 17. detached HEAD → refuse (no commit)  [review C2]
d="$ROOT/t17"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
echo y > "$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm second; git -C "$d" checkout -q --detach HEAD
echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'detached-head' "$out" "17. detached HEAD → refused"
assert_absent '"commit"' "$out" "17. no commit on detached HEAD"

# 18. merge in progress → refuse  [review C3]
d="$ROOT/t18"; new_repo "$d"; git -C "$d" checkout -q -b feat; echo x > "$d/a.txt"; touch "$d/.git/MERGE_HEAD"
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'merge-in-progress' "$out" "18. mid-merge → refused"
assert_absent '"commit"' "$out" "18. no commit during a merge"

# 19. unborn HEAD (no commits) → refuse, default untouched  [review C4]
d="$ROOT/t19"; mkdir -p "$d"; git -C "$d" init -q -b main
git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'unborn-head' "$out" "19. unborn HEAD → refused"
assert_absent '"commit"' "$out" "19. no commit on unborn HEAD"

# 20. non-main trunk (develop) WITHOUT remote → branch-first, develop untouched  [review C1]
d="$ROOT/t20"; mkdir -p "$d"; git -C "$d" init -q -b develop
git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
echo i > "$d/r"; git -C "$d" add -A; git -C "$d" commit -qm init; dev_before=$(count "$d" develop); echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'branched:' "$out" "20. non-main trunk (develop) → branch-first"
assert_eq "$dev_before" "$(count "$d" develop)" "20. develop has NO new commit (guardrail)"

# 21. committed-but-unpushed work on default → surfaced, not silently skipped  [review H2]
d="$ROOT/t21"; new_repo "$d" --remote
echo y > "$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm "local only"   # on main, not pushed, clean tree
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'unpushed-on-default' "$out" "21. unpushed-on-default surfaced (H2)"

# 22. remote not named 'origin' → push still works  [review M3]
d="$ROOT/t22"; mkdir -p "$d"; git -C "$d" init -q -b main
git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
echo i > "$d/r"; git -C "$d" add -A; git -C "$d" commit -qm init
git init -q --bare "$d.git"; git -C "$d" remote add gitlab "$d.git"; git -C "$d" push -q -u gitlab main 2>/dev/null
git -C "$d" checkout -q -b feat; echo x > "$d/a.txt"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'push' "$out" "22. pushes to a non-origin remote (M3)"
git -C "$d.git" rev-parse --verify -q feat >/dev/null && ok "22. branch landed on the 'gitlab' remote" || ko "22. branch on gitlab remote"

# 23. gh failing on `pr view` → no duplicate PR  [review M2]
d="$ROOT/t23"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; echo x > "$d/a.txt"
mkdir -p "$ROOT/binfail"; cat > "$ROOT/binfail/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "pr view" ] && { echo "could not authenticate to host" >&2; exit 1; }
echo "\$@" >> "$GH_LOG"; exit 0
EOF
chmod +x "$ROOT/binfail/gh"; before=$(grep -c 'pr create' "$GH_LOG")
out=$(PATH="$ROOT/binfail:$PATH" python3 "$SHIP" ladder --repo "$d" --verdict '{"done":true}' --gate pass 2>&1)
assert_contains 'pr:check-failed' "$out" "23. gh error on pr view → not created (M2)"
assert_eq "$before" "$(grep -c 'pr create' "$GH_LOG")" "23. no PR created on gh failure"

# 24. suggest mode keeps the marker (only opened PRs consume it)  [review M1]
d="$ROOT/t24"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"true","on_done":"suggest"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"
python3 "$SHIP" mark-done --repo "$d" --summary x >/dev/null
python3 "$SHIP" engage --repo "$d" --goal x >/dev/null 2>&1
[ -f "$d/.git/swd-done.json" ] && ok "24. suggest mode keeps the marker (M1)" || ko "24. suggest mode keeps the marker"

# 25. gitlab + glab present → draft MR via the glab CLI  [forge case 1b]
d="$ROOT/t25"; new_repo "$d" --remote gitlab.com; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"; : > "$GLAB_LOG"
out=$(forge_ladder "$d" "$ROOT/glabbin:$ROOT/realbin")
assert_contains 'pr:draft-pr' "$out" "25. gitlab+glab → draft MR via glab"
assert_contains 'mr create' "$(cat "$GLAB_LOG")" "25. glab mr create invoked"
assert_contains '--draft' "$(cat "$GLAB_LOG")" "25. MR opened as draft"
assert_contains '--target-branch main' "$(cat "$GLAB_LOG")" "25. target branch passed to glab"

# 26. gitlab WITHOUT glab → MR requested through git push options (no CLI)  [forge case 2]
d="$ROOT/t26"; new_repo "$d" --remote gitlab.com; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"
out=$(forge_ladder "$d" "$ROOT/realbin")
assert_contains 'push' "$out" "26. pushed the branch"
assert_contains 'pr:gitlab-mr' "$out" "26. MR requested via push options (no CLI)"
git -C "$d.git" rev-parse --verify -q feat >/dev/null && ok "26. branch landed on the remote" || ko "26. branch on remote"

# 27. bitbucket (no CLI path) → PR-creation URL surfaced  [forge case 3]
d="$ROOT/t27"; new_repo "$d" --remote bitbucket.org; git -C "$d" checkout -q -b feat
echo x > "$d/a.txt"
out=$(forge_ladder "$d" "$ROOT/realbin")
assert_contains 'pr-url' "$out" "27. bitbucket → URL action"
assert_contains 'bitbucket.org/test/repo/pull-requests/new' "$out" "27. constructed the bitbucket PR URL"

# 28. forge helpers — URL parsing, URL construction, strategy selection, forge override (unit)
cat > "$ROOT/forge_unit.py" <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("ship", os.environ["SHIP"])
ship = importlib.util.module_from_spec(spec); spec.loader.exec_module(ship)
def check(c, m): print(("PASS " if c else "FAIL ") + "28. " + m)
g = ship.parse_remote("git@gitlab.example.com:grp/sub/repo.git")
check(g and g["forge"] == "gitlab" and g["https"] == "https://gitlab.example.com/grp/sub/repo", "parse self-hosted gitlab (scp, nested group)")
check(ship.parse_remote("git@github.com:o/r.git")["forge"] == "github", "parse github (scp)")
check(ship.parse_remote("ssh://git@bitbucket.org/t/r.git")["forge"] == "bitbucket", "parse bitbucket (ssh)")
p = ship.parse_remote("ssh://git@gitlab.mycorp.com:2222/group/repo.git")
check(p and p["host"] == "gitlab.mycorp.com" and p["path"] == "group/repo" and "2222" not in p["https"], "ssh non-standard port does not leak into host/path/url")
c = ship.parse_remote("https://user:token@gitlab.com/g/r.git")
check(c and c["host"] == "gitlab.com" and c["path"] == "g/r" and "token" not in c["https"], "https credentials stripped")
pt = ship.parse_remote("https://gitlab.example.com:8080/g/r.git")
check(pt and pt["host"] == "gitlab.example.com:8080" and pt["path"] == "g/r", "https web port kept on host, not in path")
u = ship.parse_remote("file:///srv/git/x.git")
check(u is None or u["forge"] == "unknown", "non-forge URL stays safe")
check(ship.parse_remote("garbage") is None, "garbage rejected")
check(ship.parse_remote("../local/bare") is None, "bare local path rejected")
gl = ship.parse_remote("https://gitlab.com/g/r.git")
check("/-/merge_requests/new?" in ship.pr_create_url(gl, "main", "f/x"), "gitlab MR URL shape")
check(ship.pr_create_url(ship.parse_remote("https://github.com/o/r.git"), "main", "f") == "https://github.com/o/r/compare/main...f?expand=1", "github compare URL")
orig = ship.which
ship.which = lambda c: "/x/" + c
check(ship.pr_strategy("github") == "gh" and ship.pr_strategy("gitlab") == "glab", "strategy picks the CLI when present")
ship.which = lambda c: None
check(ship.pr_strategy("github") == "url", "github without gh → url")
check(ship.pr_strategy("gitlab") == "gitlab-push", "gitlab without glab → push options")
check(ship.pr_strategy("bitbucket") == "url", "bitbucket → url")
calls = []
def fake_run(cmd, cwd, check=False):
    calls.append(list(cmd))
    return (0, "https://github.com/o/r.git", "") if cmd[:3] == ["git", "remote", "get-url"] else (0, "", "")
ship.run = fake_run
state = {"is_git": True, "repo": "/x", "branch": "feat", "default_branch": "main", "on_default": False,
         "dirty": False, "has_remote": True, "remote": "origin", "has_upstream": True, "unpushed": 1,
         "ahead_of_base": 1, "detached": False, "unborn": False, "mid_op": None}
cfg = dict(ship.DEFAULTS); cfg["forge"] = "gitlab"
res = ship.run_ladder(state, {"done": True, "summary": "x"}, "pass", cfg)
piggy = any(c[:2] == ["git", "push"] and "merge_request.create" in c for c in calls)
check("pr:gitlab-mr" in res["actions"] and piggy, "forge override forces gitlab-push despite a github remote")
ship.which = orig
PY
while IFS= read -r line; do
  case "$line" in PASS*) ok "${line#PASS }";; FAIL*) ko "${line#FAIL }";; esac
done < <(SHIP="$SHIP" "$PY" "$ROOT/forge_unit.py")

# 29. url strategy (bitbucket) → surfaces the clickable URL once, never re-nags  [review F2]
d="$ROOT/t29"; new_repo "$d" --remote bitbucket.org; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "do x" >/dev/null
out1=$(python3 "$SHIP" engage --repo "$d" --goal "ZV-1 x" 2>&1)
assert_contains 'pr-url' "$out1" "29. first engage emits pr-url"
assert_contains 'bitbucket.org/test/repo/pull-requests/new' "$out1" "29. the actual PR URL is printed for the human"
out2=$(python3 "$SHIP" engage --repo "$d" --goal "ZV-1 x" 2>&1)   # no new work
assert_absent 'pr-url' "$out2" "29. second engage (no new commits) does NOT re-nag"

# 30. done turn makes NO new commit but the branch was pushed earlier → URL still surfaced once  [review F2 regression]
d="$ROOT/t30"; new_repo "$d" --remote bitbucket.org; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; echo x > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --goal "ZV-1 x" >/dev/null 2>&1            # turn 1: commit + push, NOT done
python3 "$SHIP" mark-done --repo "$d" --summary x >/dev/null
out=$(python3 "$SHIP" engage --repo "$d" --goal "ZV-1 x" 2>&1)               # turn 2: done, no new edits, no push
assert_contains 'pr-url' "$out" "30. done-but-already-pushed → URL surfaced even with no push this turn"
assert_contains 'bitbucket.org' "$out" "30. the surfaced URL is the bitbucket one"
out2=$(python3 "$SHIP" engage --repo "$d" --goal "ZV-1 x" 2>&1)             # turn 3: tip unchanged
assert_absent 'pr-url' "$out2" "30. third turn (tip unchanged) does NOT re-nag"

# 31. resolve: active repo (subdir / push command / transcript), root-anchored
rr="$ROOT/t31"; new_repo "$rr" --remote; git -C "$rr" checkout -q -b feat
sub="$rr/a/b/c"; mkdir -p "$sub"; rtop="$(git -C "$rr" rev-parse --show-toplevel)"
assert_eq "$rtop" "$(python3 "$SHIP" resolve --cwd "$sub")" "31. resolve: deep subdir → repo root"
nr="$ROOT/t31-nr"; mkdir -p "$nr"
assert_eq "" "$(python3 "$SHIP" resolve --cwd "$nr")" "31. resolve: non-repo cwd → empty"
assert_eq "$rtop" "$(python3 "$SHIP" resolve --command "git -C $rr push origin feat")" "31. resolve: git -C X push → X root"
assert_eq "$rtop" "$(python3 "$SHIP" resolve --command "cd $rr && git push")" "31. resolve: cd X && git push → X root"
tpr="$ROOT/t31.jsonl"; printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/app.txt"}}]}}\n' "$sub" > "$tpr"
assert_eq "$rtop" "$(python3 "$SHIP" resolve --cwd "$nr" --transcript "$tpr")" "31. resolve: transcript last-edit → its repo root"

# 31b. submodule workspace: cwd at the superproject root, edits in a submodule → the SUBMODULE wins
# (committing from the superproject would only bump a pointer — the exact Z&V-workspace hazard)
sup="$ROOT/r31b"; mkdir -p "$sup"; git -C "$sup" init -q -b main
git -C "$sup" config user.email t@t.t; git -C "$sup" config user.name t; git -C "$sup" config commit.gpgsign false
printf '[submodule "lib"]\n\tpath = lib\n' > "$sup/.gitmodules"
mkdir -p "$sup/lib"; git -C "$sup/lib" init -q -b main
subtop="$(git -C "$sup/lib" rev-parse --show-toplevel)"
tps="$ROOT/t31b.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/inner.txt"}}]}}\n' "$subtop" > "$tps"
assert_eq "$subtop" "$(python3 "$SHIP" resolve --cwd "$sup" --transcript "$tps")" "31b. submodule edit from superproject cwd → submodule root"
suptop="$(git -C "$sup" rev-parse --show-toplevel)"
tpo="$ROOT/t31b-out.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/outside.txt"}}]}}\n' "$ROOT" > "$tpo"
assert_eq "$suptop" "$(python3 "$SHIP" resolve --cwd "$sup" --transcript "$tpo")" "31b. edits OUTSIDE the superproject never steal the anchor"
python3 "$SHIP" baseline --repo "$sub" --session s1
[ -f "$rtop/.git/swd-session.json" ] && ok "31. root-anchor: baseline from subdir → state at repo root" || ko "31. root-anchor subdir"

# 32. merge-review composition: hold the PUSH until the quality gate passes (the COMMIT is the anti-loss)
d="$ROOT/t32"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; echo x > "$d/a.txt"
printf '{"session":"s","branches":{}}' > "$d/.git/merge-review-session.json"   # merge-review active, no pass yet
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'commit' "$out" "32. commits the work (anti-loss is the local commit)"
assert_contains 'push-held:merge-review-pending' "$out" "32. unreviewed → push HELD (nothing reaches the remote)"
assert_absent 'pr:draft' "$out" "32. no PR while the review is pending"
git -C "$d.git" rev-parse --verify -q feat >/dev/null 2>&1 && ko "32. branch must NOT be on the remote yet" || ok "32. branch not pushed to the remote (gate runs before the push)"
H=$(git -C "$d" rev-parse HEAD)
printf '{"head":"%s","passed":true}' "$H" > "$d/.git/merge-review-state.json"
out=$(ladder "$d" '{"done":true}' pass)
assert_contains 'push' "$out" "32. review passed → push happens"
assert_contains 'pr:' "$out" "32. review passed → PR opens"
git -C "$d.git" rev-parse --verify -q feat >/dev/null 2>&1 && ok "32. branch on the remote after the review" || ko "32. branch pushed after the review"
# 32b. no merge-review session file → gate inert, push + PR as before (graceful degradation)
d="$ROOT/t32b"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; echo x > "$d/a.txt"
assert_contains 'pr:' "$(ladder "$d" '{"done":true}' pass)" "32b. merge-review absent → push + PR (no coupling)"
# 32c. engage emits a review-block continuation when the push is held
d="$ROOT/t32c"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"session":"","branches":{}}' > "$d/.git/merge-review-session.json"; echo x > "$d/a.txt"
out=$(python3 "$SHIP" engage --repo "$d" --goal "do x" 2>&1)
assert_contains '"decision": "block"' "$out" "32c. push held → engage emits a block to run the review"
assert_contains 'merge-review' "$out" "32c. the block tells the session to run merge-review"

# 33. commit subject derived from the changed FILES, never from free prose (no ticket/marker)
d="$ROOT/t33"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
mkdir -p "$d/plugins/foo"; echo x > "$d/plugins/foo/bar.py"
python3 "$SHIP" engage --repo "$d" --goal "x" --last-message "this is my rambling prose that must not leak into the commit" >/dev/null 2>&1
msg=$(git -C "$d" log -1 --pretty=%s)
assert_absent 'rambling prose' "$msg" "33. commit subject does NOT contain free prose"
assert_contains 'bar.py' "$msg" "33. commit subject derived from the changed file"
assert_contains 'foo' "$msg" "33. scope derived from the directory (generic 'plugins' skipped)"
case "$msg" in chore*|docs*|test*|"["*) ok "33. conventional-commit type prefix";; *) ko "33. conventional type — got [$msg]";; esac
# docs type when all changed files are docs
d="$ROOT/t33b"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
mkdir -p "$d/docs"; echo '# x' > "$d/docs/guide.md"
python3 "$SHIP" engage --repo "$d" --goal "x" --last-message "noise" >/dev/null 2>&1
case "$(git -C "$d" log -1 --pretty=%s)" in docs*) ok "33b. all-docs change → docs: type";; *) ko "33b. docs type — got [$(git -C "$d" log -1 --pretty=%s)]";; esac

# 34. SECURITY: command fields in the working-tree config are ignored (a cloned repo can't execute code)
d="$ROOT/t34"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat; arm "$d"
printf '{"gate":"touch %s/pwned-gate","judge_command":"touch %s/pwned-judge"}' "$d" "$d" > "$d/.ship-when-done.json"
echo x > "$d/a.txt"
python3 "$SHIP" mark-done --repo "$d" --summary x >/dev/null
python3 "$SHIP" engage --repo "$d" --goal x >/dev/null 2>&1
[ ! -f "$d/pwned-gate" ] && ok "34. tree-config gate NOT executed" || ko "34. tree-config gate executed (RCE)"
[ ! -f "$d/pwned-judge" ] && ok "34. tree-config judge_command NOT executed" || ko "34. tree-config judge_command executed (RCE)"
g=$(python3 -c "import sys; sys.path.insert(0,'$(dirname "$SHIP")'); import ship; print(ship.load_config('$d')['gate'])")
assert_eq "None" "$g" "34. load_config strips gate from the tree file"
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
g=$(python3 -c "import sys; sys.path.insert(0,'$(dirname "$SHIP")'); import ship; print(ship.load_config('$d')['gate'])")
assert_eq "true" "$g" "34. .git/ship-when-done.json still sets the gate (local, never cloned)"

# 35. INCIDENT: porcelain is positional — a worktree-modified path (' M tests/…') stripped of its
# leading space loses the first character of the path, and the scope becomes 'ests'
d="$ROOT/t35"; new_repo "$d"; git -C "$d" checkout -q -b feat
mkdir -p "$d/tests/e2e"; echo '{}' > "$d/tests/e2e/coverage.json"
git -C "$d" add -A; git -C "$d" commit -qm baseline
echo '{"a":1}' > "$d/tests/e2e/coverage.json"
ladder "$d" '{"done":false}' skip >/dev/null
msg=$(git -C "$d" log -1 --pretty=%s)
assert_contains '(tests)' "$msg" "35. scope from a worktree-modified path keeps its first character"
assert_absent '(ests)' "$msg" "35. no mangled scope from stripped porcelain"

# 36. INCIDENT: a path claimed by a LIVE background writer (.git/swd-claims.json, path → pid) is
# invisible to ship — never swept into a commit, never counted as in-flight work
d="$ROOT/t36"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
mkdir -p "$d/tests/e2e"; echo '{}' > "$d/tests/e2e/coverage.json"
git -C "$d" add -A; git -C "$d" commit -qm baseline
echo partial > "$d/tests/e2e/coverage.json"; echo x > "$d/a.txt"
printf '{"tests/e2e/coverage.json": %s}' "$$" > "$d/.git/swd-claims.json"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'commit' "$out" "36. unclaimed work still commits"
case "$(git -C "$d" show --pretty= --name-only HEAD)" in *coverage.json*) ko "36. claimed path swept into the commit";; *) ok "36. claimed path NOT in the commit";; esac
case "$(git -C "$d" status --porcelain)" in *coverage.json*) ok "36. claimed change stays in the tree";; *) ko "36. claimed change stays in the tree";; esac
case "$(git -C "$d" log -1 --pretty=%s)" in *coverage.json*) ko "36. claimed path leaked into the subject";; *) ok "36. commit subject ignores the claimed path";; esac
# claimed-only changes → nothing in flight (no partial-ledger commit while the writer runs)
d="$ROOT/t36b"; new_repo "$d" --remote
mkdir -p "$d/tests/e2e"; echo '{}' > "$d/tests/e2e/coverage.json"
git -C "$d" add -A; git -C "$d" commit -qm baseline; git -C "$d" push -q origin main 2>/dev/null
git -C "$d" checkout -q -b feat
echo partial > "$d/tests/e2e/coverage.json"
printf '{"tests/e2e/coverage.json": %s}' "$$" > "$d/.git/swd-claims.json"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'nothing-in-flight' "$out" "36b. claimed-only changes → nothing in flight"
assert_eq 2 "$(count "$d" HEAD)" "36b. no commit of a partial ledger"
# a dead writer's claim is void — the path is sweepable again (no stale lock)
d="$ROOT/t36c"; new_repo "$d"; git -C "$d" checkout -q -b feat
echo y > "$d/f.txt"
sleep 0 & deadpid=$!; wait "$deadpid" 2>/dev/null
printf '{"f.txt": %s}' "$deadpid" > "$d/.git/swd-claims.json"
out=$(ladder "$d" '{"done":false}' skip)
assert_contains 'commit' "$out" "36c. dead writer → claim void, work swept normally"
# claim/release subcommands own the protocol file
d="$ROOT/t36d"; new_repo "$d"
python3 "$SHIP" claim --repo "$d" --path tests/e2e/coverage.json --pid "$$" >/dev/null 2>&1
case "$(cat "$d/.git/swd-claims.json" 2>/dev/null)" in *coverage.json*) ok "36d. claim writes the protocol file";; *) ko "36d. claim writes the protocol file";; esac
python3 "$SHIP" release --repo "$d" --path tests/e2e/coverage.json >/dev/null 2>&1
case "$(cat "$d/.git/swd-claims.json" 2>/dev/null)" in *coverage.json*) ko "36d. release drops the claim";; *) ok "36d. release drops the claim";; esac

# 37. the done-marker is branch-scoped: done on feat-a must never ship feat-b (two-branch ambiguity)
d="$ROOT/t37"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat-a
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
python3 "$SHIP" mark-done --repo "$d" --summary "a done" >/dev/null
git -C "$d" checkout -q -b feat-b
echo x > "$d/b.txt"
printf '{"v":1,"sessions":{"":{"branches":{"feat-b":{"engaged":true}}}}}' > "$d/.git/swd-session.json"
before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" engage --repo "$d" --goal x >/dev/null 2>&1
assert_eq "$before" "$(grep -c 'pr create' "$GH_LOG")" "37. feat-a marker does NOT open a PR for feat-b"
[ -f "$d/.git/swd-done.json" ] && ok "37. marker kept for feat-a" || ko "37. marker kept for feat-a"
# a todos-driven PR for feat-b must NOT consume feat-a's marker (only the marker that drove a PR is)
python3 "$SHIP" engage --repo "$d" --goal x --todos-done >/dev/null 2>&1
[ "$(grep -c 'pr create' "$GH_LOG")" -gt "$before" ] && ok "37. todos-done still ships feat-b" || ko "37. todos-done still ships feat-b"
[ -f "$d/.git/swd-done.json" ] && ok "37. feat-a marker survives the todos-driven PR" || ko "37. feat-a marker survives the todos-driven PR"
# branch-first move: a marker stamped on the trunk follows the work onto the derived branch — the
# re-entrant turn (after the review pass) must still read 'done' once the ladder moved off main
d="$ROOT/t37b"; new_repo "$d" --remote
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
printf '{"v":1,"sessions":{"":{"branches":{"main":{"engaged":true}}}}}' > "$d/.git/swd-session.json"
printf '{"session":"","branches":{}}' > "$d/.git/merge-review-session.json"
echo y > "$d/y.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "trunk single-shot" >/dev/null
python3 "$SHIP" engage --repo "$d" --goal "ZV-5 y" >/dev/null 2>&1            # turn 1: branch-first, push held
H=$(git -C "$d" rev-parse HEAD)
printf '{"head":"%s","passed":true}' "$H" > "$d/.git/merge-review-state.json"
before=$(grep -c 'pr create' "$GH_LOG")
python3 "$SHIP" engage --repo "$d" --goal "ZV-5 y" >/dev/null 2>&1            # turn 2: review passed → ship
[ "$(grep -c 'pr create' "$GH_LOG")" -gt "$before" ] && ok "37. marker followed the branch-first move → PR on the derived branch" || ko "37. marker followed the branch-first move → PR on the derived branch"

# FINAL GUARDRAIL: gh pr merge must NEVER have been called in any scenario
assert_absent 'MERGE-CALLED' "$(cat "$GH_LOG")" "GUARDRAIL: never auto-merged"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
