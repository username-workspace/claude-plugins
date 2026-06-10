#!/usr/bin/env bash
# Delivery-harness composition suite — ship-when-done × merge-review × mr-watchdog on real throwaway
# repos, driven through the real hooks. Encodes the end-to-end contract the three plugins promise
# together: single-shot deliveries are reviewed and watched, the gate runs once per work-state, every
# user-facing outcome reaches a rendered channel, and block-continuations advance the pipeline without
# a human prompt (bounded — never an infinite Stop loop).
set -u
ROOT="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIP="$REPO_ROOT/plugins/ship-when-done/skills/ship-when-done/scripts/ship.py"
WATCH="$REPO_ROOT/plugins/mr-watchdog/skills/mr-watchdog/scripts/watch.py"
REVIEW="$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py"
SHIP_HOOK="$REPO_ROOT/plugins/ship-when-done/hooks/stop-hook.py"
SHIP_PLUGIN="$REPO_ROOT/plugins/ship-when-done"
GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"
PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected to contain [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
key="\$(pwd | tr '/' '_')"
case "\$1 \$2" in
  "pr merge") echo "MERGE-CALLED" >> "$GH_LOG"; exit 0;;
  "pr view") if [ -f "$ROOT/pr-\$key-\$3" ]; then echo '{"state":"OPEN"}'; exit 0; else echo "no pull requests found" >&2; exit 1; fi;;
  "pr checks") echo '[{"bucket":"pending"}]'; exit 0;;
  "pr create")
     head=""; while [ \$# -gt 0 ]; do [ "\$1" = "--head" ] && head="\$2"; shift; done
     [ -n "\$head" ] && touch "$ROOT/pr-\$key-\$head"
     echo "https://example.test/pr/1"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir  [$2=--remote]  [$3=forge-host, default github.com]
  local d="$1" host="${3:-github.com}"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  if [ "${2:-}" = "--remote" ]; then
    git init -q --bare "$d.git"; git -C "$d.git" config receive.advertisePushOptions true
    git -C "$d" remote add origin "$d.git"
    git -C "$d" config remote.origin.pushurl "$d.git"
    git -C "$d" config remote.origin.url "https://$host/test/repo.git"
    git -C "$d" push -q -u origin main 2>/dev/null
  fi
}
stop_payload(){ printf '{"cwd":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$1" "$2" "$3" "$4"; }
prompt_baselines(){ python3 "$SHIP" baseline --repo "$1" --session "$2" >/dev/null
  python3 "$REVIEW" baseline --repo "$1" --session "$2" >/dev/null
  python3 "$WATCH" baseline --repo "$1" --session "$2" >/dev/null; }
pr_creates(){ grep -c 'pr create' "$GH_LOG" || true; }

tp="$ROOT/transcript.jsonl"
cat > "$tp" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"ZV-9 ship the gizmo"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done — gizmo shipped and verified."}]}}
J

echo "delivery-harness composition tests"

# --- 1. B1: the quality gate runs once per work-state, not on every Stop ---------------------------
d="$ROOT/b1"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"gate":"echo run >> %s"}' "$ROOT/gate1.log" > "$d/.git/ship-when-done.json"; : > "$ROOT/gate1.log"
python3 "$SHIP" baseline --repo "$d" --session s1 >/dev/null
echo work > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. first engage with work → gate ran once"
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "1. work committed"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. idle Stops with unchanged work-state → gate NOT re-run"
echo more > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. work-state changed → gate runs again"

# --- 2. B2: single-shot branch-first delivery is held for review (not silently shipped) ------------
d="$ROOT/ss"; new_repo "$d" --remote
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
prompt_baselines "$d" ss
echo gizmo > "$d/gizmo.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "ship the gizmo" --type feat >/dev/null
before=$(pr_creates)
out=$(stop_payload "$d" ss "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$out" "2. single-shot done → Stop blocks with a review request"
assert_contains 'merge-review' "$out" "2. the block asks for the merge-review pass"
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ko "2. nothing pushed before the review" || ok "2. nothing pushed before the review"
assert_eq "$before" "$(pr_creates)" "2. no PR opened before the review"
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "2. the work IS committed (anti-loss)"

# --- 3. B4: after the review pass, the re-entrant Stop ships it (no human prompt needed) ------------
python3 "$REVIEW" record --repo "$d" --score 95 --passed >/dev/null
out2=$(stop_payload "$d" ss "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ok "3. re-entrant Stop pushed the reviewed branch" || ko "3. re-entrant Stop pushed the reviewed branch"
assert_eq "$((before + 1))" "$(pr_creates)" "3. re-entrant Stop opened the PR"
grep -q 'MERGE-CALLED' "$GH_LOG" && ko "3. GUARDRAIL: never merged" || ok "3. GUARDRAIL: never merged"

# --- 4. B2b: the watchdog is handed the MR the pipeline just opened (no Stop-hook race) -------------
assert_contains 'run --repo' "$out2" "4. PR opened → the same Stop hands off the watcher launch"
assert_contains 'run_in_background' "$out2" "4. the launch instruction is the background-watch contract"
assert_eq "yes" "$(python3 "$WATCH" engaged --repo "$d" --session ss)" "4. watchdog engaged on the branch ship pushed"

# --- 5. loop safety: a re-entrant Stop with unchanged state never re-blocks (bounded continuation) --
out3=$(stop_payload "$d" ss "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_absent '"decision": "block"' "$out3" "5. same state again → no second block (no infinite Stop loop)"
assert_eq "$((before + 1))" "$(pr_creates)" "5. no duplicate PR"

# --- 6. loop safety: an unanswered review request is not re-blocked for the same work-state ---------
d6="$ROOT/b6"; new_repo "$d6" --remote
printf '{"gate":"true"}' > "$d6/.git/ship-when-done.json"
prompt_baselines "$d6" s6
echo w > "$d6/w.txt"
python3 "$SHIP" mark-done --repo "$d6" --summary w >/dev/null
o1=$(stop_payload "$d6" s6 "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
o2=$(stop_payload "$d6" s6 "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$o1" "6. first Stop → review block"
assert_absent '"decision": "block"' "$o2" "6. review not done, state unchanged → no re-block"

# --- 7. B3: a no-CLI forge surfaces the PR URL on a rendered channel (systemMessage), not bare stdout
d7="$ROOT/b3"; new_repo "$d7" --remote bitbucket.org; git -C "$d7" checkout -q -b feat
printf '{"gate":"true"}' > "$d7/.git/ship-when-done.json"
python3 "$SHIP" baseline --repo "$d7" --session s7 >/dev/null
echo x > "$d7/x.txt"
python3 "$SHIP" mark-done --repo "$d7" --summary "bb work" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d7" --session s7)
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "systemMessage" in d' 2>/dev/null \
  && ok "7. engage output is hook JSON with a systemMessage" || ko "7. engage output is hook JSON with a systemMessage — got [$out]"
assert_contains 'pull-requests/new' "$out" "7. the bitbucket PR-creation URL is in the rendered message"

# --- 8. visibility: done but NO gate detectable → the withheld PR is said out loud ------------------
d8="$ROOT/nogate"; new_repo "$d8" --remote; git -C "$d8" checkout -q -b feat
python3 "$SHIP" baseline --repo "$d8" --session s8 >/dev/null
echo x > "$d8/x.txt"
python3 "$SHIP" mark-done --repo "$d8" --summary "no gate here" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d8" --session s8)
assert_contains 'no-gate-detected' "$out" "8. no detectable gate → withheld reason names it"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "no-gate" in d.get("systemMessage","")' 2>/dev/null \
  && ok "8. the notice is on the rendered channel" || ko "8. the notice is on the rendered channel — got [$out]"

# --- 9. detect_gate is stack-horizontal, not a JS/PHP allowlist -------------------------------------
gd(){ python3 -c "
import sys, importlib.util as u
sp = u.spec_from_file_location('ship', '$SHIP'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
print(m.detect_gate(sys.argv[1], {'gate': None}) or 'NONE')" "$1"; }
g="$ROOT/g"; mkdir -p "$g/go" "$g/rust" "$g/py" "$g/mk" "$g/yarn" "$g/phpno" "$g/phpyes"
echo 'module t' > "$g/go/go.mod"
echo '[package]' > "$g/rust/Cargo.toml"
printf '[tool.pytest.ini_options]\n' > "$g/py/pyproject.toml"
printf 'test:\n\ttrue\n' > "$g/mk/Makefile"
printf '{"scripts":{"test":"jest"}}' > "$g/yarn/package.json"; : > "$g/yarn/yarn.lock"
printf '{"require":{}}' > "$g/phpno/composer.json"
printf '{"scripts":{"test":"phpunit"}}' > "$g/phpyes/composer.json"
assert_eq "go test ./..." "$(gd "$g/go")" "9. go.mod → go test"
assert_eq "cargo test" "$(gd "$g/rust")" "9. Cargo.toml → cargo test"
assert_contains "pytest" "$(gd "$g/py")" "9. pyproject pytest config → pytest"
assert_eq "make test" "$(gd "$g/mk")" "9. Makefile test target → make test"
assert_eq "yarn test" "$(gd "$g/yarn")" "9. yarn.lock → yarn, not npm"
assert_eq "NONE" "$(gd "$g/phpno")" "9. composer.json without a test script → no blind 'composer test'"
assert_eq "composer test" "$(gd "$g/phpyes")" "9. composer.json with a test script → composer test"

# --- 10. a timed-out gate is transient evidence: distinct reason, never cached ----------------------
d10="$ROOT/b10"; new_repo "$d10" --remote; git -C "$d10" checkout -q -b feat
printf '{"gate":"echo run >> %s; sleep 3","gate_timeout":1}' "$ROOT/gate10.log" > "$d10/.git/ship-when-done.json"; : > "$ROOT/gate10.log"
python3 "$SHIP" baseline --repo "$d10" --session s10 >/dev/null
echo w > "$d10/w.txt"
python3 "$SHIP" mark-done --repo "$d10" --summary w >/dev/null
out=$(python3 "$SHIP" engage --repo "$d10" --session s10)
assert_contains 'gate-timeout' "$out" "10. timed-out gate → distinct visible reason (not gate-not-green)"
python3 "$SHIP" engage --repo "$d10" --session s10 >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10.log" | tr -d ' ')" "10. timeout NOT cached → gate re-runs on the next Stop"

# --- 10b. real usage: a transient red gate self-heals — only GREEN verdicts are cached --------------
d="$ROOT/b10b"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"gate":"echo run >> %s; test -f %s"}' "$ROOT/gate10b.log" "$ROOT/healed" > "$d/.git/ship-when-done.json"
: > "$ROOT/gate10b.log"; rm -f "$ROOT/healed"
python3 "$SHIP" baseline --repo "$d" --session sb >/dev/null
echo w > "$d/w.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "transient" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d" --session sb)
assert_contains 'gate-not-green' "$out" "10b. red gate → PR withheld, visibly"
assert_contains '"verdict": "fail"' "$(cat "$d/.git/swd-gate.json" 2>/dev/null)" "10b. the gate run leaves evidence (verdict persisted)"
touch "$ROOT/healed"
before=$(pr_creates)
python3 "$SHIP" engage --repo "$d" --session sb >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10b.log" | tr -d ' ')" "10b. fail NOT cached → gate re-ran on the idle Stop and healed"
assert_eq "$((before + 1))" "$(pr_creates)" "10b. healed gate → the PR opens without any tree change"
python3 "$SHIP" engage --repo "$d" --session sb >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10b.log" | tr -d ' ')" "10b. green verdict IS cached → no re-run on the next idle Stop"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
