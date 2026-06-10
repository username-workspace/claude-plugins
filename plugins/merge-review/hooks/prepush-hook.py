#!/usr/bin/env python3
"""PreToolUse(Bash): the pre-push gate. When this session is about to push a branch it produced and the
current HEAD has no passing review on record, deny the push and ask the session to run /merge-review
(fix the attested findings, loop until the score clears the threshold) first. The repo gated is the one
NAMED in the push command (git -C X / cd X), else the cwd's repo — not the launch dir. All policy lives
in review.py gate — this only recognises a real `git push` and passes its decision through."""
import json, os, re, subprocess, sys

PUSH = re.compile(r"\bgit\b(?:\s+-C\s+\S+|\s+-c\s+\S+|\s+--\S+|\s+-\w+)*\s+push\b", re.I)
NOT_A_PUSH = re.compile(r"--help\b|--dry-run\b|--delete\b|\s-d\b|:\s*$", re.I)


def resolve(script, cwd, transcript="", command=""):
    try:
        r = subprocess.run([sys.executable, script, "resolve", "--cwd", cwd or "",
                            "--transcript", transcript or "", "--command", command or ""],
                           timeout=15, capture_output=True, text=True)
        return r.stdout.strip()
    except Exception:
        return ""


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if payload.get("tool_name") != "Bash":
        return
    cmd = ((payload.get("tool_input") or {}).get("command")) or ""
    if not PUSH.search(cmd) or NOT_A_PUSH.search(cmd):
        return
    session = payload.get("session_id") or ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "merge-review", "scripts", "review.py")
    repo = resolve(script, payload.get("cwd") or "", "", cmd)
    if not repo:
        return
    try:
        r = subprocess.run([sys.executable, script, "gate", "--repo", repo, "--session", session],
                           timeout=25, capture_output=True, text=True)
        if r.stdout.strip():
            sys.stdout.write(r.stdout)
    except Exception:
        pass


if __name__ == "__main__":
    main()
