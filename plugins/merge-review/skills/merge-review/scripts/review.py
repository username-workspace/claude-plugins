#!/usr/bin/env python3
"""merge-review — plumbing for an adversarial merge-readiness review.

The judgment (scoring, adversarial analysis, the fix loop) is the model's, driven by SKILL.md. This
script only does the deterministic parts: construct the local diff base and fetch forge context, gate a
push of a branch this session produced until the current HEAD has a passing review on record, persist
the per-pass state so runs are iterative, and a fake-green check the fix loop runs before committing. It
never commits, pushes, or merges, and runs no model itself. Opt a repo out with enabled:false.
"""
import argparse, json, os, re, subprocess, sys
from shutil import which

DEFAULTS = {
    "enabled": True,          # set false to opt a repo OUT (engagement is otherwise automatic)
    "threshold": 80,          # score at/above which the diff is merge-ready
    "auto_fix": True,         # local mode: apply attested findings and loop until viable
    "prepush_gate": True,     # gate `git push` of a branch this session produced until reviewed
    "forge": None,            # github | gitlab; auto-detected from the remote if null
    "skip_marker": "wip/",
}

COMMON_TRUNKS = {"main", "master", "develop", "trunk"}

# A change that hides a failure instead of resolving it — surfaced by `verify` so a fix can't fake green.
BYPASS_PATTERNS = [
    r"--no-verify",
    r"\|\|\s*true\b",
    r"\bcontinue-on-error:\s*true",
    r"\ballow_failure:\s*true",
    r"\bwhen:\s*never\b",
    r"@(?:pytest\.mark\.)?(?:skip|xfail)\b",
    r"\bpytest\.skip\b|\b(?:unittest|self)\.skip(?:Test)?\b",
    r"\b(?:it|test|describe)\.skip\b",
    r"\bxit\b|\bxdescribe\b",
    r"\.skip\s*\(",
    r"\bassert\s+(?:True|1)\b",
    r"\bexpect\(\s*true\s*\)\.tobe\(\s*true\s*\)",
    r"--maxfail\b",
    r"eslint-disable",
    r"#\s*type:\s*ignore",
    r"#\s*noqa(?!:\s*E501)",
    r"@ts-(?:ignore|nocheck|expect-error)",
    r"\bskip_tests?\b",
]

TEST_PATH = re.compile(r"(^|/)(tests?/|test_|conftest|.*[._-](test|spec)\.)", re.I)


def run(cmd, cwd, check=False, timeout=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        if check:
            raise
        return 127, "", f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {p.stderr.strip()}")
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def load_config(repo, path=None):
    cfg = dict(DEFAULTS)
    for p in [os.path.join(repo, ".merge-review.json"), path]:
        if p and os.path.isfile(p):
            try:
                cfg.update(json.load(open(p)))
            except Exception:
                pass
    return cfg


def git_dir(repo):
    rc, gd, _ = run(["git", "rev-parse", "--git-dir"], repo)
    gd = gd if (rc == 0 and gd) else ".git"
    return gd if os.path.isabs(gd) else os.path.join(repo, gd)


def cur_branch(repo):
    rc, b, _ = run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], repo)
    return b if rc == 0 else None


def head_sha(repo):
    rc, sha, _ = run(["git", "rev-parse", "HEAD"], repo)
    return sha if rc == 0 else ""


def remote_name(repo):
    rc, up, _ = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], repo)
    if rc == 0 and "/" in up:
        return up.split("/", 1)[0]
    _, remotes, _ = run(["git", "remote"], repo)
    rl = [r for r in remotes.splitlines() if r.strip()]
    return ("origin" if "origin" in rl else rl[0]) if rl else None


def default_branch(repo, remote):
    if remote:
        rc, out, _ = run(["git", "symbolic-ref", "--quiet", f"refs/remotes/{remote}/HEAD"], repo)
        if rc == 0 and out:
            return out.rsplit("/", 1)[-1]
    for b in ("main", "master"):
        rc, _, _ = run(["git", "rev-parse", "--verify", "--quiet", b], repo)
        if rc == 0:
            return b
    return "main"


def detect_forge(repo, cfg, remote):
    if cfg.get("forge"):
        return cfg["forge"]
    rc, url, _ = run(["git", "remote", "get-url", remote or "origin"], repo)
    h = (url or "").lower()
    return "github" if "github" in h else "gitlab" if "gitlab" in h else "unknown"


# --- active-repo resolution: the repo we're working in (not the launch dir), root-anchored ---------

def git_toplevel(path):
    if not path:
        return None
    rc, top, _ = run(["git", "-C", path, "rev-parse", "--show-toplevel"], ".")
    return top if rc == 0 and top else None


def repo_root(path):
    ap = os.path.abspath(path or ".")
    return git_toplevel(ap) or ap


def repo_from_command(cmd):
    m = re.search(r"\bgit\b[^&|;]*?\s-C\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd or "") \
        or re.search(r"(?:^|&&|;|\|)\s*cd\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd or "")
    return m.group(1).strip("\"'") if m else None


def last_edited_file(tp):
    if not tp or not os.path.isfile(tp):
        return None
    last, edits = None, {"Edit", "Write", "MultiEdit", "NotebookEdit", "Update"}
    try:
        for line in open(tp, errors="ignore"):
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") != "assistant":
                continue
            content = (d.get("message") or {}).get("content")
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in edits:
                        inp = b.get("input") or {}
                        fp = inp.get("file_path") or inp.get("notebook_path")
                        if fp:
                            last = fp
    except Exception:
        return None
    return last


def resolve_repo(cwd, transcript, command):
    """The git repo root we're actually working in: the one named in a push command, else the cwd's
    repo, else the repo of the most-recently edited file. None when no git repo is in scope."""
    if command:
        p = repo_from_command(command)
        if p:
            if not os.path.isabs(p) and cwd:
                p = os.path.join(cwd, p)
            r = git_toplevel(p)
            if r:
                return r
    if cwd:
        r = git_toplevel(cwd)
        if r:
            return r
    if transcript:
        f = last_edited_file(transcript)
        if f:
            r = git_toplevel(os.path.dirname(f))
            if r:
                return r
    return None


def cmd_resolve(args):
    r = resolve_repo(args.cwd, args.transcript, args.command)
    if r:
        print(r)


# --- session engagement: only gate a branch THIS session produced work on -------------------------

def work_state(repo):
    """(HEAD sha, hash of the dirty set) — changes the moment this session commits or edits the tree."""
    import hashlib
    rc, head, _ = run(["git", "rev-parse", "HEAD"], repo)
    _, porcelain, _ = run(["git", "status", "--porcelain"], repo)
    return (head if rc == 0 else ""), hashlib.sha1(porcelain.encode()).hexdigest()[:12]


def feature_branch(repo, cfg):
    """The current branch if it's one we'd ever gate (a feature branch with a remote), else None."""
    b = cur_branch(repo)
    if not b or b.startswith(cfg["skip_marker"]) or b in COMMON_TRUNKS:
        return None
    remote = remote_name(repo)
    if not remote or b == default_branch(repo, remote):
        return None
    return b


def session_path(repo):
    return os.path.join(git_dir(repo), "merge-review-session.json")


def read_session(repo):
    try:
        return json.load(open(session_path(repo)))
    except Exception:
        return None


def write_session(repo, data):
    try:
        json.dump(data, open(session_path(repo), "w"))
    except OSError:
        pass


def cmd_baseline(args):
    """UserPromptSubmit: stamp HEAD + the dirty set at turn start, so later work by this session shows."""
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    branch = feature_branch(repo, cfg)
    if not branch:
        return
    st = read_session(repo)
    if not st or st.get("session") != args.session:
        st = {"session": args.session, "branches": {}}
    if branch not in st["branches"]:
        head, dirty = work_state(repo)
        st["branches"][branch] = {"head": head, "dirty": dirty, "engaged": False}
        write_session(repo, st)


def engaged(repo, cfg, session):
    """True if THIS session produced work on the current feature branch — HEAD advanced or the tree
    changed since this session's baseline. `enabled: false` opts a repo out."""
    if not cfg.get("enabled", True):
        return False
    branch = feature_branch(repo, cfg)
    if not branch:
        return False
    st = read_session(repo)
    if not st or st.get("session") != session:
        return False
    entry = st["branches"].get(branch)
    if not entry:
        return False
    if entry.get("engaged"):
        return True
    head, dirty = work_state(repo)
    if head != entry.get("head") or dirty != entry.get("dirty"):
        entry["engaged"] = True
        write_session(repo, st)
        return True
    return False


def cmd_engaged(args):
    repo = os.path.abspath(args.repo)
    print("yes" if engaged(repo, load_config(repo, args.config), args.session) else "no")


# --- iterative review state (per-pass) + pre-push stamp --------------------------------------------

def state_path(repo):
    return os.path.join(git_dir(repo), "merge-review-state.json")


def read_state(repo):
    try:
        return json.load(open(state_path(repo)))
    except Exception:
        return None


def write_state(repo, data):
    try:
        json.dump(data, open(state_path(repo), "w"))
    except OSError:
        pass


def cmd_record(args):
    """Record one review pass. A passing record at the current HEAD is what lets the pre-push gate
    through; the findings carry into the next pass for reconciliation (the score trajectory)."""
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    prev = read_state(repo) or {}
    findings = []
    if args.findings:
        try:
            findings = json.loads(args.findings)
        except Exception:
            findings = []
    score = int(args.score) if args.score is not None else None
    passed = bool(args.passed) or (score is not None and score >= int(cfg.get("threshold", 80)))
    data = {"branch": cur_branch(repo), "head": head_sha(repo), "score": score,
            "passed": passed, "pass": int(prev.get("pass", 0)) + 1, "findings": findings}
    write_state(repo, data)
    print(f"[merge-review] recorded pass {data['pass']}: score={score} passed={passed}")


def cmd_prior(args):
    repo = os.path.abspath(args.repo)
    print(json.dumps(read_state(repo) or {}, indent=2))


# --- pre-push gate ---------------------------------------------------------------------------------

def gate_block_path(repo):
    return os.path.join(git_dir(repo), "merge-review-gate.json")


def read_gate_block(repo):
    try:
        return json.load(open(gate_block_path(repo)))
    except Exception:
        return {}


def write_gate_block(repo, data):
    try:
        json.dump(data, open(gate_block_path(repo), "w"))
    except OSError:
        pass


def gate_reason(repo, cfg):
    thr = int(cfg.get("threshold", 80))
    rec = f"python3 {os.path.abspath(__file__)} record --repo {repo} --score <N> --passed"
    verify = f"python3 {os.path.abspath(__file__)} verify --repo {repo}"
    return ("Before pushing this branch, run a merge-readiness review (the merge-review skill, LOCAL "
            "mode) on the current diff. For every BLOCKING finding that is attested — high confidence, "
            "with a file:line you actually opened and read — apply the minimal ROOT-CAUSE fix. Never "
            "fake green: no --no-verify, no `|| true`, no disabling/deleting/weakening tests, no lowered "
            f"thresholds; run `{verify}` before committing each fix. Re-run the review until the score "
            f"is >= {thr}. A contestable pure-logic finding must be SURFACED to the user, not silently "
            f"changed. When it clears, run `{rec}` to record the pass, then push. If you genuinely "
            f"cannot reach {thr} without a workaround, STOP and explain instead of bypassing.")


def cmd_gate(args):
    """Pre-push decision. Emits a PreToolUse deny (stdout) when the push should wait for a review, else
    nothing (allow). Advisory: it denies a given HEAD at most once per session, so it nudges without
    ever walling a push the user insists on."""
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    if not cfg.get("enabled", True) or not cfg.get("prepush_gate", True):
        return
    if not engaged(repo, cfg, args.session):
        return
    head = head_sha(repo)
    if not head:
        return
    st = read_state(repo)
    if st and st.get("head") == head and st.get("passed"):
        return
    blk = read_gate_block(repo)
    if blk.get("session") == args.session and blk.get("head") == head:
        return
    write_gate_block(repo, {"session": args.session, "head": head})
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                              "permissionDecision": "deny",
                                              "permissionDecisionReason": gate_reason(repo, cfg)}}))


# --- forge-agnostic context for a local review -----------------------------------------------------

def fetch_mr_context(repo, forge, branch):
    ctx = {"number": None, "title": None, "description": None, "unresolved": []}
    if not branch:
        return ctx
    if forge == "github" and which("gh"):
        rc, out, _ = run(["gh", "pr", "view", branch, "--json", "number,title,body,comments,reviews"], repo)
        if rc == 0:
            try:
                d = json.loads(out)
                ctx["number"], ctx["title"], ctx["description"] = d.get("number"), d.get("title"), d.get("body")
                notes = [f"[{(c.get('author') or {}).get('login', '?')}] {c.get('body', '')}"
                         for c in (d.get("comments") or [])]
                for r in (d.get("reviews") or []):
                    b = (r.get("body") or "").strip()
                    if b:
                        notes.append(f"[{(r.get('author') or {}).get('login', '?')}/{r.get('state', '')}] {b}")
                ctx["unresolved"] = [n for n in notes if n.strip()][:50]
            except Exception:
                pass
    elif forge == "gitlab" and which("glab"):
        rc, out, _ = run(["glab", "mr", "list", "--source-branch", branch, "-F", "json"], repo)
        iid = None
        try:
            arr = json.loads(out)
            if arr:
                iid = arr[0].get("iid")
                ctx["number"], ctx["title"], ctx["description"] = iid, arr[0].get("title"), arr[0].get("description")
        except Exception:
            pass
        if iid:
            rc, out, _ = run(["glab", "api", f"projects/:id/merge_requests/{iid}/discussions"], repo)
            try:
                notes = []
                for disc in json.loads(out):
                    for n in (disc.get("notes") or []):
                        if not n.get("system") and not n.get("resolved"):
                            notes.append(f"[{(n.get('author') or {}).get('username', '?')}] {n.get('body', '')}")
                ctx["unresolved"] = [n for n in notes if n.strip()][:50]
            except Exception:
                pass
    return ctx


def cmd_context(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    if (args.mode or "local") == "remote":
        print(json.dumps({"mode": "remote", "read_only": True,
                          "note": "The diff is injected by the runner; do NOT mutate git state (no "
                                  "fetch/checkout/commit/push). Review the injected diff only and emit "
                                  "the verdict + machine-readable state."}, indent=2))
        return
    remote = remote_name(repo)
    base = default_branch(repo, remote)
    branch = cur_branch(repo)
    forge = detect_forge(repo, cfg, remote)
    rc, log, _ = run(["git", "log", "--oneline", "--no-decorate", f"{base}..HEAD"], repo)
    commits = [l for l in log.splitlines() if l.strip()][:50] if rc == 0 else []
    print(json.dumps({"mode": "local", "branch": branch, "base": base, "remote": remote, "forge": forge,
                      "threshold": int(cfg.get("threshold", 80)), "auto_fix": bool(cfg.get("auto_fix", True)),
                      "diff_cmd": f"git diff {base}...HEAD", "commits": commits,
                      "mr": fetch_mr_context(repo, forge, branch)}, indent=2))


# --- fake-green detection (used by `verify`, run in your live session before committing a fix) ------

def added_lines(diff):
    return "\n".join(l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++"))


def bypass_in_diff(diff):
    for pat in BYPASS_PATTERNS:
        m = re.search(pat, diff, re.I)
        if m:
            return m.group(0)
    return None


def deleted_tests(repo):
    _, ns, _ = run(["git", "diff", "HEAD", "--name-status"], repo)
    return [p.split("\t")[-1] for p in ns.splitlines()
            if p[:1] == "D" and TEST_PATH.search(p.split("\t")[-1])]


def weakened_tests(repo):
    _, ns, _ = run(["git", "diff", "HEAD", "--name-status"], repo)
    for line in ns.splitlines():
        parts = line.split("\t")
        if parts[0][:1] == "M" and TEST_PATH.search(parts[-1]):
            _, d, _ = run(["git", "diff", "HEAD", "--", parts[-1]], repo)
            removed = [l for l in d.splitlines() if l.startswith("-") and not l.startswith("---")]
            if any(re.search(r"\b(assert|expect|should|require)\b", r, re.I) for r in removed):
                return parts[-1]
    return None


def read_capped(repo, rel, cap=20000):
    try:
        return open(os.path.join(repo, rel), errors="ignore").read()[:cap]
    except OSError:
        return ""


def fake_green(repo):
    """Returns a short reason the working-tree change fakes green, else '' (the change looks honest)."""
    g = deleted_tests(repo)
    if g:
        return f"deleted-test:{g[0][-40:]}"
    w = weakened_tests(repo)
    if w:
        return f"weakened-test:{w[-40:]}"
    _, tracked, _ = run(["git", "diff", "HEAD"], repo)
    _, un, _ = run(["git", "ls-files", "--others", "--exclude-standard"], repo)
    new_files = [f for f in un.splitlines() if f]
    scan = added_lines(tracked) + "\n" + "\n".join(read_capped(repo, f) for f in new_files)
    hit = bypass_in_diff(scan)
    return f"bypass:{hit[:40]}" if hit else ""


def cmd_verify(args):
    repo = os.path.abspath(args.repo)
    reason = fake_green(repo)
    if reason:
        print(f"[merge-review] ✗ fake-green: {reason} — fix the root cause, don't hide the finding")
        sys.exit(1)
    print("[merge-review] ✓ no bypass detected — the change addresses the finding, not the check")


def main():
    ap = argparse.ArgumentParser(description="merge-review")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(name, fn):
        s = sub.add_parser(name)
        s.add_argument("--repo", default=".")
        s.add_argument("--config")
        s.add_argument("--session", default="")
        s.set_defaults(fn=fn)
        return s

    common("baseline", cmd_baseline)
    common("engaged", cmd_engaged)
    common("gate", cmd_gate)
    common("prior", cmd_prior)
    common("verify", cmd_verify)
    c = common("context", cmd_context)
    c.add_argument("--mode", choices=["local", "remote"], default="local")
    r = common("record", cmd_record)
    r.add_argument("--score", type=int)
    r.add_argument("--passed", action="store_true")
    r.add_argument("--findings")
    rv = sub.add_parser("resolve")
    rv.add_argument("--cwd", default="")
    rv.add_argument("--transcript", default="")
    rv.add_argument("--command", default="")
    rv.set_defaults(fn=cmd_resolve)

    args = ap.parse_args()
    if getattr(args, "repo", None) is not None:
        args.repo = repo_root(args.repo)
    args.fn(args)


if __name__ == "__main__":
    main()
