#!/usr/bin/env python3
"""harness-e2e — generative end-to-end validation of the delivery harness against a REAL forge.

The hermetic suites idealize four things the real world doesn't: composition, environment, time, and
state evolution. This lane covers them by replaying generated scenarios (seeded, so every failure is
reproducible) on a disposable sandbox repo with plan-steered CI — real pushes, real PRs, real checks,
real registration windows.

Watcher duties: every scenario failure is re-run once with the same seed (flake vs defect); the sandbox
is self-healed before each run (stale e2e/* branches and PRs are garbage-collected); a persistent
failure files a GitHub issue on the skills repo carrying the full evidence, ready for a fixing session.

Usage: python3 tests/e2e/e2e.py [--seed N] [--count N] [--repo owner/name] [--scenario flow:gate:ci]
"""
import argparse, json, os, random, shutil, subprocess, sys, tempfile, time

SKILLS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHIP = os.path.join(SKILLS, "plugins/ship-when-done/skills/ship-when-done/scripts/ship.py")
REVIEW = os.path.join(SKILLS, "plugins/merge-review/skills/merge-review/scripts/review.py")
WATCH = os.path.join(SKILLS, "plugins/mr-watchdog/skills/mr-watchdog/scripts/watch.py")
SHIP_HOOK = os.path.join(SKILLS, "plugins/ship-when-done/hooks/stop-hook.py")
SHIP_PLUGIN = os.path.join(SKILLS, "plugins/ship-when-done")
E2E_REPO = "username-workspace/harness-e2e"
ISSUE_REPO = "username-workspace/skills"

DIMS = {
    "flow": ["single-shot", "multi-turn", "reedit"],
    "gate": ["green", "red-then-fixed", "timeout", "none"],
    "ci": ["green", "red-then-fixed", "slow-green"],
}
CANONICAL = [
    {"flow": "single-shot", "gate": "green", "ci": "green"},
    {"flow": "multi-turn", "gate": "green", "ci": "red-then-fixed"},
]
CI_PLANS = {"green": {"sleep": 0, "exit": 0}, "red-then-fixed": {"sleep": 0, "exit": 1},
            "slow-green": {"sleep": 60, "exit": 0}}


# --- project archetypes: varied complexity, gate AUTO-DETECTED (no config) --------------------------

def _files(repo, files):
    for rel, content in files.items():
        p = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(content)


PROJECTS = {
    "node": {"expected_gate": "npm test", "cwd": ".", "files": {
        "package.json": '{"name":"e2e-node","scripts":{"test":"node -e \'process.exit(0)\'"}}\n'}},
    "pnpm-ts": {"expected_gate": "pnpm ts:check", "cwd": ".", "files": {
        "package.json": '{"name":"e2e-ts","scripts":{"ts:check":"node -e \'process.exit(0)\'"}}\n',
        "pnpm-lock.yaml": "lockfileVersion: '9.0'\n"}},
    "php": {"expected_gate": "composer test", "cwd": ".", "files": {
        "composer.json": '{"name":"e2e/php","scripts":{"test":"php -r \'exit(0);\'"}}\n'}},
    "go": {"expected_gate": "go test ./...", "cwd": ".", "files": {
        "go.mod": "module e2e/gomod\n\ngo 1.21\n",
        "main.go": "package main\n\nfunc main() {}\n"}},
    "multi": {"expected_gate": "make test", "cwd": "packages/lib", "files": {
        "Makefile": "test:\n\t@true\n",
        "src/app/main.txt": "app\n",
        "packages/lib/lib.txt": "lib\n",
        "docs/README.md": "# multi\n"}},
}


def sh(cmd, cwd=None, timeout=300, env=None, check=False):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                       env=dict(os.environ, **(env or {})), shell=isinstance(cmd, str))
    if check and p.returncode != 0:
        raise RuntimeError(f"{cmd} -> rc={p.returncode}\n{p.stdout}\n{p.stderr}")
    return p.returncode, p.stdout.strip(), p.stderr.strip()


class Failure(Exception):
    pass


def expect(cond, what, evidence=""):
    if not cond:
        raise Failure(f"{what}\n--- evidence ---\n{evidence[-3000:]}")


# --- self-heal: the sandbox must be clean before and after, whatever previous runs did --------------

def gc_sandbox():
    rc, out, _ = sh(["gh", "pr", "list", "--repo", E2E_REPO, "--state", "open",
                     "--json", "number,headRefName"])
    for pr in (json.loads(out) if rc == 0 and out else []):
        if pr["headRefName"].startswith("e2e/"):
            sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO, "--delete-branch"])
    rc, out, _ = sh(["gh", "api", f"repos/{E2E_REPO}/branches", "--jq", ".[].name"])
    for b in (out.splitlines() if rc == 0 else []):
        if b.startswith("e2e/"):
            sh(["gh", "api", "-X", "DELETE", f"repos/{E2E_REPO}/git/refs/heads/{b}"])


# --- scenario plumbing -------------------------------------------------------------------------------

def clone(workdir):
    sh(["gh", "repo", "clone", E2E_REPO, workdir, "--", "-q"], check=True)
    sh(["git", "-C", workdir, "config", "user.email", "e2e@harness"], check=True)
    sh(["git", "-C", workdir, "config", "user.name", "harness-e2e"], check=True)
    sh(["git", "-C", workdir, "config", "commit.gpgsign", "false"], check=True)


def gate_config(repo, gate):
    cfg = {"green": {"gate": "true"},
           "red-then-fixed": {"gate": f"test -f {repo}/.git/gate-healed"},
           "timeout": {"gate": "sleep 5", "gate_timeout": 2},
           "none": {}, "auto": {}}[gate]
    if cfg:
        json.dump(cfg, open(os.path.join(repo, ".git", "ship-when-done.json"), "w"))


def baselines(repo, session):
    for script in (SHIP, REVIEW, WATCH):
        sh([sys.executable, script, "baseline", "--repo", repo, "--session", session], check=True)


def stop(repo, session, transcript, active=False):
    payload = json.dumps({"cwd": repo, "session_id": session, "transcript_path": transcript,
                          "stop_hook_active": active})
    p = subprocess.run([sys.executable, SHIP_HOOK], input=payload, capture_output=True, text=True,
                       timeout=300, env=dict(os.environ, CLAUDE_PLUGIN_ROOT=SHIP_PLUGIN))
    return p.stdout.strip()


def transcript_for(workdir, goal):
    tp = os.path.join(os.path.dirname(workdir), "transcript.jsonl")
    lines = [{"type": "user", "isSidechain": False, "message": {"role": "user", "content": goal}},
             {"type": "assistant", "message": {"role": "assistant",
                                               "content": [{"type": "text", "text": "Done."}]}}]
    open(tp, "w").write("\n".join(json.dumps(l) for l in lines))
    return tp


def work(repo, name, ci):
    open(os.path.join(repo, f"{name}.txt"), "w").write(f"work for {name}\n")
    json.dump(CI_PLANS[ci], open(os.path.join(repo, "ci-plan.json"), "w"))


COVERAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage.json")


def coverage_read():
    try:
        return json.load(open(COVERAGE))
    except Exception:
        return {}


def coverage_record(label, runid, secs):
    cov = coverage_read()
    cov[label] = {"run": runid, "proven": time.strftime("%Y-%m-%d"), "secs": secs}
    json.dump(dict(sorted(cov.items())), open(COVERAGE, "w"), indent=2)


def coverage_report():
    cov = coverage_read()
    bare = [f"bare/{f}/{g}/{c}" for f in DIMS["flow"] for g in DIMS["gate"] for c in DIMS["ci"]]
    twists = [f"twist/{t}" for t in TWISTS]
    projects = [f"{p}/single-shot/auto/{'red-then-fixed' if p == 'multi' else 'green'}" for p in PROJECTS]
    print(f"coverage ledger — {len(cov)} situation(s) proven")
    for space, keys in (("bare", bare), ("projects", projects), ("twists", twists)):
        missing = [k for k in keys if k not in cov]
        print(f"  {space}: {len(keys) - len(missing)}/{len(keys)} covered"
              + (f" — missing: {', '.join(missing)}" if missing else ""))


def watch_until_resolved(repo, timeout=420):
    rc, out, err = sh([sys.executable, WATCH, "run", "--repo", repo, "--timeout", str(timeout)],
                      timeout=timeout + 60)
    return rc, out + ("\n" + err if err else "")


def pr_state(branch):
    """The OPEN PR for this exact head branch, else None — `gh pr view <branch>` also matches closed
    PRs from previous runs, which is a different question and broke cross-run isolation."""
    rc, out, _ = sh(["gh", "pr", "list", "--repo", E2E_REPO, "--head", branch, "--state", "open",
                     "--json", "state,isDraft,number"])
    prs = json.loads(out) if rc == 0 and out else []
    return prs[0] if prs else None


# --- the scenario executor ---------------------------------------------------------------------------

def run_scenario(sc, tag):
    if sc.get("twist"):
        TWISTS[sc["twist"]](tag)
        return "pass"
    workdir = os.path.join(tempfile.mkdtemp(prefix="harness-e2e-"), "repo")
    clone(workdir)
    project = PROJECTS.get(sc.get("project", "bare"))
    branch = f"e2e/{tag}-{sc.get('project', 'bare')}-{sc['flow']}-{sc['gate']}-{sc['ci']}"
    session = f"e2e-{tag}"
    sh(["git", "-C", workdir, "checkout", "-q", "-b", branch], check=True)
    if project:
        _files(workdir, project["files"])
        sh(["git", "-C", workdir, "add", "-A"], check=True)
        sh(["git", "-C", workdir, "commit", "-qm", "chore: project scaffold"], check=True)
    cwd = os.path.join(workdir, project["cwd"]) if project else workdir
    gate_config(workdir, sc["gate"])
    tp = transcript_for(workdir, f"E2E-1 {sc['flow']} delivery on {branch}")
    baselines(workdir, session)

    if sc["flow"] == "multi-turn":
        work(workdir, "part1", sc["ci"])
        out = stop(cwd, session, tp)
        expect("push" in out or "commit" in out, "multi-turn turn1: partial work must commit+push", out)
        expect(pr_state(branch) is None, "multi-turn turn1: no PR before done", out)
        baselines(workdir, session)
    if sc["flow"] == "reedit":
        work(workdir, "feature", sc["ci"])
        open(os.path.join(workdir, "feature.txt"), "a").write("reedited content, same dirty file\n")

    work(workdir, "feature", sc["ci"])
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary",
        f"e2e {sc['flow']}", "--type", "feat"], check=True)

    out = stop(cwd, session, tp)
    if sc["gate"] == "timeout":
        expect("gate-timeout" in out, "timeout gate: distinct withheld reason expected", out)
        ev = json.load(open(os.path.join(workdir, ".git", "swd-gate.json")))
        expect(ev.get("verdict") == "timeout", "timeout gate: evidence persisted", json.dumps(ev))
        expect(pr_state(branch) is None, "timeout gate: no PR", out)
        return "pass"
    if sc["gate"] == "none":
        expect("no-gate-detected" in out, "no gate: withheld reason must be said out loud", out)
        expect(pr_state(branch) is None, "no gate: no PR", out)
        return "pass"
    if sc["gate"] == "red-then-fixed":
        expect("gate-not-green" in out, "red gate: PR withheld visibly", out)
        open(os.path.join(workdir, ".git", "gate-healed"), "w").write("x")

    expect('"decision": "block"' in out and "merge-review" in out,
           "done work must be held for the merge-review pass (the block rides the FIRST stop, "
           "once per work-state — a red gate does not delay it)", out)
    expect(pr_state(branch) is None, "nothing on the forge before the review", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(cwd, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr is not None and pr["state"] == "OPEN" and pr["isDraft"],
           "reviewed work must reach the forge as a draft PR", out)

    rc, verdict = watch_until_resolved(workdir)
    if sc["ci"] == "red-then-fixed":
        expect(rc == 1 and "ROOT" in verdict, "red CI: the watcher must hand back the fix contract",
               verdict)
        json.dump(CI_PLANS["green"], open(os.path.join(workdir, "ci-plan.json"), "w"))
        sh(["git", "-C", workdir, "add", "-A"], check=True)
        sh(["git", "-C", workdir, "commit", "-qm", "fix: heal the pipeline"], check=True)
        sh(["git", "-C", workdir, "push", "-q", "origin", branch], check=True)
        rc, verdict = watch_until_resolved(workdir)
    expect(rc == 0 and "CI green" in verdict, "the pipeline must end green", verdict)
    if sc["gate"] == "auto":
        ev = json.load(open(os.path.join(workdir, ".git", "swd-gate.json")))
        expect(ev.get("cmd") == project["expected_gate"] and ev.get("verdict") == "pass",
               f"auto-detected gate must be '{project['expected_gate']}' and green", json.dumps(ev))

    sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO, "--delete-branch"])
    shutil.rmtree(os.path.dirname(workdir), ignore_errors=True)
    return "pass"


# --- twists: human behaviour that diverges from the nominal pipeline --------------------------------

def twist_setup(tag, name, ci="green"):
    workdir = os.path.join(tempfile.mkdtemp(prefix="harness-e2e-"), "repo")
    clone(workdir)
    branch = f"e2e/{tag}-twist-{name}"
    sh(["git", "-C", workdir, "checkout", "-q", "-b", branch], check=True)
    json.dump({"gate": "true"}, open(os.path.join(workdir, ".git", "ship-when-done.json"), "w"))
    open(os.path.join(workdir, ".mr-watchdog.json"), "w").write('{"poll_interval": 1}')
    tp = transcript_for(workdir, f"E2E-2 twist {name} on {branch}")
    return workdir, branch, f"e2e-{tag}", tp


def deliver(workdir, branch, session, tp, ci="green"):
    """The nominal reviewed delivery, up to the open draft PR."""
    baselines(workdir, session)
    work(workdir, "feature", ci)
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "twist", "--type", "feat"],
       check=True)
    out = stop(workdir, session, tp)
    expect('"decision": "block"' in out, "delivery must be held for review", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr and pr["state"] == "OPEN", "reviewed delivery must open the draft PR", out)
    return pr


def twist_preexisting_dirty(tag):
    """The safety guarantee: a tree dirty BEFORE the session is never swept up."""
    workdir, branch, session, tp = twist_setup(tag, "preexisting-dirty")
    open(os.path.join(workdir, "precious-wip.txt"), "w").write("someone else's uncommitted work\n")
    baselines(workdir, session)
    out = stop(workdir, session, tp)
    _, n, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
    expect(n == "1", "pre-existing dirty tree: no commit", out)
    expect(os.path.isfile(os.path.join(workdir, "precious-wip.txt")), "the dirty file is untouched", out)
    expect(pr_state(branch) is None, "nothing reached the forge", out)


def twist_wip_branch(tag):
    """The wip/ escape hatch: even completed work on a wip/ branch is left alone."""
    workdir, _, session, tp = twist_setup(tag, "wip-branch")
    sh(["git", "-C", workdir, "checkout", "-q", "-b", "wip/spike"], check=True)
    baselines(workdir, session)
    work(workdir, "spike", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "spike"], check=True)
    out = stop(workdir, session, tp)
    _, n, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
    expect(n == "1", "wip/ branch: no commit, no ladder", out)


def twist_amend_after_push(tag):
    """HEAD rewritten while the watcher polls: it must stand down, never emit a verdict."""
    workdir, branch, session, tp = twist_setup(tag, "amend-after-push")
    deliver(workdir, branch, session, tp, ci="slow-green")
    proc = subprocess.Popen([sys.executable, WATCH, "run", "--repo", workdir],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(4)
    sh(["git", "-C", workdir, "commit", "--amend", "-m", "amended by the human"], check=True)
    out, _ = proc.communicate(timeout=90)
    expect("branch/HEAD moved" in out, "amended HEAD → the watcher stands down", out)
    expect("ok, all good" not in out and "ROOT" not in out, "no verdict for a rewritten HEAD", out)
    pr = pr_state(branch)
    if pr:
        sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO, "--delete-branch"])


def twist_mr_closed_mid_watch(tag):
    """The human closes the MR while the watcher polls: nothing left to watch, clean exit."""
    workdir, branch, session, tp = twist_setup(tag, "mr-closed-mid-watch")
    pr = deliver(workdir, branch, session, tp, ci="slow-green")
    sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO], check=True)
    rc, out, err = sh([sys.executable, WATCH, "run", "--repo", workdir], timeout=120)
    expect("no open merge request" in out + err, "closed MR → the watcher stands down", out + err)
    sh(["gh", "api", "-X", "DELETE", f"repos/{E2E_REPO}/git/refs/heads/{branch}"])


def twist_manual_push_midflow(tag):
    """The impatient human pushes by hand during the review hold: the pipeline still converges."""
    workdir, branch, session, tp = twist_setup(tag, "manual-push-midflow")
    baselines(workdir, session)
    work(workdir, "feature", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "manual"], check=True)
    out = stop(workdir, session, tp)
    expect('"decision": "block"' in out, "held for review first", out)
    sh(["git", "-C", workdir, "push", "-q", "-u", "origin", branch], check=True)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr and pr["state"] == "OPEN", "manual push absorbed, the PR still opens", out)
    sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO, "--delete-branch"])


def twist_review_loop(tag):
    """The review fails first (score under threshold): held without re-block churn, then the fix
    re-arms one new request, the pass ships it."""
    workdir, branch, session, tp = twist_setup(tag, "review-loop")
    baselines(workdir, session)
    work(workdir, "feature", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "loop"], check=True)
    out = stop(workdir, session, tp)
    expect('"decision": "block"' in out, "first stop requests the review", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "40"], check=True)
    out = stop(workdir, session, tp, active=True)
    expect('"decision": "block"' not in out, "failed review, unchanged state → no re-block churn", out)
    expect(pr_state(branch) is None, "still nothing on the forge", out)
    open(os.path.join(workdir, "feature.txt"), "a").write("finding fixed at the root\n")
    out = stop(workdir, session, tp, active=True)
    expect('"decision": "block"' in out, "new work-state → the review is re-requested", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr and pr["state"] == "OPEN", "passing review ships the loop's result", out)
    sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO, "--delete-branch"])


TWISTS = {
    "preexisting-dirty": twist_preexisting_dirty,
    "wip-branch": twist_wip_branch,
    "amend-after-push": twist_amend_after_push,
    "mr-closed-mid-watch": twist_mr_closed_mid_watch,
    "manual-push-midflow": twist_manual_push_midflow,
    "review-loop": twist_review_loop,
}


# --- the watcher: generate, run, classify, self-heal, hand off ---------------------------------------

def generate(seed, count):
    rng = random.Random(seed)
    seen = {tuple(sorted(c.items())) for c in CANONICAL}
    out = list(CANONICAL)
    for _ in range(1000):
        if len(out) >= len(CANONICAL) + count:
            break
        c = {d: rng.choice(v) for d, v in DIMS.items()}
        if tuple(sorted(c.items())) not in seen:
            seen.add(tuple(sorted(c.items())))
            out.append(c)
    return out


def file_issue(sc, tag, err):
    what = (f"twist/{sc['twist']}" if sc.get("twist")
            else f"{sc['flow']}/{sc['gate']}/{sc['ci']}")
    title = f"e2e: persistent failure — {what} (seed tag {tag})"
    body = (f"The E2E lane failed twice on the same generated scenario.\n\n"
            f"**Scenario**: `{json.dumps(sc)}`  ·  **tag**: `{tag}`\n"
            f"**Reproduce**: `python3 tests/e2e/e2e.py --scenario "
            + (f"twist:{sc['twist']}" if sc.get("twist") else
               f"{sc['flow']}:{sc['gate']}:{sc['ci']}" + (f":{sc['project']}" if sc.get("project") else ""))
            + f"`\n\n```\n{str(err)[-4000:]}\n```")
    rc, _, _ = sh(["gh", "issue", "create", "--repo", ISSUE_REPO, "--title", title, "--body", body,
                   "--label", "e2e"])
    if rc != 0:
        sh(["gh", "issue", "create", "--repo", ISSUE_REPO, "--title", title, "--body", body])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=2)
    ap.add_argument("--repo", default=E2E_REPO)
    ap.add_argument("--scenario", help="one-off flow:gate:ci[:project] or twist:<name>")
    ap.add_argument("--projects", action="store_true",
                    help="full-integration suite over the project archetypes (auto-detected gates)")
    ap.add_argument("--twists", action="store_true",
                    help="human-divergence situations (dirty start, amend, manual push, review loop…)")
    ap.add_argument("--coverage", action="store_true", help="print the proven-situations ledger")
    ap.add_argument("--fill", action="store_true",
                    help="run exactly the bare combos the ledger has never proven (target the holes)")
    args = ap.parse_args()
    globals()["E2E_REPO"] = args.repo

    if args.coverage:
        coverage_report()
        return
    if args.scenario:
        parts = args.scenario.split(":")
        if parts[0] == "twist":
            scenarios = [{"twist": parts[1]}]
        else:
            scenarios = [{"flow": parts[0], "gate": parts[1], "ci": parts[2],
                          **({"project": parts[3]} if len(parts) > 3 else {})}]
    elif args.fill:
        cov = coverage_read()
        scenarios = [{"flow": f, "gate": g, "ci": c}
                     for f in DIMS["flow"] for g in DIMS["gate"] for c in DIMS["ci"]
                     if f"bare/{f}/{g}/{c}" not in cov]
    elif args.twists:
        scenarios = [{"twist": t} for t in TWISTS]
    elif args.projects:
        scenarios = [{"flow": "single-shot", "gate": "auto",
                      "ci": "red-then-fixed" if p == "multi" else "green", "project": p}
                     for p in PROJECTS]
    else:
        scenarios = generate(args.seed, args.count)

    runid = format(int(time.time()) % 36 ** 4, "x")
    print(f"harness-e2e · forge={E2E_REPO} · seed={args.seed} · run={runid} · {len(scenarios)} scenario(s)")
    sh([sys.executable, SHIP, "claim", "--repo", SKILLS, "--path", "tests/e2e/coverage.json",
        "--pid", str(os.getpid())])
    failures = 0
    try:
        gc_sandbox()
        for i, sc in enumerate(scenarios):
            tag = f"s{args.seed}n{i}r{runid}"
            label = (f"twist/{sc['twist']}" if sc.get("twist")
                     else f"{sc.get('project', 'bare')}/{sc['flow']}/{sc['gate']}/{sc['ci']}")
            t0 = time.time()
            for attempt in (1, 2):
                try:
                    run_scenario(sc, f"{tag}a{attempt}")
                    coverage_record(label, runid, round(time.time() - t0))
                    print(f"  ✓ {label}  ({round(time.time() - t0)}s"
                          + (", flaky: passed on retry)" if attempt == 2 else ")"))
                    break
                except Failure as e:
                    if attempt == 1:
                        cause = str(e).splitlines()[0]
                        print(f"  ↻ {label} failed ({cause}) — retrying once to classify flake vs defect")
                        continue
                    failures += 1
                    print(f"  ✗ {label} — persistent:\n{e}")
                    file_issue(sc, tag, e)
                except Exception as e:
                    failures += 1
                    print(f"  ✗ {label} — infrastructure error: {e}")
                    break
        gc_sandbox()
    finally:
        sh([sys.executable, SHIP, "release", "--repo", SKILLS, "--path", "tests/e2e/coverage.json"])
    print(f"\n{'all green' if failures == 0 else f'{failures} persistent failure(s) — issues filed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
