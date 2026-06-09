#!/usr/bin/env python3
"""mr-watchdog — once a merge request is open, watch its remote CI in the background and drive it to
green by fixing failures at the root. Never bypasses a check, never merges, never touches the default
branch, never force-pushes. Opt-in per repo.

The loop is `tick`-shaped (one poll → at most one fix) so the daemon and the tests share the same code.
"""
import argparse, json, os, re, signal, subprocess, sys
from shutil import which

DEFAULTS = {
    "gate": None,
    "forge": None,                    # github | gitlab; auto-detected from the remote if null
    "poll_interval": 30,              # seconds between CI polls
    "max_fix_attempts": 3,           # hard cap on autonomous fix rounds (bounds credit spend)
    "fix_command": None,             # the headless fixer; defaults to `claude -p` (see fixer_command)
    "fix_timeout": 1200,             # seconds per fix attempt
    "notify": "status-file",         # status-file | desktop
    "skip_marker": "wip/",
}

COMMON_TRUNKS = {"main", "master", "develop", "trunk"}

# A "fix" that merely hides the failure instead of resolving it. The watchdog refuses these outright.
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
    r"#\s*noqa(?!:\s*E501)",                       # blanket noqa (line-length is benign)
    r"@ts-(?:ignore|nocheck|expect-error)",
    r"\bskip_tests?\b",
]


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


def tree_clean(repo):
    rc, _, _ = run(["git", "diff", "--quiet", "HEAD"], repo)
    return rc == 0


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
        rid = None
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


def carried_attempts(prev, branch, head):
    """Carry the attempt count across a restart only for the same branch AND head — so a user pushing a
    new commit to an exhausted branch gets a fresh budget (matching cmd_start's re-arm gate)."""
    if prev and prev.get("branch") == branch and prev.get("head") == head:
        return prev.get("attempts", 0)
    return 0


# --- the fix step ----------------------------------------------------------------------------------

def bypass_in_diff(diff):
    for pat in BYPASS_PATTERNS:
        m = re.search(pat, diff, re.I)
        if m:
            return m.group(0)
    return None


def added_lines(diff):
    return "\n".join(l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++"))


def fixer_command(cfg):
    if cfg.get("fix_command"):
        return ["bash", "-c", cfg["fix_command"]]
    return ["claude", "-p", "--permission-mode", "acceptEdits"]


FIX_PROMPT = (
    "A CI job for this merge request is failing. Study the failure below and fix the ROOT CAUSE in the "
    "working tree. Do NOT bypass the check: never disable, skip, delete or weaken a test; never add "
    "ignore/disable directives, `|| true`, continue-on-error, allow_failure, or --no-verify; never "
    "lower a threshold to hide the problem. Make the minimal correct change. Do not commit or push — "
    "just leave the fix in the working tree. If the only way to make it pass is a workaround, make NO "
    "change at all.\n\nFailing CI log:\n{log}\n"
)


TEST_PATH = re.compile(r"(^|/)(tests?/|test_|conftest|.*[._-](test|spec)\.)", re.I)


def untracked(repo):
    _, out, _ = run(["git", "ls-files", "--others", "--exclude-standard"], repo)
    return set(filter(None, out.splitlines()))


def revert_fix(repo, pre_untracked):
    """Undo the fixer's work only: reset tracked edits/staged deletions back to HEAD, delete files it
    created — never touch files the user already had untracked (reset --hard leaves those alone)."""
    run(["git", "reset", "--hard", "HEAD"], repo)
    for f in untracked(repo) - pre_untracked:
        try:
            os.remove(os.path.join(repo, f))
        except OSError:
            pass


def deleted_tests(repo):
    _, ns, _ = run(["git", "diff", "HEAD", "--name-status"], repo)
    return [p.split("\t")[-1] for p in ns.splitlines()
            if p[:1] == "D" and TEST_PATH.search(p.split("\t")[-1])]


def weakened_tests(repo):
    """A modified test file that drops an assertion is a fake-green, not a fix."""
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


def run_fixer(repo, cfg, log):
    if cfg.get("fix_command"):
        env = dict(os.environ, MR_WATCHDOG_LOG=log[:8000])
        try:
            return subprocess.run(["bash", "-c", cfg["fix_command"]], cwd=repo, env=env,
                                  capture_output=True, text=True, timeout=cfg["fix_timeout"]).returncode
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return 1
    rc, _, _ = run(fixer_command(cfg) + [FIX_PROMPT.format(log=log[:8000])], repo, timeout=cfg["fix_timeout"])
    return rc


def propose_fix(repo, cfg, log, branch):
    """Run the headless fixer, gatekeep its change, commit it only if it resolves the root cause.
    Returns 'pushed' | 'blocked:bypass:<hit>' | 'blocked:nofix' | 'blocked:fixer' | 'blocked:branch-moved'.
    On any block, only the fixer's own changes are reverted."""
    pre = untracked(repo)
    if run_fixer(repo, cfg, log) != 0:
        revert_fix(repo, pre)
        return "blocked:fixer"
    _, tracked, _ = run(["git", "diff", "HEAD"], repo)
    new_files = sorted(untracked(repo) - pre)
    if not tracked.strip() and not new_files:
        return "blocked:nofix"
    gutted = deleted_tests(repo)
    if gutted:
        revert_fix(repo, pre)
        return f"blocked:bypass:deleted-test:{gutted[0][-30:]}"
    weak = weakened_tests(repo)
    if weak:
        revert_fix(repo, pre)
        return f"blocked:bypass:weakened-test:{weak[-30:]}"
    scan = added_lines(tracked) + "\n" + "\n".join(read_capped(repo, f) for f in new_files)
    hit = bypass_in_diff(scan)
    if hit:
        revert_fix(repo, pre)
        return f"blocked:bypass:{hit[:40]}"
    if current_branch(repo) != branch:
        revert_fix(repo, pre)
        return "blocked:branch-moved"
    if new_files:
        run(["git", "add", "--"] + new_files, repo)
    run(["git", "add", "-u"], repo)
    run(["git", "commit", "-m", "fix: resolve failing CI check"], repo, check=True)
    return "pushed"


# --- the watch loop --------------------------------------------------------------------------------

def guard_state(repo, cfg):
    """Returns (branch, forge, remote) or raises a string reason it must not run."""
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
    """One cycle. Returns {'state': continue|green|failed-exhausted|blocked|no-mr|branch-changed}."""
    if current_branch(repo) != branch:
        return {"state": "branch-changed"}
    if not mr_open(repo, forge, branch):
        return {"state": "no-mr"}
    status = ci_status(repo, forge, branch)
    if status == "success":
        return {"state": "green"}
    if status in ("pending", "error", "none"):
        return {"state": "continue", "ci": status}
    if not tree_clean(repo):
        return {"state": "blocked", "reason": "dirty-tree"}
    attempts = (read_status(repo) or {}).get("attempts", 0)
    if attempts >= cfg["max_fix_attempts"]:
        return {"state": "failed-exhausted", "attempts": attempts}
    log = failing_log(repo, forge, branch)
    outcome = propose_fix(repo, cfg, log, branch)
    if outcome == "pushed":
        rc, _, err = run(["git", "push", remote, branch], repo)
        if rc != 0:
            return {"state": "blocked", "reason": f"push-failed:{err[:60]}"}
        return {"state": "continue", "attempts": attempts + 1, "fixed": True}
    return {"state": "blocked", "reason": outcome}


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
    prev = read_status(repo) or {}
    attempts = carried_attempts(prev, branch, head_sha(repo))
    write_status(repo, state="watching", branch=branch, head=head_sha(repo),
                 attempts=attempts, announced=False, reason=None)
    while True:
        try:
            if guard_state(repo, cfg)[0] != branch:
                terminate(repo, cfg, "stopped", "branch-moved")
                return
        except ValueError as e:
            terminate(repo, cfg, "stopped", str(e))
            return
        res = tick(repo, cfg, branch, forge, remote)
        state = res["state"]
        if "attempts" in res:
            write_status(repo, attempts=res["attempts"], head=head_sha(repo))
        if state == "continue":
            if res.get("fixed"):
                write_status(repo, state="fixing")
            time.sleep(max(5, int(cfg["poll_interval"])))
            continue
        terminal = {"green": "green", "no-mr": "stopped", "failed-exhausted": "exhausted",
                    "blocked": "blocked", "branch-changed": "stopped"}.get(state, "stopped")
        terminate(repo, cfg, terminal, res.get("reason"))
        return


def notify(repo, cfg, state, reason):
    msg = {"green": "ok c'est bon — CI au vert",
           "exhausted": f"CI toujours rouge après {cfg['max_fix_attempts']} tentatives — à toi de jouer",
           "blocked": f"arrêt : {reason or 'fix impossible sans contournement'}",
           "stopped": f"arrêt : {reason or ''}"}.get(state, state)
    if cfg.get("notify") == "desktop" and sys.platform == "darwin":
        run(["osascript", "-e", f'display notification "{msg}" with title "mr-watchdog"'], repo)


# --- commands --------------------------------------------------------------------------------------

def cmd_start(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    if not (os.path.isfile(os.path.join(repo, ".mr-watchdog.json")) or os.environ.get("MR_WATCHDOG")):
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
    st = read_status(repo) or {}
    if st.get("branch") == branch and st.get("head") == head_sha(repo) and st.get("state") in ("exhausted", "blocked"):
        if args.verbose:
            print(f"[mr-watchdog] {branch} is {st['state']} ({st.get('reason') or ''}); push a change or `reset` to retry")
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


def cmd_reset(args):
    repo = os.path.abspath(args.repo)
    clear_lock(repo)
    try:
        os.remove(status_path(repo))
    except OSError:
        pass
    print("[mr-watchdog] reset")


def cmd_stop(args):
    repo = os.path.abspath(args.repo)
    try:
        pid = int(open(lock_path(repo)).read().strip())
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    clear_lock(repo)
    write_status(repo, state="stopped", reason="manual")
    print("[mr-watchdog] stopped")


def cmd_status(args):
    repo = os.path.abspath(args.repo)
    print(json.dumps(read_status(repo) or {"state": "none"}, indent=2))


def cmd_announce(args):
    repo = os.path.abspath(args.repo)
    st = read_status(repo)
    if not st or st.get("announced") or st.get("state") in ("watching", "fixing"):
        return
    cfg = load_config(repo, args.config)
    msg = {"green": "ok c'est bon — CI au vert",
           "exhausted": f"CI toujours rouge après {cfg['max_fix_attempts']} tentatives — à toi de jouer",
           "blocked": f"arrêt : {st.get('reason') or 'fix impossible sans contournement'}",
           "stopped": f"arrêt : {st.get('reason') or ''}"}.get(st.get("state"))
    if msg:
        print(f"[mr-watchdog] {msg}")
    write_status(repo, announced=True)


def cmd_tick(args):
    repo = os.path.abspath(args.repo)
    cfg = load_config(repo, args.config)
    branch, forge, remote = guard_state(repo, cfg)
    print(json.dumps(tick(repo, cfg, branch, forge, remote), indent=2))


def main():
    ap = argparse.ArgumentParser(description="mr-watchdog")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("start", cmd_start), ("_run", cmd_run), ("stop", cmd_stop), ("reset", cmd_reset),
                     ("status", cmd_status), ("announce", cmd_announce), ("tick", cmd_tick)):
        s = sub.add_parser(name)
        s.add_argument("--repo", default=".")
        s.add_argument("--config")
        s.add_argument("--verbose", action="store_true")
        s.set_defaults(fn=fn)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
