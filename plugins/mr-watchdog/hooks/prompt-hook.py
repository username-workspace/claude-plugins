#!/usr/bin/env python3
"""UserPromptSubmit: stamp the active repo's branch pushed-state at turn start, so the Stop hook can tell
whether THIS session advances (pushes) it — the signal that the pipeline is ours to watch. The repo is
the one we're working in (resolved from cwd / recent edits), not the directory Claude was launched in."""
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
    session = payload.get("session_id") or ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "mr-watchdog", "scripts", "watch.py")
    repo = resolve(script, payload.get("cwd") or "", payload.get("transcript_path") or "")
    if not repo:
        return
    try:
        subprocess.run([sys.executable, script, "baseline", "--repo", repo, "--session", session],
                       timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


if __name__ == "__main__":
    main()
