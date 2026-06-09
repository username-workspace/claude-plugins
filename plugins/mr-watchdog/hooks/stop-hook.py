#!/usr/bin/env python3
"""Stop-hook plumbing: surface the watchdog's latest result, then (idempotently) launch a watcher for
the current branch's open MR. Opt-in and all guardrails live in watch.py."""
import json, os, subprocess, sys


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if payload.get("stop_hook_active"):
        return
    cwd = payload.get("cwd") or os.getcwd()
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "mr-watchdog", "scripts", "watch.py")
    for cmd in ("announce", "start"):
        try:
            subprocess.run([sys.executable, script, cmd, "--repo", cwd], timeout=30)
        except Exception:
            pass


if __name__ == "__main__":
    main()
