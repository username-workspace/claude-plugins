#!/usr/bin/env python3
"""PostToolUse(Edit|Write|NotebookEdit): record the edited file's repo + path as THIS session's work.
Provenance is observed, never inferred — it is what `engaged` trusts first."""
import json, os, subprocess, sys


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    tool_input = payload.get("tool_input") or {}
    fp = (tool_input.get("file_path") or tool_input.get("notebook_path") or "").strip()
    session = payload.get("session_id") or ""
    if not fp or not session:
        return
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "ship-when-done", "scripts", "ship.py")
    try:
        subprocess.run([sys.executable, script, "provenance", "--file", fp, "--session", session],
                       timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


if __name__ == "__main__":
    main()
