#!/usr/bin/env python3
"""argv or stdin: changed paths → the plugin dirs whose suites must run, or FULL.
Conservative by construction: any path outside plugins/<name>/ forces the full gate."""
import re, sys


def impacted(paths):
    plugins = set()
    for p in paths:
        m = re.match(r"plugins/([^/]+)/", p)
        if not m:
            return None
        plugins.add(m.group(1))
    return sorted(plugins) or None


paths = sys.argv[1:] if len(sys.argv) > 1 else sys.stdin.read().splitlines()
names = impacted([p.strip() for p in paths if p.strip()])
print("FULL" if names is None else "\n".join(f"plugins/{n}" for n in names))
