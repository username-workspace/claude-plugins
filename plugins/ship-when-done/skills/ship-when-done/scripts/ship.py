#!/usr/bin/env python3
"""ship-when-done — commit at milestones, push to keep work safe, open a draft PR when done.

Guardrails (never crossed): never commit or push the default branch (branch-first); push only the
feature branch; never merge; refuse to act on a detached/unborn HEAD or mid rebase/merge; no AI
attribution in commits.
"""
import argparse, json, os, re, subprocess, sys, time
from shutil import which
from urllib.parse import quote

DEFAULTS = {
    "on_done": "draft-pr",            # draft-pr | ready-pr | suggest
    "gate": None,                     # auto-detected if null
    "ticket_pattern": r"\b([A-Z][A-Z0-9]+-\d+)\b",
    "commit_convention": "conventional",  # conventional | ticket
    "require_green_gate_for_pr": True,
    "judge_command": None,            # optional external "is it done?" command; off by default
    "skip_marker": "wip/",
    "forge": None,                    # github | gitlab | bitbucket; auto-detected from the remote if null
    "goal": "",
    "default_base": None,
    "enabled": True,                  # set false to opt a repo OUT (engagement is otherwise automatic)
    "respect_merge_review": True,     # hold the PR until a sibling merge-review gate passes (if present)
    "gate_timeout": 120,              # seconds before a gate run is declared timed out (never cached)
}

COMMON_TRUNKS = {"main", "master", "develop", "trunk"}


def run(cmd, cwd, check=False):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    except FileNotFoundError:
        if check:
            raise
        return 127, "", f"{cmd[0]}: not found"
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {p.stderr.strip()}")
    return p.returncode, p.stdout.strip(), p.stderr.strip()


# gate/judge_command are shell commands: never honored from the (cloneable) working-tree file,
# only from .git/ (never cloned) or an explicitly passed config
COMMAND_FIELDS = ("gate", "judge_command")


def load_config(repo, path=None):
    cfg = dict(DEFAULTS)
    sources = [(os.path.join(repo, ".ship-when-done.json"), False),
               (os.path.join(git_dir(repo), "ship-when-done.json"), True),
               (path, True)]
    for p, trusted in sources:
        if p and os.path.isfile(p):
            try:
                data = json.load(open(p))
            except Exception:
                continue
            if not trusted:
                for f in COMMAND_FIELDS:
                    data.pop(f, None)
            cfg.update(data)
    return cfg


def git_dir(repo):
    rc, gd, _ = run(["git", "rev-parse", "--git-dir"], repo)
    gd = gd if (rc == 0 and gd) else ".git"
    return gd if os.path.isabs(gd) else os.path.join(repo, gd)


def in_progress_op(repo):
    gd = git_dir(repo)
    for name, op in (("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
                     ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")):
        if os.path.exists(os.path.join(gd, name)):
            return op
    return None


def remote_name(repo):
    rc, up, _ = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], repo)
    if rc == 0 and "/" in up:
        return up.split("/", 1)[0]
    _, remotes, _ = run(["git", "remote"], repo)
    rl = [r for r in remotes.splitlines() if r.strip()]
    return ("origin" if "origin" in rl else rl[0]) if rl else None


def default_branch(repo, remote):
    """Returns (name, confident). Confident only when the remote's HEAD resolves it."""
    if remote:
        rc, out, _ = run(["git", "symbolic-ref", "--quiet", f"refs/remotes/{remote}/HEAD"], repo)
        if rc == 0 and out:
            return out.rsplit("/", 1)[-1], True
    for b in ("main", "master"):
        rc, _, _ = run(["git", "rev-parse", "--verify", "--quiet", b], repo)
        if rc == 0:
            return b, False
    return "main", False


def git_state(repo):
    rc, _, _ = run(["git", "rev-parse", "--is-inside-work-tree"], repo)
    if rc != 0:
        return {"is_git": False}
    rc_sym, branch, _ = run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], repo)
    detached = rc_sym != 0
    rc_h, _, _ = run(["git", "rev-parse", "--verify", "--quiet", "HEAD"], repo)
    unborn = (not detached) and rc_h != 0
    remote = remote_name(repo)
    base, confident = default_branch(repo, remote)
    on_default = (not detached) and (branch == base or (not confident and branch in COMMON_TRUNKS))
    _, porcelain, _ = run(["git", "status", "--porcelain"], repo)
    ahead_of_base = unpushed = 0
    has_upstream = False
    if not detached and not unborn:
        rc, ab, _ = run(["git", "rev-list", "--count", f"{base}..HEAD"], repo)
        ahead_of_base = int(ab) if rc == 0 and ab.isdigit() else 0
        rc_u, up, _ = run(["git", "rev-list", "--count", "@{u}..HEAD"], repo)
        has_upstream = rc_u == 0
        unpushed = int(up) if has_upstream and up.isdigit() else (ahead_of_base if not has_upstream else 0)
    return {
        "is_git": True,
        "repo": repo,
        "branch": branch if not detached else "(detached)",
        "default_branch": base,
        "on_default": on_default,
        "dirty": bool(porcelain.strip()),
        "has_remote": bool(remote),
        "remote": remote,
        "has_upstream": has_upstream,
        "unpushed": unpushed,
        "ahead_of_base": ahead_of_base,
        "detached": detached,
        "unborn": unborn,
        "mid_op": in_progress_op(repo),
    }


def pr_exists(repo, branch):
    """Returns 'open' | 'none' | 'error' — distinguishing 'no PR' from a failed gh call."""
    rc, out, err = run(["gh", "pr", "view", branch, "--json", "state"], repo)
    if rc == 0:
        try:
            return "open" if json.loads(out).get("state") == "OPEN" else "none"
        except Exception:
            return "open"
    low = (err or "").lower()
    if "no pull requests found" in low or "no open pull requests" in low or "could not resolve" in low or "no default" in low:
        return "none"
    return "error"


def remote_url(repo, remote):
    rc, url, _ = run(["git", "remote", "get-url", remote], repo)
    return url if rc == 0 else ""


def parse_remote(url):
    """Parse an scp-style or http(s) git URL into {host, path, forge, https}. None if unrecognized."""
    if not url:
        return None
    u = re.sub(r"\.git/?$", "", url.strip())
    m = re.match(r"https?://(?:[^@/]+@)?([^/]+)/(.+)$", u) or \
        re.match(r"ssh://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$", u)
    if not m and "://" not in u:
        m = re.match(r"(?:[^@/]+@)?([^/:]+):(.+)$", u)
    if not m:
        return None
    host, path = m.group(1), m.group(2).strip("/")
    if "/" not in path:
        return None
    h = host.lower()
    forge = "github" if "github" in h else "gitlab" if "gitlab" in h else "bitbucket" if "bitbucket" in h else "unknown"
    return {"host": host, "path": path, "forge": forge, "https": f"https://{host}/{path}"}


def pr_create_url(info, base, branch):
    https, forge = info["https"], info["forge"]
    if forge == "gitlab":
        return f"{https}/-/merge_requests/new?merge_request%5Bsource_branch%5D={quote(branch)}&merge_request%5Btarget_branch%5D={quote(base)}"
    if forge == "bitbucket":
        return f"{https}/pull-requests/new?source={quote(branch)}&dest={quote(base)}"
    return f"{https}/compare/{quote(base)}...{quote(branch)}?expand=1"


def pr_strategy(forge):
    """How to open the PR: a CLI if present, GitLab push-options, else a constructed URL to surface."""
    if forge == "github" and which("gh"):
        return "gh"
    if forge == "gitlab" and which("glab"):
        return "glab"
    if forge == "gitlab":
        return "gitlab-push"
    return "url"


def detect_gate(repo, cfg):
    if cfg.get("gate"):
        return cfg["gate"]
    pj = os.path.join(repo, "package.json")
    if os.path.isfile(pj):
        try:
            scripts = (json.load(open(pj)) or {}).get("scripts", {})
        except Exception:
            scripts = {}
        runner = "pnpm" if os.path.isfile(os.path.join(repo, "pnpm-lock.yaml")) else \
                 "bun" if os.path.isfile(os.path.join(repo, "bun.lock")) or os.path.isfile(os.path.join(repo, "bun.lockb")) else \
                 "yarn" if os.path.isfile(os.path.join(repo, "yarn.lock")) else \
                 "npm run"
        for key in ("ts:check", "typecheck", "test", "lint"):
            if key in scripts:
                return f"{runner} {key}".replace("npm run test", "npm test")
    cj = os.path.join(repo, "composer.json")
    if os.path.isfile(cj):
        try:
            if "test" in ((json.load(open(cj)) or {}).get("scripts") or {}):
                return "composer test"
        except Exception:
            pass
    pyproject = os.path.join(repo, "pyproject.toml")
    if os.path.isfile(os.path.join(repo, "pytest.ini")) or \
       (os.path.isfile(pyproject) and "pytest" in read_text(pyproject)):
        return "python3 -m pytest"
    if os.path.isfile(os.path.join(repo, "go.mod")):
        return "go test ./..."
    if os.path.isfile(os.path.join(repo, "Cargo.toml")):
        return "cargo test"
    if re.search(r"^test:", read_text(os.path.join(repo, "Makefile")), re.M):
        return "make test"
    return None


def read_text(path):
    try:
        return open(path, errors="ignore").read()
    except OSError:
        return ""


def run_gate(repo, cmd, timeout=120):
    """('pass'|'fail'|'skip'|'timeout', output tail, seconds) — the tail is persisted as evidence so a
    red gate seen only inside a Stop hook is diagnosable after the fact."""
    if not cmd:
        return "skip", "", 0.0
    t0 = time.time()
    try:
        p = subprocess.run(["bash", "-c", cmd], cwd=repo, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", f"gate exceeded {timeout}s", round(time.time() - t0, 1)
    except FileNotFoundError:
        return "fail", "bash: not found", round(time.time() - t0, 1)
    tail = ((p.stdout or "") + "\n" + (p.stderr or "")).strip()[-2000:]
    return ("pass" if p.returncode == 0 else "fail"), tail, round(time.time() - t0, 1)


def find_ticket(text, pattern):
    m = re.search(pattern, text or "")
    return m.group(1) if m else None


def derive_branch_name(cfg, state):
    ticket = find_ticket(cfg.get("goal", ""), cfg["ticket_pattern"])
    if ticket:
        return f"{ticket.lower()}-work"
    slug = re.sub(r"[^a-z0-9]+", "-", (cfg.get("goal") or "work").lower()).strip("-")[:32] or "work"
    return f"swd/{slug}"


def commit_scope(files):
    """A readable conventional-commit scope from the changed files' common directory (skipping generic
    container dirs like plugins/src/app), or None."""
    dirs = [os.path.dirname(f) for f in files if os.path.dirname(f)]
    if not dirs:
        return None
    try:
        common = os.path.commonpath(dirs)
    except ValueError:
        return None
    parts = [p for p in common.split(os.sep) if p and p != "."]
    generic = {"plugins", "src", "app", "lib", "libs", "packages", "apps", "skills", "scripts", "components"}
    meaningful = [p for p in parts if p not in generic]
    return meaningful[0] if meaningful else (parts[-1] if parts else None)


def summarize_changes(repo):
    """A concise conventional-commit (type, scope, description) derived from the CHANGED FILES — used
    when there is no done-marker summary, so the subject never falls back to free prose."""
    _, porcelain, _ = run(["git", "status", "--porcelain", "-uall"], repo)
    files = [l[3:].split(" -> ")[-1].strip().strip('"') for l in porcelain.splitlines() if l.strip()]
    files = [f for f in files if f]
    if not files:
        return "chore", None, "work in progress"
    low = [f.lower() for f in files]
    ctype = ("docs" if all(f.endswith((".md", ".mdx", ".rst", ".txt")) for f in low)
             else "test" if all(("test" in f or "spec" in f) for f in low)
             else "chore")
    names = list(dict.fromkeys(os.path.basename(f) for f in files))
    desc = ("update " + ", ".join(names[:3])) if len(names) <= 3 else f"update {len(files)} files"
    return ctype, commit_scope(files), desc[:72]


def build_commit_message(cfg, state, verdict):
    ticket = find_ticket(cfg.get("goal", ""), cfg["ticket_pattern"]) or find_ticket(state["branch"], cfg["ticket_pattern"])
    v = verdict or {}
    if v.get("source") == "marker" and (v.get("summary") or "").strip():
        ctype, scope = v.get("type") or "chore", None
        desc = v["summary"].strip().rstrip(".")[:72]
    else:
        ctype, scope, desc = summarize_changes(state["repo"])
    head = f"{ctype}({scope}): {desc}" if scope else f"{ctype}: {desc}"
    if ticket and cfg["commit_convention"] == "ticket":
        return f"[{ticket}] {head}"
    return f"{head}\n\nRefs: {ticket}" if ticket else head


def review_gate_pending(repo):
    """True when a sibling merge-review gate is active for this repo (its session file is present) but
    has not passed the current HEAD — so we hold the PUSH (the quality gate runs before anything reaches
    the remote; the commit is the anti-loss). Loose coupling via merge-review's .git state files; if it
    isn't active here this is always False and ship behaves exactly as before."""
    gd = git_dir(repo)
    if not os.path.isfile(os.path.join(gd, "merge-review-session.json")):
        return False
    try:
        st = json.load(open(os.path.join(gd, "merge-review-state.json")))
    except Exception:
        return True
    rc, head, _ = run(["git", "rev-parse", "HEAD"], repo)
    return not (st.get("passed") and st.get("head") == (head if rc == 0 else None))


def review_block_reason():
    return ("The work is committed (safe), and it's ready to ship — but the merge-review quality gate "
            "has not passed for this HEAD, and nothing is pushed to the remote until it does. Run a "
            "merge-readiness review now (the merge-review skill, LOCAL mode): score the diff, fix the "
            "attested findings at the root cause (never fake green — no --no-verify, || true, "
            "disabled/deleted/weakened tests, lowered thresholds), loop until it clears the threshold, "
            "then record the pass. Once it passes I'll push and open the PR. If you cannot reach the "
            "threshold without a workaround, STOP and explain instead.")


def run_ladder(state, verdict, gate, cfg):
    """Run the commit → push → PR ladder under the guardrails. Returns what it did."""
    res = {"actions": [], "blocked": [], "skipped": None, "branch": state.get("branch"), "commit_message": None}
    if not state.get("is_git"):
        res["skipped"] = "not-a-git-repo"
        return res
    if state.get("mid_op"):
        res["skipped"] = state["mid_op"] + "-in-progress"
        return res
    if state.get("detached") or state.get("unborn"):
        res["skipped"] = "unborn-head" if state.get("unborn") else "detached-head"
        return res
    if state["branch"].startswith(cfg["skip_marker"]):
        res["skipped"] = "skip-marker"
        return res
    if state["on_default"] and not state["dirty"] and state["unpushed"] > 0:
        res["blocked"].append("unpushed-on-default")
        res["skipped"] = "on-default"
        return res
    if not state["dirty"] and state["ahead_of_base"] == 0:
        res["skipped"] = "nothing-in-flight"
        return res

    repo = state["repo"]
    remote = state["remote"]
    ahead = state["ahead_of_base"]
    unpushed = state["unpushed"]
    has_up = state["has_upstream"]
    just_committed = False

    if state["on_default"] and state["dirty"]:
        branch = derive_branch_name(cfg, state)
        run(["git", "checkout", "-b", branch], repo, check=True)
        state = dict(state, branch=branch, on_default=False)
        has_up = False
        res["branch"] = branch
        res["actions"].append(f"branched:{branch}")

    if state["dirty"]:
        if state["on_default"]:
            res["blocked"].append("refuse-commit-on-default")
            return res
        msg = build_commit_message(cfg, state, verdict)
        run(["git", "add", "-A"], repo, check=True)
        run(["git", "commit", "-m", msg], repo, check=True)
        res["commit_message"] = msg
        res["actions"].append("commit")
        ahead += 1
        unpushed += 1
        just_committed = True

    base = cfg.get("default_base") or state["default_branch"]
    mode = cfg["on_done"]
    done = bool((verdict or {}).get("done"))
    gate_ok = (gate == "pass") or (not cfg["require_green_gate_for_pr"] and gate != "fail")
    review_pending = cfg.get("respect_merge_review", True) and review_gate_pending(repo)
    want_pr = done and gate_ok and not review_pending and remote and not state["on_default"] and ahead > 0
    info = parse_remote(remote_url(repo, remote)) if remote else None
    forge = cfg.get("forge") or (info["forge"] if info else "unknown")
    strategy = pr_strategy(forge)
    summary = (verdict or {}).get("summary") or "work"
    created = False

    if remote and state["on_default"]:
        res["blocked"].append("refuse-push-default")
    elif remote and (just_committed or not has_up or unpushed > 0):
        if review_pending:
            res["blocked"].append("push-held:merge-review-pending")   # quality gate: nothing leaves before review
        else:
            push = ["git", "push", "-u", remote, state["branch"]]
            gitlab_push = want_pr and mode in ("draft-pr", "ready-pr") and strategy == "gitlab-push"
            if gitlab_push:
                title = ("Draft: " if mode == "draft-pr" else "") + " ".join(summary.split())[:72]
                push += ["-o", "merge_request.create", "-o", f"merge_request.target={base}",
                         "-o", f"merge_request.title={title}"]
            rc, _, err = run(push, repo)
            if rc == 0:
                res["actions"].append("push")
                if gitlab_push:
                    res["actions"].append("pr:gitlab-mr")
                    created = True
            else:
                res["actions"].append(f"push-failed:{err[:60]}")

    if want_pr and not created:
        if mode == "suggest":
            if info and surface_url_once(repo, state["branch"]):
                res["actions"].append("suggest-pr")
                res["pr_url"] = pr_create_url(info, base, state["branch"])
        elif strategy == "gh":
            status = pr_exists(repo, state["branch"])
            if status == "open":
                res["actions"].append("pr:exists")
            elif status == "error":
                res["actions"].append("pr:check-failed")
            else:
                args = ["gh", "pr", "create", "--base", base, "--head", state["branch"], "--fill"]
                if mode == "draft-pr":
                    args.append("--draft")
                rc, out, err = run(args, repo)
                if rc == 0:
                    res["actions"].append(f"pr:{mode}")
                    res["pr"] = out
                    created = True
                else:
                    res["actions"].append(f"pr-failed:{err[:60]}")
        elif strategy == "glab":
            args = ["glab", "mr", "create", "--fill", "--yes", "--target-branch", base]
            if mode == "draft-pr":
                args.append("--draft")
            rc, out, err = run(args, repo)
            if rc == 0:
                res["actions"].append(f"pr:{mode}")
                res["pr"] = out
                created = True
            else:
                res["actions"].append(f"pr-failed:{err[:60]}")
        else:
            if info and surface_url_once(repo, state["branch"]):
                res["actions"].append("pr-url")
                res["pr_url"] = pr_create_url(info, base, state["branch"])
    elif done and not gate_ok:
        res["blocked"].append("pr-withheld:gate-not-green")
    elif not done and (verdict or {}).get("source") in ("marker", "todos"):
        if gate == "fail":
            res["blocked"].append("pr-withheld:gate-not-green")
        elif gate == "timeout":
            res["blocked"].append('pr-withheld:gate-timeout (raise "gate_timeout" in .git/ship-when-done.json)')
        elif gate == "skip" and cfg["require_green_gate_for_pr"]:
            res["blocked"].append('pr-withheld:no-gate-detected (set "gate" in .git/ship-when-done.json)')

    if not res["actions"]:
        res["skipped"] = "nothing-to-do"
    return res


def marker_path(repo):
    return os.path.join(git_dir(repo), "swd-done.json")          # inside .git → never committed


def read_marker(repo):
    p = marker_path(repo)
    if os.path.isfile(p):
        try:
            return json.load(open(p))
        except Exception:
            return {"done": True}
    return None


def clear_marker(repo):
    try:
        os.remove(marker_path(repo))
    except OSError:
        pass


def surface_url_once(repo, branch):
    """Surface a forge URL at most once per branch tip — dedups so a 'done' PR is shown when the tip
    advances but never re-nagged on idle turns. Stamp lives in .git (never committed)."""
    rc, sha, _ = run(["git", "rev-parse", "HEAD"], repo)
    p = os.path.join(git_dir(repo), "swd-url.json")
    try:
        data = json.load(open(p))
    except Exception:
        data = {}
    if rc == 0 and data.get(branch) == sha:
        return False
    data[branch] = sha
    try:
        json.dump(data, open(p, "w"))
    except OSError:
        pass
    return True


def evaluate_completion(state, gate, cfg, last_message="", todos_done=False):
    """Decide `done` from an explicit `mark-done` or all-todos-complete, cross-checked against a green
    gate and no fresh TODO/FIXME. When unsure → not done."""
    repo = state["repo"]
    marker = read_marker(repo)
    _, diff, _ = run(["git", "diff", "HEAD"], repo)
    new_todos = len(re.findall(r"^\+.*\b(TODO|FIXME|XXX)\b", diff, re.M))
    done = (bool(marker) or todos_done) and gate == "pass" and new_todos == 0
    summary = (marker or {}).get("summary") or (last_message.strip().splitlines()[0][:60] if last_message.strip() else "milestone")
    verdict = {"done": done, "score": 80 if done else 40, "type": (marker or {}).get("type", "chore"),
               "summary": summary, "remaining": [], "source": "marker" if marker else ("todos" if todos_done else "none")}

    if done and cfg.get("judge_command") and not os.environ.get("SHIP_WHEN_DONE_EVAL"):
        try:
            env = dict(os.environ, SHIP_WHEN_DONE_EVAL="1")
            p = subprocess.run(["bash", "-c", cfg["judge_command"]], cwd=repo, input=cfg.get("goal", ""),
                               capture_output=True, text=True, timeout=120, env=env)
            m = re.search(r"\{.*\}", p.stdout or "", re.S)
            if m:
                verdict["done"] = bool(json.loads(m.group(0)).get("done"))
        except Exception:
            pass
    return verdict


def cmd_state(args):
    print(json.dumps(git_state(os.path.abspath(args.repo)), indent=2))


def cmd_ladder(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    if args.goal:
        cfg["goal"] = args.goal
    verdict = json.loads(args.verdict) if args.verdict else {"done": False}
    print(json.dumps(run_ladder(git_state(repo), verdict, args.gate, cfg), indent=2))


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


# --- session engagement: only act on work THIS session produced (not a pre-existing dirty tree) -----

def cur_branch(repo):
    rc, b, _ = run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], repo)
    return b if rc == 0 else None


def work_state(repo):
    """(HEAD sha, hash of the dirty set) — changes the moment this session commits or edits the tree."""
    import hashlib
    rc, head, _ = run(["git", "rev-parse", "HEAD"], repo)
    _, porcelain, _ = run(["git", "status", "--porcelain"], repo)
    return (head if rc == 0 else ""), hashlib.sha1(porcelain.encode()).hexdigest()[:12]


def session_path(repo):
    return os.path.join(git_dir(repo), "swd-session.json")


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
    branch = cur_branch(repo)
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
    """True if THIS session produced work on the current branch — HEAD advanced or the tree changed
    since this session's baseline. `enabled: false` opts a repo out."""
    if not cfg.get("enabled", True):
        return False
    branch = cur_branch(repo)
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


def gate_cache_path(repo):
    return os.path.join(git_dir(repo), "swd-gate.json")


def cached_gate(repo, cmd):
    """Cache hit ONLY for a green verdict at this exact work-state + gate command. A red gate carries
    no proof of determinism (timeout, flake, machine state) — caching it would pin a false red and
    withhold the PR forever — so anything but 'pass' is re-run on the next Stop and self-heals."""
    if not cmd:
        return None
    try:
        d = json.load(open(gate_cache_path(repo)))
    except Exception:
        return None
    head, dirty = work_state(repo)
    if d.get("head") == head and d.get("dirty") == dirty and d.get("cmd") == cmd and d.get("verdict") == "pass":
        return "pass"
    return None


def store_gate(repo, cmd, verdict, tail="", secs=0.0):
    """Every gate run leaves evidence (verdict + output tail + duration), whatever the verdict — only
    'pass' is ever read back as a cache hit."""
    head, dirty = work_state(repo)
    try:
        json.dump({"head": head, "dirty": dirty, "cmd": cmd, "verdict": verdict,
                   "tail": tail, "secs": secs},
                  open(gate_cache_path(repo), "w"))
    except OSError:
        pass


def review_block_allowed(repo, session):
    """At most one review block per work-state, capped per session — a block-continuation that doesn't
    converge ends the turn instead of looping the Stop hook forever."""
    p = os.path.join(git_dir(repo), "swd-review-block.json")
    head, dirty = work_state(repo)
    try:
        d = json.load(open(p))
    except Exception:
        d = {}
    if d.get("session") != session:
        d = {"session": session, "count": 0}
    if d.get("head") == head and d.get("dirty") == dirty:
        return False
    if int(d.get("count", 0)) >= 5:
        return False
    try:
        json.dump({"session": session, "head": head, "dirty": dirty, "count": int(d.get("count", 0)) + 1},
                  open(p, "w"))
    except OSError:
        pass
    return True


def stamp_sibling(repo, fname, branch, session, entry):
    """Hand engagement to a sibling plugin (merge-review / mr-watchdog) for work THIS session produced.
    Their session file is the coupling point: absent → the plugin isn't active here, do nothing."""
    p = os.path.join(git_dir(repo), fname)
    if not os.path.isfile(p):
        return
    try:
        st = json.load(open(p))
    except Exception:
        return
    if st.get("session") != session:
        st["session"] = session
        st["branches"] = {}
    st.setdefault("branches", {})[branch] = dict(st.get("branches", {}).get(branch) or {}, **entry)
    try:
        json.dump(st, open(p, "w"))
    except OSError:
        pass


def watchdog_handoff(repo, session):
    """Right after opening the PR, ask the sibling mr-watchdog (via the script path its baseline stamped)
    whether to nudge the session to launch the CI watcher — same turn, no Stop-hook race. The forge may
    not have registered the new PR's checks yet (status 'none' for a few seconds), so a silent first
    answer is retried once."""
    try:
        script = json.load(open(os.path.join(git_dir(repo), "mr-watchdog-session.json"))).get("script")
    except Exception:
        return None
    if not script or not os.path.isfile(script):
        return None
    for attempt in (0, 1):
        try:
            r = subprocess.run([sys.executable, script, "hook", "--repo", repo, "--session", session],
                               capture_output=True, text=True, timeout=30)
            d = json.loads(r.stdout.strip() or "{}")
            if d.get("decision") == "block":
                return d.get("reason")
        except Exception:
            return None
        if attempt == 0:
            time.sleep(4)
    return None


def cmd_engage(args):
    if os.environ.get("SHIP_WHEN_DONE_EVAL"):
        return
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    if not engaged(repo, cfg, args.session):
        return
    if args.goal:
        cfg["goal"] = args.goal
    state = git_state(repo)
    if not state.get("is_git") or state.get("detached") or state.get("unborn") or state.get("mid_op"):
        return
    if not state["dirty"] and state["ahead_of_base"] == 0:
        return
    gate_cmd = detect_gate(repo, cfg)
    gate = cached_gate(repo, gate_cmd)
    gate_tail, gate_secs, gate_ran = "", 0.0, False
    if gate is None:
        gate, gate_tail, gate_secs = run_gate(repo, gate_cmd, int(cfg.get("gate_timeout", 120)))
        gate_ran = True
    verdict = evaluate_completion(state, gate, cfg, args.last_message or "", args.todos_done)
    res = run_ladder(state, verdict, gate, cfg)
    if gate_cmd and gate_ran:
        store_gate(repo, gate_cmd, gate, gate_tail, gate_secs)
    branch = res.get("branch")
    acts = res["actions"]
    if branch:
        if "commit" in acts or any(a.startswith("branched:") for a in acts):
            stamp_sibling(repo, "swd-session.json", branch, args.session, {"engaged": True})
            stamp_sibling(repo, "merge-review-session.json", branch, args.session, {"engaged": True})
        if "push" in acts:
            stamp_sibling(repo, "mr-watchdog-session.json", branch, args.session, {"engaged": True})
    created = any(a.startswith("pr:draft") or a.startswith("pr:ready") or a == "pr:gitlab-mr" for a in acts)
    if created:
        clear_marker(repo)
    out = {}
    if "push-held:merge-review-pending" in res["blocked"]:
        if review_block_allowed(repo, args.session):
            out = {"decision": "block", "reason": review_block_reason()}
    elif created:
        nudge = watchdog_handoff(repo, args.session)
        if nudge:
            out = {"decision": "block", "reason": nudge}
    summary = " · ".join(acts) or res.get("skipped") or "no-op"
    line = f"[ship-when-done] {summary}" + (f"  (withheld: {', '.join(res['blocked'])})" if res["blocked"] else "")
    link = res.get("pr") or res.get("pr_url")
    if link:
        line += f"\n  → {link}"
    if out or link or res["blocked"]:
        out["systemMessage"] = line
        print(json.dumps(out))
    else:
        print(line)


def cmd_mark_done(args):
    repo = os.path.abspath(args.repo)
    data = {"done": True, "summary": (args.summary or "").strip()[:72], "type": args.type}
    p = marker_path(repo)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(data, open(p, "w"))
    print(f"[ship-when-done] marked done: {data['summary'] or '(no summary)'}")


def main():
    ap = argparse.ArgumentParser(description="ship-when-done")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("state"); s.add_argument("--repo", default="."); s.set_defaults(fn=cmd_state)
    l = sub.add_parser("ladder")
    l.add_argument("--repo", default="."); l.add_argument("--config"); l.add_argument("--goal", default="")
    l.add_argument("--verdict"); l.add_argument("--gate", default="skip", choices=["pass", "fail", "skip", "timeout"])
    l.set_defaults(fn=cmd_ladder)
    e = sub.add_parser("engage")
    e.add_argument("--repo", default="."); e.add_argument("--config"); e.add_argument("--goal", default="")
    e.add_argument("--last-message", default=""); e.add_argument("--todos-done", action="store_true")
    e.add_argument("--session", default="")
    e.set_defaults(fn=cmd_engage)
    b = sub.add_parser("baseline")
    b.add_argument("--repo", default="."); b.add_argument("--config"); b.add_argument("--session", default="")
    b.set_defaults(fn=cmd_baseline)
    g = sub.add_parser("engaged")
    g.add_argument("--repo", default="."); g.add_argument("--config"); g.add_argument("--session", default="")
    g.set_defaults(fn=cmd_engaged)
    m = sub.add_parser("mark-done")
    m.add_argument("--repo", default="."); m.add_argument("--summary", default=""); m.add_argument("--type", default="chore")
    m.set_defaults(fn=cmd_mark_done)
    rv = sub.add_parser("resolve")
    rv.add_argument("--cwd", default=""); rv.add_argument("--transcript", default=""); rv.add_argument("--command", default="")
    rv.set_defaults(fn=cmd_resolve)
    args = ap.parse_args()
    if getattr(args, "repo", None) is not None:
        args.repo = repo_root(args.repo)
    args.fn(args)


if __name__ == "__main__":
    main()
