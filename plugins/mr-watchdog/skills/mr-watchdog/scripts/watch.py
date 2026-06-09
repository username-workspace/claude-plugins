#!/usr/bin/env python3
"""mr-watchdog — once a merge request is open, watch its remote CI in the background and, on a red
pipeline, hand the failure off to your interactive session to fix at the root.

Read-only: it polls the CI, fetches the failing job log, and surfaces it — it never commits, pushes, or
merges, and runs no model itself. The fix happens in your interactive session; `verify` lets that
session self-check its change for fake-green before committing. It engages only a branch this session
pushed; opt a repo out with enabled:false.
"""
import argparse, json, os, re, subprocess, sys
from shutil import which

DEFAULTS = {
    "enabled": True,          # set false to opt a repo OUT (engagement is otherwise automatic)
    "forge": None,            # github | gitlab; auto-detected from the remote if null
    "poll_interval": 30,      # seconds between CI polls
    "log_lines": 200,         # failing-log lines carried into the handoff
    "on_red": "fix",          # fix (continue your live session to fix it) | notify (just surface it)
    "notify": "status-file",  # status-file | desktop
    "skip_marker": "wip/",
}

COMMON_TRUNKS = {"main", "master", "develop", "trunk"}

# A change that hides a failure instead of resolving it — surfaced by `verify` so the fix can't fake green.
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
    for p in [os.path.join(repo, ".mr-watchdog.json"), path]:
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


def current_branch(repo):
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


def forge_cli(forge):
    return "gh" if forge == "github" else "glab" if forge == "gitlab" else None


# --- remote state: open MR + CI status -------------------------------------------------------------

def mr_open(repo, forge, branch):
    if forge == "github":
        rc, out, _ = run(["gh", "pr", "view", branch, "--json", "state"], repo)
        if rc != 0:
            return False
        try:
            return json.loads(out).get("state") == "OPEN"
        except Exception:
            return False
    if forge == "gitlab":
        rc, out, _ = run(["glab", "mr", "list", "--source-branch", branch, "-F", "json"], repo)
        if rc != 0:
            return False
        try:
            return any((m.get("state") == "opened") for m in json.loads(out))
        except Exception:
            return False
    return False


def ci_status(repo, forge, branch):
    """Returns 'success' | 'failed' | 'pending' | 'none' | 'error'."""
    if forge == "github":
        rc, out, err = run(["gh", "pr", "checks", branch, "--json", "bucket"], repo)
        if out:
            try:
                buckets = [c.get("bucket") for c in json.loads(out)]
                if not buckets:
                    return "none"
                if any(b in ("fail", "cancel") for b in buckets):
                    return "failed"
                if any(b == "pending" for b in buckets):
                    return "pending"
                return "success"
            except Exception:
                pass
        low = (err or "").lower()
        if "no checks" in low or "no commit" in low:
            return "none"
        return {8: "pending"}.get(rc, "failed" if rc == 1 else "none" if rc == 0 else "error")
    if forge == "gitlab":
        rc, out, err = run(["glab", "ci", "status", "-b", branch], repo)
        blob = out + "\n" + err
        if rc != 0 and "no pipeline" in blob.lower():
            return "none"
        m = re.search(r"\bstatus:\s*([a-z]+)", blob, re.I)
        token = (m.group(1).lower() if m else blob.lower())
        if re.search(r"\b(failed|canceled)\b", token):
            return "failed"
        if re.search(r"\b(running|pending|created|preparing|manual)\b", token):
            return "pending"
        if re.search(r"\b(success|passed)\b", token):
            return "success"
        return "error" if rc != 0 else "none"
    return "error"


def failing_log(repo, forge, branch):
    if forge == "github":
        rc, out, _ = run(["gh", "run", "list", "-b", branch, "-L", "1", "--json", "databaseId"], repo)
        try:
            rid = json.loads(out)[0]["databaseId"]
        except Exception:
            rid = None
        if rid is not None:
            _, log, _ = run(["gh", "run", "view", str(rid), "--log-failed"], repo)
            return log
        return ""
    if forge == "gitlab":
        _, log, _ = run(["glab", "ci", "trace"], repo)
        return log
    return ""


# --- daemon lock + status --------------------------------------------------------------------------

def lock_path(repo):
    return os.path.join(git_dir(repo), "mr-watchdog.lock")


def status_path(repo):
    return os.path.join(git_dir(repo), "mr-watchdog-status.json")


def watcher_alive(repo):
    try:
        pid = int(open(lock_path(repo)).read().strip())
    except Exception:
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def write_lock(repo, pid):
    open(lock_path(repo), "w").write(str(pid))


def acquire_lock(repo):
    """Atomically reserve the single-watcher slot. Returns False if a live watcher already holds it."""
    if watcher_alive(repo):
        return False
    path = lock_path(repo)
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        if watcher_alive(repo):
            return False
        try:
            os.remove(path)
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except (OSError, FileExistsError):
            return False
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)
    return True


def clear_lock(repo):
    try:
        os.remove(lock_path(repo))
    except OSError:
        pass


def write_status(repo, **fields):
    data = read_status(repo) or {}
    data.update(fields)
    try:
        json.dump(data, open(status_path(repo), "w"))
    except OSError:
        pass


def read_status(repo):
    try:
        return json.load(open(status_path(repo)))
    except Exception:
        return None


# --- session engagement: only watch a branch THIS session pushed (so its pipeline is ours) ----------

def upstream_sha(repo):
    rc, sha, _ = run(["git", "rev-parse", "@{u}"], repo)
    return sha if rc == 0 else ""


def feature_branch(repo, cfg):
    """The current branch if it's one we'd ever watch (a feature branch with a remote), else None."""
    b = current_branch(repo)
    if not b or b.startswith(cfg["skip_marker"]) or b in COMMON_TRUNKS:
        return None
    remote = remote_name(repo)
    if not remote or b == default_branch(repo, remote):
        return None
    return b


def session_path(repo):
    return os.path.join(git_dir(repo), "mr-watchdog-session.json")


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
    """UserPromptSubmit: stamp the branch's pushed state at turn start, so a later push is detectable."""
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    branch = feature_branch(repo, cfg)
    if not branch:
        return
    st = read_session(repo)
    if not st or st.get("session") != args.session:
        st = {"session": args.session, "branches": {}}
    if branch not in st["branches"]:
        st["branches"][branch] = {"base": upstream_sha(repo), "engaged": False}
        write_session(repo, st)


def engaged(repo, cfg, session):
    """True if THIS session is responsible for the current branch's pipeline — i.e. it pushed it (the
    branch's @{u} advanced since this session's baseline). `enabled: false` opts a repo out."""
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
    if upstream_sha(repo) != (entry.get("base") or ""):
        entry["engaged"] = True
        write_session(repo, st)
        return True
    return False


def cmd_engaged(args):
    repo = os.path.abspath(args.repo)
    print("yes" if engaged(repo, load_config(repo, args.config), args.session) else "no")


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


# --- the watch loop (read-only: poll → surface) ----------------------------------------------------

def guard_state(repo, cfg):
    """Returns (branch, forge, remote) or raises a string reason it must not watch."""
    rc, _, _ = run(["git", "rev-parse", "--is-inside-work-tree"], repo)
    if rc != 0:
        raise ValueError("not-a-git-repo")
    branch = current_branch(repo)
    if not branch:
        raise ValueError("detached-or-unborn")
    if branch.startswith(cfg["skip_marker"]):
        raise ValueError("skip-marker")
    remote = remote_name(repo)
    if not remote:
        raise ValueError("no-remote")
    base = default_branch(repo, remote)
    if branch == base or branch in COMMON_TRUNKS:
        raise ValueError("on-default-branch")
    forge = detect_forge(repo, cfg, remote)
    if forge == "unknown" or not which(forge_cli(forge) or ""):
        raise ValueError("no-forge-cli")
    return branch, forge, remote


def tick(repo, cfg, branch, forge, remote):
    """One poll. Returns {'state': continue|green|needs-fix|no-mr|branch-changed}. Read-only."""
    if current_branch(repo) != branch:
        return {"state": "branch-changed"}
    if not mr_open(repo, forge, branch):
        return {"state": "no-mr"}
    status = ci_status(repo, forge, branch)
    if status == "success":
        return {"state": "green"}
    if status == "failed":
        log = failing_log(repo, forge, branch)
        tail = "\n".join(log.splitlines()[-int(cfg["log_lines"]):])
        return {"state": "needs-fix", "log": tail}
    return {"state": "continue", "ci": status}


def terminate(repo, cfg, state, reason):
    write_status(repo, state=state, reason=reason, head=head_sha(repo), announced=False)
    notify(repo, cfg, state, reason)
    clear_lock(repo)


def run_loop(repo, cfg):
    import time
    try:
        branch, forge, remote = guard_state(repo, cfg)
    except ValueError as e:
        terminate(repo, cfg, "stopped", str(e))
        return
    write_status(repo, state="watching", branch=branch, head=head_sha(repo), announced=False, reason=None)
    while True:
        try:
            if guard_state(repo, cfg)[0] != branch:
                terminate(repo, cfg, "stopped", "branch-moved")
                return
        except ValueError as e:
            terminate(repo, cfg, "stopped", str(e))
            return
        res = tick(repo, cfg, branch, forge, remote)
        st = res["state"]
        if st == "green":
            terminate(repo, cfg, "green", None)
            return
        if st in ("no-mr", "branch-changed"):
            terminate(repo, cfg, "stopped", st)
            return
        if st == "needs-fix":
            head = head_sha(repo)
            if (read_status(repo) or {}).get("handoff_head") != head:
                write_status(repo, state="needs-fix", branch=branch, head=head, handoff_head=head,
                             log=res.get("log", ""), announced=False, reason=None)
                notify(repo, cfg, "needs-fix", None)
        time.sleep(max(5, int(cfg["poll_interval"])))


def notify(repo, cfg, state, reason):
    msg = {"green": "ok c'est bon — CI au vert",
           "needs-fix": f"CI rouge sur {os.path.basename(repo)} — à corriger (handoff)",
           "stopped": f"arrêt : {reason or ''}"}.get(state)
    if msg and cfg.get("notify") == "desktop" and sys.platform == "darwin":
        run(["osascript", "-e", f'display notification "{msg}" with title "mr-watchdog"'], repo)


# --- commands --------------------------------------------------------------------------------------

def cmd_start(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    if not cfg.get("enabled", True):
        return
    if watcher_alive(repo):
        if args.verbose:
            print("[mr-watchdog] already watching")
        return
    try:
        branch, forge, remote = guard_state(repo, cfg)
    except ValueError as e:
        if args.verbose:
            print(f"[mr-watchdog] not starting: {e}")
        return
    if not mr_open(repo, forge, branch):
        if args.verbose:
            print("[mr-watchdog] no open MR for this branch")
        return
    if not acquire_lock(repo):
        return
    logf = open(os.path.join(git_dir(repo), "mr-watchdog.log"), "a")
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_run", "--repo", repo],
                         stdout=logf, stderr=logf, stdin=subprocess.DEVNULL,
                         start_new_session=True, cwd=repo)
    write_lock(repo, p.pid)
    print(f"[mr-watchdog] watching {branch} (pid {p.pid})")


def cmd_run(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    write_lock(repo, os.getpid())
    run_loop(repo, cfg)


def cmd_stop(args):
    import signal
    repo = os.path.abspath(args.repo)
    try:
        pid = int(open(lock_path(repo)).read().strip())
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    clear_lock(repo)
    write_status(repo, state="stopped", reason="manual")
    print("[mr-watchdog] stopped")


def cmd_reset(args):
    repo = os.path.abspath(args.repo)
    clear_lock(repo)
    try:
        os.remove(status_path(repo))
    except OSError:
        pass
    print("[mr-watchdog] reset")


def cmd_status(args):
    repo = os.path.abspath(args.repo)
    print(json.dumps(read_status(repo) or {"state": "none"}, indent=2))


def handoff_message(st):
    log = (st.get("log") or "")[-4000:]
    return (f"[mr-watchdog] ⚠ CI rouge sur '{st.get('branch')}'. Corrige la CAUSE RACINE — pas de "
            f"contournement (ne désactive/supprime/affaiblis aucun test, pas de --no-verify, || true, "
            f"seuils baissés…). Puis `watch.py verify` avant de committer. Log du job en échec :\n" + log)


def fix_instruction(repo, st):
    log = (st.get("log") or "")[-4000:]
    verify = f"python3 {os.path.abspath(__file__)} verify --repo {repo}"
    return ("The CI pipeline for merge-request branch '" + str(st.get("branch")) + "' is failing. Fix "
            "the ROOT CAUSE of the failure now. Do NOT fake green: never disable, skip, delete, or "
            "weaken a test; no --no-verify, no `|| true`, no continue-on-error/allow_failure, no "
            "lowered coverage or thresholds. Make the minimal correct change. Then run `" + verify +
            "` and only commit/push if it passes. If the only way to make it pass is a workaround, "
            "STOP and explain instead. Failing job log:\n" + log)


def cmd_announce(args):
    repo = os.path.abspath(args.repo)
    st = read_status(repo)
    if not st or st.get("announced") or st.get("state") == "watching":
        return
    if st.get("state") == "needs-fix":
        print(handoff_message(st))
    else:
        msg = {"green": "ok c'est bon — CI au vert",
               "stopped": f"arrêt : {st.get('reason') or ''}"}.get(st.get("state"))
        if msg:
            print(f"[mr-watchdog] {msg}")
    write_status(repo, announced=True)


def cmd_hook(args):
    """The Stop hook's mouthpiece: on a fresh red handoff, either continue the live session to fix it
    (on_red=fix → emit a block decision) or just surface it (on_red=notify). Marks it handled."""
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    st = read_status(repo)
    if not st or st.get("announced") or st.get("state") == "watching":
        return
    state = st.get("state")
    if state == "needs-fix":
        write_status(repo, announced=True)
        if cfg.get("on_red", "fix") == "fix":
            print(json.dumps({"decision": "block", "reason": fix_instruction(repo, st)}))
        else:
            print(handoff_message(st))
    elif state == "green":
        write_status(repo, announced=True)
        print("[mr-watchdog] ok c'est bon — CI au vert")


def cmd_verify(args):
    repo = os.path.abspath(args.repo)
    reason = fake_green(repo)
    if reason:
        print(f"[mr-watchdog] ✗ fake-green: {reason} — fix the root cause, don't hide the failure")
        sys.exit(1)
    print("[mr-watchdog] ✓ no bypass detected — the change addresses the failure, not the check")


def cmd_tick(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    branch, forge, remote = guard_state(repo, cfg)
    print(json.dumps(tick(repo, cfg, branch, forge, remote), indent=2))


def main():
    ap = argparse.ArgumentParser(description="mr-watchdog")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("start", cmd_start), ("_run", cmd_run), ("stop", cmd_stop), ("reset", cmd_reset),
                     ("status", cmd_status), ("announce", cmd_announce), ("hook", cmd_hook),
                     ("baseline", cmd_baseline), ("engaged", cmd_engaged),
                     ("verify", cmd_verify), ("tick", cmd_tick)):
        s = sub.add_parser(name)
        s.add_argument("--repo", default=".")
        s.add_argument("--config")
        s.add_argument("--session", default="")
        s.add_argument("--verbose", action="store_true")
        s.set_defaults(fn=fn)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
