#!/usr/bin/env python3
"""UserPromptSubmit: hand the prompt to repro.py nudge — when it looks like a bug/fix request, the
evidence-first protocol (failing repro before the fix, same probe proves the fix) is injected as
context, once per session per repo. All policy lives in repro.py."""
import json, os, subprocess, sys


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "repro-first", "scripts", "repro.py")
    cwd = payload.get("cwd") or ""
    if not cwd:
        return
    try:
        r = subprocess.run([sys.executable, script, "nudge", "--repo", cwd,
                            "--session", payload.get("session_id") or "",
                            "--prompt", (payload.get("prompt") or "")[:4000]],
                           timeout=15, capture_output=True, text=True)
        if r.stdout.strip():
            sys.stdout.write(r.stdout)
    except Exception:
        pass


if __name__ == "__main__":
    main()
