#!/usr/bin/env bash
# mr-watchdog test suite. The watcher is read-only (polls CI, surfaces the failing log) — it never
# commits/pushes/merges and runs no model. Stubs gh/glab on PATH; throwaway repos with a bare remote.
set -u
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)/scripts"
WATCH="$SCRIPTS/watch.py"
ROOT="$(mktemp -d)"; PASS=0; FAIL=0

ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
assert_contains(){ case "$2" in *"$1"*) ok "$3";; *) ko "$3 — expected [$1] in [$2]";; esac; }
assert_absent(){ case "$2" in *"$1"*) ko "$3 — unexpected [$1]";; *) ok "$3";; esac; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || ko "$3 — expected [$1] got [$2]"; }

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
ci="${STUB_CI:-pending}"
case "$1 $2" in
  "pr view")   echo "{\"state\":\"${STUB_MR_STATE:-OPEN}\"}";;
  "pr checks") case "$ci" in success) echo '[{"bucket":"pass"}]';; failed) echo '[{"bucket":"fail"}]';; pending) echo '[{"bucket":"pending"}]';; none) echo '[]';; esac;;
  "run list")  echo '[{"databaseId":1}]';;
  "run view")  echo "JOB FAILED: AssertionError at app.py:7";;
  *) exit 0;;
esac
EOF
cat > "$ROOT/bin/glab" <<'EOF'
#!/usr/bin/env bash
ci="${STUB_CI:-pending}"
case "$1 $2" in
  "mr list")   echo "[{\"state\":\"${STUB_MR_STATE_GL:-opened}\"}]";;
  "ci status") if [ "$ci" = none ]; then echo "no pipeline found"; exit 1; else echo "status: $ci"; fi;;
  "ci trace")  echo "JOB FAILED: AssertionError";;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh" "$ROOT/bin/glab"; export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir [$2=host] [$3=branch]
  local d="$1" host="${2:-github.com}" br="${3:-feat}"
  mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" config remote.origin.pushurl "$d.git"
  git -C "$d" config remote.origin.url "https://$host/test/repo.git"
  git -C "$d" push -q -u origin main 2>/dev/null
  [ "$br" != main ] && git -C "$d" checkout -q -b "$br"
  printf '{}' > "$d/.mr-watchdog.json"
}
tick(){ python3 "$WATCH" tick --repo "$1" 2>&1; }
guard_reason(){ python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch
try:
    watch.guard_state('$1', dict(watch.load_config('$1'))); print('OK')
except ValueError as e: print(str(e))"; }
count(){ git -C "$1" rev-list --count "$2" 2>/dev/null || echo -1; }

echo "mr-watchdog tests"

# 1. pure: fake-green pattern detection (used by `verify`)
cat > "$ROOT/t1.py" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"1. "+m)
bad=["--no-verify","run || true","@pytest.mark.skip","it.skip('x')","# type: ignore","allow_failure: true",
     "continue-on-error: true","@ts-ignore","@ts-expect-error","xit('x')",".skip(","assert True","--maxfail=0",
     "when: never","skip_tests=1","eslint-disable no-console","self.skipTest('x')"]
for b in bad: ck(watch.bypass_in_diff(b), "fake-green flagged: "+b[:24])
good=["def f(): return 1","assert x==2","# noqa: E501 url","fixed the off-by-one","const y=2","return None"]
for g in good: ck(watch.bypass_in_diff(g) is None, "honest change allowed: "+g[:24])
ck(watch.added_lines("+++ b/f\n+bad || true\n-old\n ctx")=="bad || true","added_lines extracts + only")
PY
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t1.py" "$SCRIPTS")

# 2. pure: ci_status mapping (github + gitlab) + mr_open via stubs
cat > "$ROOT/t2.py" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); R=sys.argv[2]; import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"2. "+m)
for forge in ("github","gitlab"):
    for want in ("success","failed","pending","none"):
        os.environ["STUB_CI"]=want
        ck(watch.ci_status(R, forge, "feat")==want, f"ci_status {forge}:{want}")
ck(watch.mr_open(R,"github","feat") is True, "mr_open github OPEN")
os.environ["STUB_MR_STATE"]="MERGED"; ck(watch.mr_open(R,"github","feat") is False, "mr_open github not-open")
PY
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t2.py" "$SCRIPTS" "$ROOT")

# 3. guard refusals
d="$ROOT/g_main"; new_repo "$d" github.com main
assert_eq "on-default-branch" "$(guard_reason "$d")" "3. refuse on default branch"
d="$ROOT/g_dev"; new_repo "$d" github.com develop
assert_eq "on-default-branch" "$(guard_reason "$d")" "3. refuse on a common trunk (develop)"
d="$ROOT/g_feat"; new_repo "$d" github.com feat
assert_eq "OK" "$(guard_reason "$d")" "3. allow on a feature branch"
d="$ROOT/g_wip"; new_repo "$d" github.com wip/spike
assert_eq "skip-marker" "$(guard_reason "$d")" "3. refuse a wip/ branch"
d="$ROOT/g_det"; new_repo "$d" github.com feat; git -C "$d" checkout -q --detach HEAD
assert_eq "detached-or-unborn" "$(guard_reason "$d")" "3. refuse detached HEAD"
d="$ROOT/g_unk"; new_repo "$d" example.com feat
assert_eq "no-forge-cli" "$(guard_reason "$d")" "3. refuse unknown forge (no CLI)"

# 4. tick: green / pending / no-mr / branch-changed
d="$ROOT/t_green"; new_repo "$d"; assert_contains '"green"' "$(STUB_CI=success tick "$d")" "4. CI success → green"
d="$ROOT/t_pend"; new_repo "$d";  assert_contains '"continue"' "$(STUB_CI=pending tick "$d")" "4. CI pending → continue"
d="$ROOT/t_nomr"; new_repo "$d";  assert_contains '"no-mr"' "$(STUB_CI=failed STUB_MR_STATE=CLOSED tick "$d")" "4. no open MR → no-mr"

# 5. tick: failed → needs-fix WITH the failing log, and READ-ONLY (no commit, HEAD unchanged)
d="$ROOT/t_fail"; new_repo "$d"; before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains '"needs-fix"' "$out" "5. CI failed → needs-fix (handoff, no autonomous fix)"
assert_contains 'AssertionError' "$out" "5. the failing job log is carried into the handoff"
assert_eq "$before" "$(count "$d" HEAD)" "5. READ-ONLY: tick made no commit"
git -C "$d" diff --quiet && ok "5. READ-ONLY: working tree untouched" || ko "5. working tree untouched"

# 6. verify: honest fix passes; every fake-green is caught (exit 1)
d="$ROOT/v"; new_repo "$d"
printf 'def pay(a,b):\n    return a+b\n' > "$d/app.py"; mkdir -p "$d/tests"
printf 'from app import pay\ndef test_pay():\n    assert pay(2,2)==4\n' > "$d/tests/test_app.py"
git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm base
printf 'def pay(a,b):\n    return a+b  # real fix\n' > "$d/app.py"   # honest edit
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "6. honest fix → verify passes (exit 0)"
assert_contains 'no bypass' "$out" "6. honest fix → reported clean"
git -C "$d" checkout -- app.py
printf 'run-tests || true\n' >> "$d/ci.sh"                          # bypass marker in a new file
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "6. '|| true' → verify fails (exit 1)"
assert_contains 'fake-green' "$out" "6. bypass marker flagged as fake-green"
rm -f "$d/ci.sh"
git -C "$d" rm -q tests/test_app.py                                  # delete a test
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "6. deleting a test → verify fails"
assert_contains 'deleted-test' "$out" "6. deleted test flagged"
git -C "$d" reset -q --hard HEAD
printf 'from app import pay\ndef test_pay():\n    assert True\n' > "$d/tests/test_app.py"   # gut a test
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "6. gutting a test (assert True) → verify fails"
assert_contains 'green' "$out" "6. weakened/assert-True test flagged"

# 7. announce: surfaces the handoff (with log) once; green; silent while watching
d="$ROOT/a"; new_repo "$d"
printf '{"state":"needs-fix","branch":"feat","log":"BOOM at app.py:7","announced":false}' > "$d/.git/mr-watchdog-status.json"
a1=$(python3 "$WATCH" announce --repo "$d"); a2=$(python3 "$WATCH" announce --repo "$d")
assert_contains 'CAUSE RACINE' "$a1" "7. needs-fix → surfaces the root-cause handoff"
assert_contains 'BOOM at app.py:7' "$a1" "7. handoff includes the failing log"
assert_contains 'verify' "$a1" "7. handoff tells the live session to self-check with verify"
assert_eq "" "$a2" "7. handoff announced only once"
printf '{"state":"green","announced":false}' > "$d/.git/mr-watchdog-status.json"
assert_contains "ok c'est bon" "$(python3 "$WATCH" announce --repo "$d")" "7. green → ok c'est bon"
printf '{"state":"watching","announced":false}' > "$d/.git/mr-watchdog-status.json"
assert_eq "" "$(python3 "$WATCH" announce --repo "$d")" "7. while watching → silent"

# 8. lock + reset
d="$ROOT/l"; new_repo "$d"
python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import os,watch
print('dead', watch.watcher_alive('$d'))
watch.write_lock('$d', os.getpid()); print('self', watch.watcher_alive('$d'))
print('acq2', watch.acquire_lock('$d'))" > "$ROOT/l.out"
assert_contains 'dead False' "$(cat "$ROOT/l.out")" "8. no lock → not alive"
assert_contains 'self True' "$(cat "$ROOT/l.out")" "8. live pid → alive"
assert_contains 'acq2 False' "$(cat "$ROOT/l.out")" "8. acquire refuses when a live watcher holds the lock"
printf '{"state":"green"}' > "$d/.git/mr-watchdog-status.json"
python3 "$WATCH" reset --repo "$d" >/dev/null
[ ! -f "$d/.git/mr-watchdog-status.json" ] && ok "8. reset clears status" || ko "8. reset clears status"

# 9. opt-in gating + start no-ops without an open MR
d="$ROOT/o"; new_repo "$d"; rm -f "$d/.mr-watchdog.json"
assert_eq "" "$(env -u MR_WATCHDOG python3 "$WATCH" start --repo "$d" 2>&1)" "9. no opt-in → start silent"
d="$ROOT/o2"; new_repo "$d"
assert_absent 'watching' "$(STUB_MR_STATE=CLOSED python3 "$WATCH" start --repo "$d" --verbose 2>&1)" "9. opted-in but no MR → no watcher"

# 10. GUARDRAILS: the watcher is read-only — no commit / push / merge anywhere in the source
grep -Eq "['\"]merge['\"]" "$WATCH" && ko "10. never merges (no merge command)" || ok "10. never merges (no merge command in source)"
grep -Eq 'git[^\n]*(commit|push)|"-A"|reset[^\n]*hard|checkout[^\n]*--' "$WATCH" && ko "10. read-only: no git mutation in the watcher" || ok "10. read-only: never commits, pushes, or mutates the tree"
grep -q 'claude' "$WATCH" && ko "10. no model invocation (no headless billing)" || ok "10. runs no model itself (no 'claude' anywhere — zero headless billing)"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
