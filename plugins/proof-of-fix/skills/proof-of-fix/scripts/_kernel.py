"""Shared kernel of the delivery-harness plugins (ship-when-done, mr-watchdog, merge-review,
proof-of-fix). SOURCE OF TRUTH: lib/_kernel.py — vendored byte-identical into each plugin's
scripts/ dir by `python3 scripts/kernel-sync.py` (CI and the harness suite fail on drift); edit it
HERE, never in a vendored copy. Stateless on purpose: plugin identity (the .git/ state-file names)
stays in each plugin, so a process that loads two plugins can never cross their state."""
import json
import os
import re
import subprocess
from datetime import datetime, timedelta, timezone


def run(cmd, cwd, check=False, raw=False, timeout=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        if check:
            raise
        return (127, "", f"{cmd[0]}: not found")
    except subprocess.TimeoutExpired:
        return (124, "", "timed out")
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {p.stderr.strip()}")
    return (p.returncode, p.stdout if raw else p.stdout.strip(), p.stderr.strip())


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
    """The git repo root we're actually working in: the one named in a push command; else, in a
    submodule workspace (cwd repo has .gitmodules), the repo of the most-recently edited file when it
    is nested inside the cwd's — acting on the superproject would only bump a pointer; else the cwd's
    repo, else the edited file's. None when no git repo is in scope."""
    if command:
        p = repo_from_command(command)
        if p:
            if not os.path.isabs(p) and cwd:
                p = os.path.join(cwd, p)
            r = git_toplevel(p)
            if r:
                return r
    cwd_repo = git_toplevel(cwd) if cwd else None
    if cwd_repo and transcript and os.path.isfile(os.path.join(cwd_repo, ".gitmodules")):
        f = last_edited_file(transcript)
        if f:
            edited = git_toplevel(os.path.dirname(f))
            if edited and edited != cwd_repo and edited.startswith(cwd_repo + os.sep):
                return edited
    if cwd_repo:
        return cwd_repo
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


def write_json(path, data):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


SESSION_GC_DAYS = 7


def read_sessions(path):
    """v1 multi-session map. Anything else — absent, corrupt, or pre-v1 (the one-minor migration
    window is closed) — reads as empty and is rewritten as v1 on the next write."""
    try:
        st = json.load(open(path))
    except Exception:
        st = None
    if isinstance(st, dict) and "v" in st and isinstance(st.get("sessions"), dict):
        return st
    return {"v": 1, "sessions": {}}


def write_sessions(path, st):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SESSION_GC_DAYS)).isoformat()
    st["sessions"] = {k: v for k, v in st["sessions"].items() if (v.get("started") or cutoff) >= cutoff}
    try:
        write_json(path, st)
    except OSError:
        pass


def read_state(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def write_state(path, data):
    try:
        write_json(path, data)
    except OSError:
        pass


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
