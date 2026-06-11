#!/usr/bin/env python3
"""Vendor lib/_kernel.py byte-identical into each harness plugin's scripts/ dir, so installed
plugins stay self-contained while the repo keeps one source of truth. `--check` exits non-zero on
drift — wired into CI and tests/harness, so a copy can never silently diverge again (the session
schema was lockstep-patched by hand twice before this existed)."""
import glob
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "lib", "_kernel.py")
PLUGINS = ["ship-when-done", "mr-watchdog", "merge-review", "proof-of-fix"]


def copies():
    listed = {os.path.join(ROOT, "plugins", p, "skills", p, "scripts", "_kernel.py") for p in PLUGINS}
    found = set(glob.glob(os.path.join(ROOT, "plugins", "*", "skills", "*", "scripts", "_kernel.py")))
    return sorted(listed | found)


def main():
    check = "--check" in sys.argv[1:]
    src = open(SOURCE).read()
    stale = []
    for dest in copies():
        try:
            current = open(dest).read()
        except OSError:
            current = None
        if current != src:
            stale.append(os.path.relpath(dest, ROOT))
            if not check:
                shutil.copyfile(SOURCE, dest)
    if check and stale:
        print("vendored kernel out of sync (run: python3 scripts/kernel-sync.py):")
        for p in stale:
            print(f"  {p}")
        sys.exit(1)
    print("kernel copies in sync" if not stale else f"kernel synced to {len(stale)} plugin(s)")


if __name__ == "__main__":
    main()
