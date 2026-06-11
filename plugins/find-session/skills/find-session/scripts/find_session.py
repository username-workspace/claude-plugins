#!/usr/bin/env python3
"""
find-session — locate a past Claude Code session from concept terms, ranked by relevance.

Each positional argument is ONE concept, passed as a case-insensitive regex (use `a|b` for
variants). A transcript matches only if EVERY concept appears in it (cross-match) — far more
discriminating than a single term. Results rank by matching lines and recency; density and the
most frequent ticket-style key are shown as signals, plus a ready `claude --resume <id>` for the top.

Scope: the current project's transcripts (~/.claude/projects/<cwd-slug>/*.jsonl). Auto-widens to
every project when the current one is absent or yields nothing; --all forces an all-projects scan.
Override the root with CLAUDE_PROJECTS_DIR. Pure stdlib — works on macOS and Linux.
"""

import argparse
import os
import re
import shlex
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

PROJECTS = Path(os.environ.get("CLAUDE_PROJECTS_DIR", Path.home() / ".claude" / "projects"))
TICKET_RE = re.compile(r"[A-Z]{2,}-\d+")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
CWD_RE = re.compile(r'"cwd"\s*:\s*"([^"]+)"')


def slug_for(text):
    return re.sub(r"[^a-zA-Z0-9]", "-", str(text))


def all_dirs():
    if not PROJECTS.is_dir():
        return []
    return sorted(d for d in PROJECTS.iterdir() if d.is_dir())


SCAN_STATS = {"files_seen": 0, "files_counted": 0}  # observable: counted == survivors of the pre-gate


def scan(dirs, regexes, since):
    results = []
    SCAN_STATS["files_seen"] = SCAN_STATS["files_counted"] = 0
    for d in dirs:
        for f in d.glob("*.jsonl"):
            try:
                mtime = datetime.fromtimestamp(f.stat().st_mtime)
            except OSError:
                continue
            day = mtime.strftime("%Y-%m-%d")
            if since and day < since:
                continue
            SCAN_STATS["files_seen"] += 1
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            # cross-match pre-gate: a file missing ANY concept can't win — reject it with one search per
            # concept over the whole text, instead of len(lines) × len(concepts) line-by-line searches.
            # The majority of files fail here; only survivors pay for per-line counting below.
            if any(not rx.search(text) for rx in regexes):
                continue
            SCAN_STATS["files_counted"] += 1
            hits = [0] * len(regexes)
            tickets = Counter()
            lines = 0
            for line in text.splitlines():
                lines += 1
                for i, rx in enumerate(regexes):
                    if rx.search(line):
                        hits[i] += 1
                tickets.update(TICKET_RE.findall(line))
            if not lines or any(h == 0 for h in hits):
                continue
            total = sum(hits)
            top = tickets.most_common(1)[0] if tickets else None
            results.append({
                "id": f.stem,
                "project": d.name,
                "total": total,
                "lines": lines,
                "density": total * 1000 // lines,
                "key": f"{top[0]} (x{top[1]})" if top else "-",
                "date": mtime.strftime("%Y-%m-%d %H:%M"),
                "day": day,
            })
    return results


def session_cwd(transcript):
    """The session's working directory, recovered from its transcript — `claude --resume <id>` only
    resolves ids of the project it is launched FROM, so a cross-project resume needs a `cd` first."""
    last = None
    try:
        with transcript.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = CWD_RE.search(line)
                if m:
                    last = m.group(1)
    except OSError:
        return None
    return last


def resume_command(top):
    cmd = f"claude --resume {top['id']}"
    if top["project"] == slug_for(Path.cwd()):
        return cmd
    cwd = session_cwd(PROJECTS / top["project"] / f"{top['id']}.jsonl")
    return f"cd {shlex.quote(cwd)} && {cmd}" if cwd else cmd


def main():
    ap = argparse.ArgumentParser(add_help=True, description="Find a past Claude Code session.")
    ap.add_argument("concepts", nargs="*", help="one regex per concept; ALL must match")
    ap.add_argument("--since", default="", help="ISO date cutoff, e.g. 2026-05-20")
    ap.add_argument("--all", action="store_true", help="scan every project, not just the current one")
    ap.add_argument("--recent", action="store_true", help="sort by recency first")
    ap.add_argument("--limit", type=int, default=12)
    args = ap.parse_args()

    concepts = [c for c in args.concepts if c.strip()]
    if not concepts:
        ap.error("give at least one non-empty concept term")
    if args.since and not DATE_RE.fullmatch(args.since):
        ap.error("--since must be an ISO date (YYYY-MM-DD)")
    try:
        regexes = [re.compile(c, re.IGNORECASE) for c in concepts]
    except re.error as e:
        ap.error(f"invalid concept pattern ({e}); escape regex metacharacters, e.g. 'C\\+\\+'")
    if not PROJECTS.is_dir():
        print(f"No Claude Code transcripts found at {PROJECTS}.", file=sys.stderr)
        sys.exit(1)

    every = all_dirs()
    here = PROJECTS / slug_for(Path.cwd())
    primary = every if args.all or not here.is_dir() else [here]

    results = scan(primary, regexes, args.since)
    widened = False
    if not results and primary != every:
        results = scan(every, regexes, args.since)
        widened = bool(results)

    if not results:
        hint = f" or drop --since {args.since}" if args.since else ""
        print(f"No session matches all of: {', '.join(concepts)}. Try fewer or looser concepts{hint}.")
        sys.exit(0)

    results.sort(key=lambda r: (r["day"], r["total"]) if args.recent else (r["total"], r["day"]), reverse=True)
    show_project = args.all or widened or len({r["project"] for r in results}) > 1
    top = results[0]

    if widened:
        print("(no match in the current project — widened to all projects)\n")
    proj = f"  ·  project {top['project']}" if show_project else ""
    print(f"Best match: {top['id']}")
    print(f"   {top['total']} matching lines · {top['lines']} lines · density {top['density']}/1k · key {top['key']} · last {top['date']}{proj}")
    print(f"   resume:  {resume_command(top)}")

    if len(results) > 1:
        print("\nOther candidates:")
        for r in results[1:args.limit]:
            note = " · short+dense (report?)" if r["density"] >= 120 and r["lines"] < 400 else ""
            proj = f" · {r['project']}" if show_project else ""
            print(f" - {r['id']} — {r['total']} matching lines · {r['date']}{proj} · key {r['key']}{note}")


if __name__ == "__main__":
    main()
