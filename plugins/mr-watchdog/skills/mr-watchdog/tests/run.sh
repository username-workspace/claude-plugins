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

# 7. run (the bg watcher): poll until the pipeline resolves, then exit with the verdict (read-only)
d="$ROOT/run"; new_repo "$d"; before=$(count "$d" HEAD)
out=$(STUB_CI=success python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_contains "ok, all good" "$out" "7. green → the wake word"
assert_eq 0 "$rc" "7. green → exit 0"
out=$(STUB_CI=failed python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_contains 'ROOT CAUSE' "$out" "7. red → hands the failure back to fix the root cause"
assert_contains 'AssertionError' "$out" "7. red → carries the failing job log"
assert_contains 'verify' "$out" "7. red → verify before commit"
assert_eq 1 "$rc" "7. red → exit 1 (so the harness re-invokes with a failure)"
assert_eq "$before" "$(count "$d" HEAD)" "7. READ-ONLY: the watcher made no commit"
git -C "$d" diff --quiet && ok "7. READ-ONLY: working tree untouched" || ko "7. working tree untouched"
assert_contains 'no open merge request' "$(STUB_CI=failed STUB_MR_STATE=CLOSED python3 "$WATCH" run --repo "$d" 2>&1)" "7. MR closed → watcher exits, does not watch"
printf '{"on_red":"notify"}' > "$d/.mr-watchdog.json"
out=$(STUB_CI=failed python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_absent 'ROOT CAUSE' "$out" "7. on_red=notify → no fix directive"
assert_contains 'CI red' "$out" "7. on_red=notify → passive red report"
assert_eq 1 "$rc" "7. on_red=notify → still exit 1"
printf '{}' > "$d/.mr-watchdog.json"

# 9. engagement: a branch is watched only if THIS session pushed it (no opt-in file needed)
d="$ROOT/eng"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session S)" "9. baseline, no new push → not engaged (just visiting)"
echo z > "$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
assert_eq "yes" "$(python3 "$WATCH" engaged --repo "$d" --session S)" "9. session pushed the branch → engaged"
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session OTHER)" "9. a different session (no baseline) → not engaged"
printf '{"enabled":false}' > "$d/.mr-watchdog.json"
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session S)" "9. enabled:false opts the repo out"
dm="$ROOT/em"; new_repo "$dm" github.com main
python3 "$WATCH" baseline --repo "$dm" --session S >/dev/null
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$dm" --session S)" "9. default branch → never engaged"
d="$ROOT/o2"; new_repo "$d"
assert_contains 'no open merge request' "$(STUB_MR_STATE=CLOSED python3 "$WATCH" run --repo "$d" 2>&1)" "9. no open MR → the watcher exits immediately (nothing to watch)"

# 10. GUARDRAILS: the watcher is read-only — no commit / push / merge anywhere in the source
grep -Eq "['\"]merge['\"]" "$WATCH" && ko "10. never merges (no merge command)" || ok "10. never merges (no merge command in source)"
grep -Eq 'git[^\n]*(commit|push)|"-A"|reset[^\n]*hard|checkout[^\n]*--' "$WATCH" && ko "10. read-only: no git mutation in the watcher" || ok "10. read-only: never commits, pushes, or mutates the tree"
grep -q 'claude' "$WATCH" && ko "10. runs no model itself" || ok "10. runs no model itself (no 'claude' anywhere in the watcher)"

# 11. hook (Stop-hook launch trigger): engaged + open MR + live CI → block to launch the bg watcher
d="$ROOT/hk"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w
git -C "$d" push -q origin feat 2>/dev/null     # this session pushed the branch → engaged
out=$(STUB_CI=pending python3 "$WATCH" hook --repo "$d" --session S)
assert_contains '"decision": "block"' "$out" "11. engaged + open MR + CI running → block to launch a bg watcher"
assert_contains 'run_in_background' "$out" "11. the block tells the session to launch it in the background"
assert_contains 'run --repo' "$out" "11. the block carries the watcher command"
assert_eq "" "$(STUB_CI=pending python3 "$WATCH" hook --repo "$d" --session S)" "11. asked once per HEAD → silent next time"
assert_eq "" "$(STUB_CI=pending python3 "$WATCH" hook --repo "$d" --session OTHER)" "11. different session (not engaged) → silent"
d="$ROOT/hk2"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
assert_eq "" "$(STUB_CI=none python3 "$WATCH" hook --repo "$d" --session S)" "11. no pipeline yet → silent (nothing to watch)"
assert_eq "" "$(STUB_CI=pending STUB_MR_STATE=CLOSED python3 "$WATCH" hook --repo "$d" --session S)" "11. no open MR → silent"

# 12. Stop-hook plumbing: resolves the repo, gated on engagement; emits the launch block; re-entrancy
PLUGIN="$(cd "$(dirname "$WATCH")/../../.." && pwd)"
HOOK="$PLUGIN/hooks/stop-hook.py"
d="$ROOT/sh"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session X >/dev/null
out=$(echo "{\"cwd\":\"$d\",\"session_id\":\"X\",\"stop_hook_active\":false}" | STUB_CI=pending CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK" 2>/dev/null)
assert_eq "" "$out" "12. not engaged (no push this session) → Stop hook silent"
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
out=$(echo "{\"cwd\":\"$d\",\"session_id\":\"X\",\"stop_hook_active\":false}" | STUB_CI=pending CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK" 2>/dev/null)
assert_contains '"decision": "block"' "$out" "12. engaged + open MR + CI running → Stop hook emits the launch block"
out=$(echo "{\"cwd\":\"$d\",\"session_id\":\"X\",\"stop_hook_active\":true}" | STUB_CI=pending CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK" 2>/dev/null)
assert_eq "" "$out" "12. re-entrancy: stop_hook_active → hook silent"

# 13. resolve: active repo (subdir / push command / transcript), root-anchored
rr="$ROOT/r13"; new_repo "$rr"   # on branch feat, with origin
rsub="$rr/a/b/c"; mkdir -p "$rsub"; rtop="$(git -C "$rr" rev-parse --show-toplevel)"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --cwd "$rsub")" "13. resolve: deep subdir → repo root"
rnr="$ROOT/r13-nr"; mkdir -p "$rnr"
assert_eq "" "$(python3 "$WATCH" resolve --cwd "$rnr")" "13. resolve: non-repo cwd → empty"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --command "git -C $rr push origin feat")" "13. resolve: git -C X push → X root"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --command "cd $rr && git push")" "13. resolve: cd X && git push → X root"
rtp="$ROOT/r13.jsonl"; printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/app.txt"}}]}}\n' "$rsub" > "$rtp"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --cwd "$rnr" --transcript "$rtp")" "13. resolve: transcript last-edit → its repo root"
python3 "$WATCH" baseline --repo "$rsub" --session s1
[ -f "$rtop/.git/mr-watchdog-session.json" ] && ok "13. root-anchor: baseline from subdir → state at repo root" || ko "13. root-anchor subdir"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
