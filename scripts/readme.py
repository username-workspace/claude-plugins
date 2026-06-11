#!/usr/bin/env python3
"""Regenerate README.md's plugin table from marketplace.json + each plugin's web.json tagline.
`--check` exits non-zero when the README is stale — wired into CI, so the storefront cannot drift
from the catalogue again (it once advertised 1 plugin out of 10)."""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEGIN, END = "<!-- plugins:begin -->", "<!-- plugins:end -->"


def plugin_table():
    mp = json.load(open(os.path.join(ROOT, ".claude-plugin", "marketplace.json")))
    rows = []
    for pl in mp["plugins"]:
        web = json.load(open(os.path.join(ROOT, pl["source"], "web.json")))
        rows.append((web.get("category", ""), pl["name"], pl["version"], web.get("tagline", "")))
    rows.sort()
    lines = ["| Plugin | Version | Category | What it does |", "|---|---|---|---|"]
    for cat, name, ver, tag in rows:
        lines.append(f"| [`{name}`](./plugins/{name}) | {ver} | {cat} | {tag} |")
    return "\n".join(lines)


def main():
    path = os.path.join(ROOT, "README.md")
    current = open(path).read()
    if BEGIN not in current or END not in current:
        print(f"README.md is missing the {BEGIN} / {END} markers")
        sys.exit(1)
    regenerated = re.sub(re.escape(BEGIN) + ".*?" + re.escape(END),
                         BEGIN + "\n" + plugin_table() + "\n" + END, current, flags=re.S)
    if "--check" in sys.argv:
        if regenerated != current:
            print("README.md is stale vs marketplace.json — run: python3 scripts/readme.py")
            sys.exit(1)
        print("README.md is in sync with marketplace.json")
        return
    open(path, "w").write(regenerated)
    print("README.md regenerated")


if __name__ == "__main__":
    main()
