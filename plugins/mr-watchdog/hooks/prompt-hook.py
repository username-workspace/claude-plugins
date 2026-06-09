#!/usr/bin/env python3
"""UserPromptSubmit: stamp the current branch's pushed state at the start of the turn, so the Stop hook
can tell whether THIS session advances (pushes) it — the signal that the pipeline is ours to watch."""
import json, os, subprocess, sys


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    cwd = payload.get("cwd") or os.getcwd()
    session = payload.get("session_id") or ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "mr-watchdog", "scripts", "watch.py")
    try:
        subprocess.run([sys.executable, script, "baseline", "--repo", cwd, "--session", session],
                       timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


if __name__ == "__main__":
    main()
