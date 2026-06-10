#!/usr/bin/env python3
"""Stop: let repro.py decide whether an open repro must be re-proven — it re-runs the probe itself
(green → auto-proven systemMessage, red → a bounded `block` with the failing output). All policy lives
in repro.py."""
import json, os, subprocess, sys


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "repro-first", "scripts", "repro.py")
    cwd = payload.get("cwd") or os.getcwd()
    try:
        r = subprocess.run([sys.executable, script, "hook", "--repo", cwd,
                            "--session", payload.get("session_id") or ""],
                           timeout=150, capture_output=True, text=True)
        if r.stdout.strip():
            sys.stdout.write(r.stdout)
    except Exception:
        pass


if __name__ == "__main__":
    main()
