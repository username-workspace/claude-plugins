#!/usr/bin/env bash
# mr-watchdog test suite. Stubs gh/glab/the fixer on PATH; throwaway git repos with a bare remote.
# Drives the tick loop deterministically (CI status via a file the fixer flips), exercises every
# guardrail (anti-bypass, never-default, never-merge, bounded attempts) on real repos.
set -u
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)/scripts"
WATCH="$SCRIPTS/watch.py"
ROOT="$(mktemp -d)"; PASS=0; FAIL=0
CIFILE="$ROOT/ci_state"; echo pending > "$CIFILE"
export STUB_CI_FILE="$CIFILE"

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
ci="\${STUB_CI:-}"; [ -z "\$ci" ] && [ -n "\${STUB_CI_FILE:-}" ] && [ -f "\$STUB_CI_FILE" ] && ci="\$(cat "\$STUB_CI_FILE")"; ci="\${ci:-pending}"
case "\$1 \$2" in
  "pr view")   echo "{\"state\":\"\${STUB_MR_STATE:-OPEN}\"}";;
  "pr checks") case "\$ci" in success) echo '[{"bucket":"pass"}]';; failed) echo '[{"bucket":"fail"}]';; pending) echo '[{"bucket":"pending"}]';; none) echo '[]';; esac;;
  "run list")  echo '[{"databaseId":123}]';;
  "run view")  echo "FAILING LOG: AssertionError at app.py:42";;
  *) exit 0;;
esac
EOF
cat > "$ROOT/bin/glab" <<EOF
#!/usr/bin/env bash
ci="\${STUB_CI:-}"; [ -z "\$ci" ] && [ -n "\${STUB_CI_FILE:-}" ] && [ -f "\$STUB_CI_FILE" ] && ci="\$(cat "\$STUB_CI_FILE")"; ci="\${ci:-pending}"
case "\$1 \$2" in
  "mr list")  echo "[{\"state\":\"\${STUB_MR_STATE_GL:-opened}\"}]";;
  "ci status") if [ "\$ci" = none ]; then echo "no pipeline found"; exit 1; else echo "Pipeline status: \$ci"; fi;;
  "ci trace") echo "FAILING LOG: AssertionError";;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh" "$ROOT/bin/glab"; export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir [$2=host github.com|gitlab.com] [$3=branch]
  local d="$1" host="${2:-github.com}" br="${3:-feat}"
  mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" config remote.origin.pushurl "$d.git"
  git -C "$d" config remote.origin.url "https://$host/test/repo.git"
  git -C "$d" push -q -u origin main 2>/dev/null
  [ "$br" != main ] && git -C "$d" checkout -q -b "$br"
  printf '{"max_fix_attempts":3}' > "$d/.mr-watchdog.json"
}
tick(){ python3 "$WATCH" tick --repo "$1" 2>&1; }
guard_reason(){ python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch
try:
    watch.guard_state('$1', dict(watch.load_config('$1'))); print('OK')
except ValueError as e: print(str(e))"; }
count(){ git -C "$1" rev-list --count "$2" 2>/dev/null || echo -1; }

echo "mr-watchdog tests"

# 1. pure: anti-bypass gate
cat > "$ROOT/t1.py" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"1. "+m)
bad=["--no-verify","run || true","@pytest.mark.skip","it.skip('x')","# type: ignore","allow_failure: true",
     "continue-on-error: true","@ts-ignore","xit('x')",".skip(",  "skip_tests=1","eslint-disable no-console"]
for b in bad: ck(watch.bypass_in_diff(b), "bypass blocked: "+b[:24])
good=["def f(): return 1","assert x==2","# noqa: E501 long-url","fixed the regex","const y=2","return None"]
for g in good: ck(watch.bypass_in_diff(g) is None, "clean allowed: "+g[:24])
ck(watch.added_lines("+++ b/f\n+bad || true\n-old\n ctx")=="bad || true","added_lines extracts + only")
PY
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t1.py" "$SCRIPTS")

# 2. pure: ci_status mapping (github + gitlab) via stubs
cat > "$ROOT/t2.py" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); R=sys.argv[2]; import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"2. "+m)
os.environ.pop("STUB_CI_FILE", None)
for forge in ("github","gitlab"):
    for want in ("success","failed","pending","none"):
        os.environ["STUB_CI"]=want
        got=watch.ci_status(R, forge, "feat")
        ck(got==want, f"ci_status {forge}:{want} -> {got}")
ck(watch.mr_open(R,"github","feat") is True, "mr_open github OPEN")
os.environ["STUB_MR_STATE"]="MERGED"; ck(watch.mr_open(R,"github","feat") is False, "mr_open github not-open")
PY
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t2.py" "$SCRIPTS" "$ROOT")

# 3. guard refusals
d="$ROOT/g_main"; new_repo "$d" github.com main
assert_eq "on-default-branch" "$(guard_reason "$d")" "3. refuse on default branch (main)"
d="$ROOT/g_dev"; new_repo "$d" github.com develop
assert_eq "on-default-branch" "$(guard_reason "$d")" "3. refuse on a common trunk (develop)"
d="$ROOT/g_feat"; new_repo "$d" github.com feat
assert_eq "OK" "$(guard_reason "$d")" "3. allow on a feature branch"
d="$ROOT/g_wip"; new_repo "$d" github.com wip/spike
assert_eq "skip-marker" "$(guard_reason "$d")" "3. refuse a wip/ branch"
d="$ROOT/g_det"; new_repo "$d" github.com feat; git -C "$d" checkout -q --detach HEAD
assert_eq "detached-or-unborn" "$(guard_reason "$d")" "3. refuse detached HEAD"
d="$ROOT/g_norem"; mkdir -p "$d"; git -C "$d" init -q -b feat; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
echo x > "$d/a"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm i
assert_eq "no-remote" "$(guard_reason "$d")" "3. refuse with no remote"
d="$ROOT/g_unk"; new_repo "$d" example.com feat
assert_eq "no-forge-cli" "$(guard_reason "$d")" "3. refuse unknown forge (no CLI)"

# 4. tick: green / pending / no-mr
d="$ROOT/t_green"; new_repo "$d"; STUB_CI=success assert_contains '"green"' "$(STUB_CI=success tick "$d")" "4. CI success → green"
d="$ROOT/t_pend"; new_repo "$d"; assert_contains '"continue"' "$(STUB_CI=pending tick "$d")" "4. CI pending → continue"
d="$ROOT/t_nomr"; new_repo "$d"; assert_contains '"no-mr"' "$(STUB_CI=failed STUB_MR_STATE=CLOSED tick "$d")" "4. no open MR → no-mr"

# 5. tick: failed → benign root-cause fix → commit + push, attempts++
d="$ROOT/t_fix"; new_repo "$d"
printf '{"max_fix_attempts":3,"fix_command":"printf \\"value = 1\\\\n\\" >> README.md"}' > "$d/.mr-watchdog.json"
before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains '"continue"' "$out" "5. failed → fix applied → continue"
assert_contains '"attempts": 1' "$out" "5. attempts incremented"
assert_contains '"fixed": true' "$out" "5. fix flagged"
assert_eq "$((before+1))" "$(count "$d" HEAD)" "5. exactly one fix commit"
git -C "$d.git" rev-parse --verify -q feat >/dev/null && ok "5. fix pushed to the remote" || ko "5. fix pushed"
git -C "$d" diff --quiet && ok "5. working tree clean after fix" || ko "5. working tree clean"
git -C "$d" log -1 --pretty=%B | grep -qi 'fix' && ok "5. commit message is a fix" || ko "5. commit message"

# 6. tick: failed → fixer attempts a BYPASS → blocked, reverted, NO commit  [the soul]
d="$ROOT/t_bypass"; new_repo "$d"
printf '{"fix_command":"printf \\"run-tests || true\\\\n\\" >> ci.sh"}' > "$d/.mr-watchdog.json"
before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains 'blocked:bypass' "$out" "6. bypass fix → blocked:bypass (refused)"
assert_eq "$before" "$(count "$d" HEAD)" "6. NO commit on a bypass fix"
[ ! -f "$d/ci.sh" ] && ok "6. bypass change reverted from the worktree" || ko "6. bypass reverted"
git -C "$d" diff --quiet && ok "6. tracked tree clean after revert" || ko "6. tracked tree clean after revert"

# 7. tick: fixer makes NO change → blocked:nofix
d="$ROOT/t_nofix"; new_repo "$d"
printf '{"fix_command":"true"}' > "$d/.mr-watchdog.json"
assert_contains 'blocked:nofix' "$(STUB_CI=failed tick "$d")" "7. empty fix → blocked:nofix"

# 8. tick: fixer exits non-zero → blocked:fixer, reverted
d="$ROOT/t_fixerr"; new_repo "$d"
printf '{"fix_command":"echo half >> README.md; exit 3"}' > "$d/.mr-watchdog.json"
before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains 'blocked:fixer' "$out" "8. fixer error → blocked:fixer"
assert_eq "$before" "$(count "$d" HEAD)" "8. no commit when the fixer errors"
git -C "$d" diff --quiet && ok "8. partial change reverted" || ko "8. partial change reverted"

# 9. tick: attempts already at the cap → failed-exhausted, no fixer run
d="$ROOT/t_exhaust"; new_repo "$d"
printf '{"max_fix_attempts":1,"fix_command":"printf bad >> README.md"}' > "$d/.mr-watchdog.json"
printf '{"attempts":1}' > "$d/.git/mr-watchdog-status.json"
before=$(count "$d" HEAD)
assert_contains 'failed-exhausted' "$(STUB_CI=failed tick "$d")" "9. attempts at cap → failed-exhausted"
assert_eq "$before" "$(count "$d" HEAD)" "9. no fix attempted past the cap"

# 10. end-to-end: failed → fix flips CI → second tick sees green
d="$ROOT/t_e2e"; new_repo "$d"
printf '{"fix_command":"printf ok >> README.md; echo success > %s"}' "$CIFILE" > "$d/.mr-watchdog.json"
echo failed > "$CIFILE"
out1=$(tick "$d"); assert_contains '"continue"' "$out1" "10. round 1: failed → fix → continue"
out2=$(tick "$d"); assert_contains '"green"' "$out2" "10. round 2: CI now green"
echo pending > "$CIFILE"

# 11. gitlab forge: failed → fix → continue (parses glab output)
d="$ROOT/t_gl"; new_repo "$d" gitlab.com
printf '{"fix_command":"printf gl >> README.md"}' > "$d/.mr-watchdog.json"
assert_contains '"continue"' "$(STUB_CI=failed tick "$d")" "11. gitlab failed → fix → continue"

# 12. lock + status + announce
d="$ROOT/t_lock"; new_repo "$d"
python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch
print('alive_empty', watch.watcher_alive('$d'))
watch.write_lock('$d', 999999999); print('alive_dead', watch.watcher_alive('$d'))
import os; watch.write_lock('$d', os.getpid()); print('alive_self', watch.watcher_alive('$d'))
watch.clear_lock('$d'); print('alive_cleared', watch.watcher_alive('$d'))" > "$ROOT/lock.out"
assert_contains 'alive_empty False' "$(cat "$ROOT/lock.out")" "12. no lock → not alive"
assert_contains 'alive_dead False' "$(cat "$ROOT/lock.out")" "12. stale pid → not alive"
assert_contains 'alive_self True' "$(cat "$ROOT/lock.out")" "12. live pid → alive"
assert_contains 'alive_cleared False' "$(cat "$ROOT/lock.out")" "12. cleared → not alive"

# 13. announce surfaces a terminal result exactly once
d="$ROOT/t_ann"; new_repo "$d"
printf '{"state":"green","announced":false}' > "$d/.git/mr-watchdog-status.json"
a1=$(python3 "$WATCH" announce --repo "$d"); a2=$(python3 "$WATCH" announce --repo "$d")
assert_contains "ok c'est bon" "$a1" "13. announce surfaces green once"
assert_eq "" "$a2" "13. second announce is silent (already announced)"
printf '{"state":"watching","announced":false}' > "$d/.git/mr-watchdog-status.json"
assert_eq "" "$(python3 "$WATCH" announce --repo "$d")" "13. non-terminal state is not announced"

# 14. opt-in gating on start
d="$ROOT/t_optin"; new_repo "$d"; rm -f "$d/.mr-watchdog.json"
assert_eq "" "$(env -u MR_WATCHDOG python3 "$WATCH" start --repo "$d" 2>&1)" "14. no opt-in → start is silent"

# 15. start no-ops when there is no open MR (even opted-in)
d="$ROOT/t_nostart"; new_repo "$d"
assert_absent 'watching' "$(STUB_MR_STATE=CLOSED python3 "$WATCH" start --repo "$d" --verbose 2>&1)" "15. opted-in but no MR → no watcher"

# 16. GUARDRAIL: there is no merge path anywhere in the source
grep -Eq '(gh[^\n]*pr[^\n]*merge|glab[^\n]*mr[^\n]*merge|"merge"|git.*merge)' "$WATCH" && ko "16. GUARDRAIL: no merge path" || ok "16. GUARDRAIL: never merges (no merge path in source)"
# 16b. tick: fixer DELETES a test file → blocked:bypass (deleted-test), restored on revert
d="$ROOT/t_deltest"; new_repo "$d"
mkdir -p "$d/tests"; echo 'def test_x():' > "$d/tests/test_app.py"; echo '    assert pay()==4' >> "$d/tests/test_app.py"
git -C "$d" add tests/; git -C "$d" -c commit.gpgsign=false commit -qm "add test"
printf '{"fix_command":"git rm -q tests/test_app.py"}' > "$d/.mr-watchdog.json"
before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains 'deleted-test' "$out" "16b. deleting a test → blocked:bypass (deleted-test)"
assert_eq "$before" "$(count "$d" HEAD)" "16b. no commit when a test is deleted"
[ -f "$d/tests/test_app.py" ] && ok "16b. deleted test restored on revert" || ko "16b. deleted test restored"

# 16c. tick: fixer WEAKENS a test (drops an assertion) → blocked:bypass (weakened-test)  [review H1]
d="$ROOT/t_weak"; new_repo "$d"
mkdir -p "$d/tests"; printf 'def test_pay():\n    assert pay(2,2)==4\n' > "$d/tests/test_p.py"
git -C "$d" add tests/; git -C "$d" -c commit.gpgsign=false commit -qm "add test"
printf '{"fix_command":"printf '\''def test_pay():\\n    assert True\\n'\'' > tests/test_p.py"}' > "$d/.mr-watchdog.json"
before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains 'weakened-test' "$out" "16c. gutting a test (assert→assert True) → blocked:bypass (weakened-test)"
assert_eq "$before" "$(count "$d" HEAD)" "16c. no commit when a test is gutted"
grep -q 'pay(2,2)' "$d/tests/test_p.py" && ok "16c. original assertion restored on revert" || ko "16c. assertion restored"

# 16d. tick: fixer adds `assert True` in a new file → blocked:bypass (pattern)  [review H1]
d="$ROOT/t_at"; new_repo "$d"
printf '{"fix_command":"printf '\''assert True\\n'\'' >> faked.py"}' > "$d/.mr-watchdog.json"
assert_contains 'blocked:bypass' "$(STUB_CI=failed tick "$d")" "16d. assert True → blocked:bypass"

# 16e. GUARDRAIL: branch switched out from under a fix → no commit on the wrong branch  [review C1]
d="$ROOT/t_switch"; new_repo "$d"
printf '{"fix_command":"printf x >> README.md"}' > "$d/.mr-watchdog.json"
mainbefore=$(count "$d" main)
out=$(python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch
cfg=watch.load_config('$d'); b,f,r=watch.guard_state('$d',cfg)
import subprocess; subprocess.run(['git','-C','$d','checkout','-q','main'])
print(watch.tick('$d',cfg,b,f,r))" 2>&1)
assert_contains "branch-changed" "$out" "16e. branch switched mid-cycle → branch-changed (no fix)"
assert_eq "$mainbefore" "$(count "$d" main)" "16e. nothing committed on the default branch"

# 16f. tick: failed CI but DIRTY tree → blocked:dirty-tree, user's work untouched  [review C2/H2]
d="$ROOT/t_dirty"; new_repo "$d"
printf '{"fix_command":"printf x >> README.md"}' > "$d/.mr-watchdog.json"
printf 'precious local work\n' >> "$d/README.md"     # user's uncommitted edit
out=$(STUB_CI=failed tick "$d")
assert_contains 'dirty-tree' "$out" "16f. failed + dirty tree → blocked:dirty-tree (no fixer)"
grep -q 'precious local work' "$d/README.md" && ok "16f. user's uncommitted work preserved" || ko "16f. user work preserved"

# 16g. start refuses to relaunch a branch already exhausted at the same HEAD; reset re-arms  [review C3]
d="$ROOT/t_sticky"; new_repo "$d"
head=$(git -C "$d" rev-parse HEAD)
printf '{"state":"exhausted","branch":"feat","attempts":3,"head":"%s"}' "$head" > "$d/.git/mr-watchdog-status.json"
out=$(STUB_CI=failed python3 "$WATCH" start --repo "$d" --verbose 2>&1)
assert_contains 'exhausted' "$out" "16g. exhausted branch @HEAD → start refuses to relaunch"
[ ! -f "$d/.git/mr-watchdog.lock" ] && ok "16g. refused → no watcher spawned" || ko "16g. no watcher spawned"
python3 "$WATCH" reset --repo "$d" >/dev/null
[ ! -f "$d/.git/mr-watchdog-status.json" ] && ok "16g. reset clears status (re-arms the branch)" || ko "16g. reset clears status"
out=$(STUB_CI=failed python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch
cfg=watch.load_config('$d'); b,f,r=watch.guard_state('$d',cfg)
prev={'state':'exhausted','branch':b,'head':'deadbeef'}
print('refused' if (prev.get('branch')==b and prev.get('head')==watch.head_sha('$d')) else 'allowed')")
assert_eq "allowed" "$out" "16g. a stale recorded HEAD no longer matches → not refused"

# 16h. attempts carry across restart ONLY for the same branch+head → re-arm gets a fresh budget  [review N1]
cat > "$ROOT/t16h.py" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"16h. "+m)
p={"branch":"feat","head":"abc","attempts":3}
ck(watch.carried_attempts(p,"feat","abc")==3, "same branch+head -> carry count (bound survives a crash-restart)")
ck(watch.carried_attempts(p,"feat","def")==0, "head advanced (user pushed) -> fresh budget (re-arm actually works)")
ck(watch.carried_attempts(p,"other","abc")==0, "different branch -> fresh budget")
ck(watch.carried_attempts({},"feat","abc")==0, "no prior status -> 0")
PY
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t16h.py" "$SCRIPTS")

# 17. GUARDRAIL: never force-push
grep -Eq -- '--force|force-with-lease|push -f' "$WATCH" && ko "17. GUARDRAIL: no force-push" || ok "17. GUARDRAIL: never force-pushes"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
