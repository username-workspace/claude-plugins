#!/usr/bin/env python3
"""Stop-hook plumbing: resolve the repo we're working in, then let watch.py decide whether to nudge this
session to launch the background CI watcher (a `block` continuation). All policy lives in watch.py."""
import json, os, subprocess, sys


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
    if payload.get("stop_hook_active"):
        return
    session = payload.get("session_id") or ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "mr-watchdog", "scripts", "watch.py")
    repo = resolve(script, payload.get("cwd") or "", payload.get("transcript_path") or "")
    if not repo:
        return
    try:
        r = subprocess.run([sys.executable, script, "hook", "--repo", repo, "--session", session],
                           timeout=30, capture_output=True, text=True)
        if r.stdout.strip():
            sys.stdout.write(r.stdout)
    except Exception:
        pass


if __name__ == "__main__":
    main()
