#!/usr/bin/env python3
"""PostToolUse hook: whenever a catalogue file is edited (marketplace.json, a plugin's web.json or
plugin.json), regenerate README.md on the spot — the storefront self-heals locally instead of waiting
for the CI sync check to go red at merge time."""
import json, os, subprocess, sys

CATALOGUE = {"marketplace.json", "web.json", "plugin.json"}


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    path = (payload.get("tool_input") or {}).get("file_path") or ""
    if os.path.basename(path) not in CATALOGUE:
        return
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        subprocess.run([sys.executable, os.path.join(root, "scripts", "readme.py")],
                       timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


if __name__ == "__main__":
    main()
