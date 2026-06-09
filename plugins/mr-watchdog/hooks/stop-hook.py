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
    session = payload.get("session_id") or ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "mr-watchdog", "scripts", "watch.py")
    # only engage a branch THIS session pushed (its pipeline is ours) — not one we're merely visiting
    try:
        r = subprocess.run([sys.executable, script, "engaged", "--repo", cwd, "--session", session],
                           timeout=20, capture_output=True, text=True)
        if (r.stdout or "").strip() != "yes":
            return
    except Exception:
        return
    # (re)launch the background watcher — output suppressed so it can't corrupt the decision below
    try:
        subprocess.run([sys.executable, script, "start", "--repo", cwd], timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    # emit the handoff: a `block` decision to continue this interactive session into a fix, or a plain
    # notice. Its stdout IS the hook's stdout, which Claude Code parses.
    try:
        subprocess.run([sys.executable, script, "hook", "--repo", cwd], timeout=30)
    except Exception:
        pass


if __name__ == "__main__":
    main()
