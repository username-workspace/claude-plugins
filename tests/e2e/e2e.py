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
        out = stop(cwd, session, tp, active=True)

    expect('"decision": "block"' in out and "merge-review" in out,
           "done work must be held for the merge-review pass", out)
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
    expect(rc == 0 and "CI au vert" in verdict, "the pipeline must end green", verdict)
    if sc["gate"] == "auto":
        ev = json.load(open(os.path.join(workdir, ".git", "swd-gate.json")))
        expect(ev.get("cmd") == project["expected_gate"] and ev.get("verdict") == "pass",
               f"auto-detected gate must be '{project['expected_gate']}' and green", json.dumps(ev))

    sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO, "--delete-branch"])
    shutil.rmtree(os.path.dirname(workdir), ignore_errors=True)
    return "pass"


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
    title = f"e2e: persistent failure — {sc['flow']}/{sc['gate']}/{sc['ci']} (seed tag {tag})"
    body = (f"The E2E lane failed twice on the same generated scenario.\n\n"
            f"**Scenario**: `{json.dumps(sc)}`  ·  **tag**: `{tag}`\n"
            f"**Reproduce**: `python3 tests/e2e/e2e.py --scenario "
            f"{sc['flow']}:{sc['gate']}:{sc['ci']}"
            + (f":{sc['project']}" if sc.get("project") else "")
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
    ap.add_argument("--scenario", help="one-off flow:gate:ci[:project] instead of the generated set")
    ap.add_argument("--projects", action="store_true",
                    help="full-integration suite over the project archetypes (auto-detected gates)")
    args = ap.parse_args()
    globals()["E2E_REPO"] = args.repo

    if args.scenario:
        parts = args.scenario.split(":")
        scenarios = [{"flow": parts[0], "gate": parts[1], "ci": parts[2],
                      **({"project": parts[3]} if len(parts) > 3 else {})}]
    elif args.projects:
        scenarios = [{"flow": "single-shot", "gate": "auto",
                      "ci": "red-then-fixed" if p == "multi" else "green", "project": p}
                     for p in PROJECTS]
    else:
        scenarios = generate(args.seed, args.count)

    runid = format(int(time.time()) % 36 ** 4, "x")
    print(f"harness-e2e · forge={E2E_REPO} · seed={args.seed} · run={runid} · {len(scenarios)} scenario(s)")
    gc_sandbox()
    failures = 0
    for i, sc in enumerate(scenarios):
        tag = f"s{args.seed}n{i}r{runid}"
        label = f"{sc.get('project', 'bare')}/{sc['flow']}/{sc['gate']}/{sc['ci']}"
        t0 = time.time()
        for attempt in (1, 2):
            try:
                run_scenario(sc, f"{tag}a{attempt}")
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
    print(f"\n{'all green' if failures == 0 else f'{failures} persistent failure(s) — issues filed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
