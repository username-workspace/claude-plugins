#!/usr/bin/env python3
"""Collect git productivity + quality metrics across one or more repos.

Repo-agnostic: works on a single git repo or a workspace of git submodules.
All project-specifics live in an optional config file — nothing is hardcoded.

Usage: collect-metrics.py <root> <since> <until> <months_count> [config.json]
Config is also auto-loaded from <root>/.delivery-metrics.json if present.
Output: JSON to stdout.

Config (all optional):
{
  "repos": ["."]                 // relative paths; default: auto-detect submodules, else ["."]
  "ticket_pattern": "\\b([A-Z][A-Z0-9]+-\\d+)\\b",
  "fix_pattern": "\\b(fix|hotfix|bugfix)\\b",
  "big_commit_lines": 500, "tiny_commit_lines": 5, "noise_floor": 5,
  "author_aliases": { "Jane": "Jane Doe" },
  "exclude": ["CI Bot"],          // hidden from charts (kept in raw developers)
  "holidays": ["2026-01-01"],     // ISO dates excluded from working days
  "leaves": [ { "author": "Jane Doe", "start": "2026-05-01", "end": "2026-05-05", "fraction": 1.0 } ]
}
"""
import configparser
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta

DEFAULTS = {
    "repos": None,
    "ticket_pattern": r"\b([A-Z][A-Z0-9]+-\d+)\b",
    "fix_pattern": r"\b(fix|hotfix|bugfix)\b",
    "big_commit_lines": 500,
    "tiny_commit_lines": 5,
    "noise_floor": 5,
    "author_aliases": {},
    "exclude": [],
    "holidays": [],
    "leaves": [],
}


def run_git(repo_path, args, timeout=120):
    try:
        r = subprocess.run(["git"] + args, cwd=repo_path, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def detect_repos(root):
    gm = os.path.join(root, ".gitmodules")
    if os.path.isfile(gm):
        cp = configparser.ConfigParser()
        try:
            cp.read(gm)
            paths = [cp.get(s, "path") for s in cp.sections() if cp.has_option(s, "path")]
            paths = [p for p in paths if os.path.isdir(os.path.join(root, p, ".git")) or os.path.isfile(os.path.join(root, p, ".git"))]
            if paths:
                return paths
        except configparser.Error:
            pass
    return ["."]


def default_branch(repo_path):
    head = run_git(repo_path, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]).strip()
    if head:
        return head  # e.g. "origin/main"
    cur = run_git(repo_path, ["symbolic-ref", "--quiet", "--short", "HEAD"]).strip()
    return cur or "HEAD"


def month_ranges(since, until):
    cur = datetime.strptime(since, "%Y-%m-%d")
    end = datetime.strptime(until, "%Y-%m-%d")
    while cur < end:
        nm, ny = cur.month + 1, cur.year
        if nm > 12:
            nm, ny = 1, ny + 1
        nxt = datetime(ny, nm, 1)
        yield cur.strftime("%Y-%m-%d"), min(nxt, end).strftime("%Y-%m-%d"), f"{cur.year}-{cur.month:02d}"
        cur = nxt


def leave_fraction_on(leave, day_iso):
    if leave["start"] <= day_iso <= leave["end"]:
        return float(leave.get("fraction", 1.0))
    return 0.0


def workdays_in_range(start_iso, end_excl_iso, leaves, holidays):
    n = 0.0
    leave_days = 0.0
    d = date.fromisoformat(start_iso)
    end = date.fromisoformat(end_excl_iso)
    while d < end:
        iso = d.isoformat()
        if d.weekday() < 5 and iso not in holidays:
            off = min(1.0, max((leave_fraction_on(l, iso) for l in leaves), default=0.0))
            n += max(0.0, 1.0 - off)
            leave_days += off
        d += timedelta(days=1)
    return n, leave_days


def collect_repo_commits(repo_path, since, until):
    args = ["log", "--all", f"--since={since}", f"--until={until}", "--no-merges",
            "--pretty=format:__C__%H|%an|%ai|%s", "--numstat"]
    out = run_git(repo_path, args)
    commits = []
    cur = None
    for line in out.split("\n"):
        if line.startswith("__C__"):
            parts = line[5:].split("|", 3)
            if len(parts) == 4:
                cur = {"sha": parts[0], "author": parts[1], "date": parts[2], "subject": parts[3],
                       "files": 0, "ins": 0, "dels": 0}
                commits.append(cur)
        elif cur and line and "\t" in line:
            a, b, _ = line.split("\t", 2)
            cur["files"] += 1
            cur["ins"] += int(a) if a.isdigit() else 0
            cur["dels"] += int(b) if b.isdigit() else 0
    return commits


def sha_set_on_default(repo_path, branch, since, until):
    out = run_git(repo_path, ["log", branch, f"--since={since}", f"--until={until}", "--no-merges", "--format=%H"])
    return set(s for s in out.strip().split("\n") if s)


def main_subjects_by_author(repo_path, branch, since, until, alias):
    out = run_git(repo_path, ["log", branch, f"--since={since}", f"--until={until}", "--no-merges", "--format=%an\t%s"])
    by_author = defaultdict(set)
    for line in out.strip().split("\n"):
        if "\t" in line:
            author, subject = line.split("\t", 1)
            by_author[alias.get(author, author)].add(subject)
    return by_author


def load_config(root, explicit):
    cfg = dict(DEFAULTS)
    path = explicit or os.path.join(root, ".delivery-metrics.json")
    if path and os.path.isfile(path):
        try:
            cfg.update({k: v for k, v in json.load(open(path, encoding="utf-8")).items() if v is not None})
        except (ValueError, OSError) as e:
            print(f"WARN: config {path} ignored: {e}", file=sys.stderr)
    if not cfg["repos"]:
        cfg["repos"] = detect_repos(root)
    return cfg


def main():
    if len(sys.argv) < 4:
        print("Usage: collect-metrics.py <root> <since> <until> [months] [config.json]", file=sys.stderr)
        sys.exit(1)
    root, since, until = sys.argv[1], sys.argv[2], sys.argv[3]
    months_count = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    cfg = load_config(root, sys.argv[5] if len(sys.argv) > 5 else None)

    alias = cfg["author_aliases"]
    ticket_re = re.compile(cfg["ticket_pattern"])
    fix_re = re.compile(cfg["fix_pattern"], re.IGNORECASE)
    revert_re = re.compile(r"^revert\b", re.IGNORECASE)
    holidays = set(cfg["holidays"])
    leaves_by_author = defaultdict(list)
    for lv in cfg["leaves"]:
        leaves_by_author[alias.get(lv["author"], lv["author"])].append(lv)

    all_commits = []
    sha_on_main = set()
    main_subjects = defaultdict(lambda: defaultdict(set))
    for repo in cfg["repos"]:
        rp = os.path.join(root, repo)
        branch = default_branch(rp)
        for c in collect_repo_commits(rp, since, until):
            c["repo"] = repo
            all_commits.append(c)
        sha_on_main |= sha_set_on_default(rp, branch, since, until)
        for author, subjects in main_subjects_by_author(rp, branch, since, until, alias).items():
            main_subjects[repo][author] = subjects

    devs = {}
    for c in all_commits:
        name = alias.get(c["author"], c["author"])
        d = devs.setdefault(name, {
            "commits_all": 0, "commits_main": 0, "wip": 0, "insertions": 0, "deletions": 0, "files_total": 0,
            "tickets_main": set(), "tickets_all": set(), "active_dates": set(),
            "fix": 0, "revert": 0, "no_ticket": 0, "big": 0, "tiny": 0, "repos": Counter(),
            "monthly": defaultdict(lambda: {"commits_main": 0, "tickets": set(), "lines": 0, "dates": set(), "fix": 0}),
        })
        d["commits_all"] += 1
        on_main = c["sha"] in sha_on_main
        if not on_main and c["subject"] not in main_subjects.get(c["repo"], {}).get(name, set()):
            d["wip"] += 1
        s = c["subject"]
        m = ticket_re.search(s)
        ticket = m.group(1) if m else None
        if ticket:
            d["tickets_all"].add(ticket)
        total_lines = c["ins"] + c["dels"]
        if on_main:
            d["commits_main"] += 1
            d["insertions"] += c["ins"]
            d["deletions"] += c["dels"]
            d["files_total"] += c["files"]
            d["active_dates"].add(c["date"][:10])
            d["repos"][c["repo"]] += 1
            if ticket:
                d["tickets_main"].add(ticket)
            else:
                d["no_ticket"] += 1
            if fix_re.search(s):
                d["fix"] += 1
            if revert_re.match(s):
                d["revert"] += 1
            if total_lines > cfg["big_commit_lines"]:
                d["big"] += 1
            if total_lines < cfg["tiny_commit_lines"]:
                d["tiny"] += 1
            mb = d["monthly"][c["date"][:7]]
            mb["commits_main"] += 1
            mb["lines"] += total_lines
            mb["dates"].add(c["date"][:10])
            if ticket:
                mb["tickets"].add(ticket)
            if fix_re.search(s):
                mb["fix"] += 1

    months = [m for _, _, m in month_ranges(since, until)]
    total_wd, leave_days, monthly_wd = {}, {}, {}
    for name in devs:
        lv = leaves_by_author.get(name, [])
        wd, ld = workdays_in_range(since, until, lv, holidays)
        total_wd[name], leave_days[name] = round(wd, 1), round(ld, 1)
        monthly_wd[name] = {label: round(workdays_in_range(ms, me, lv, holidays)[0], 1) for ms, me, label in month_ranges(since, until)}

    developers = {}
    for name, d in devs.items():
        tickets = len(d["tickets_main"])
        cm, ca = d["commits_main"], d["commits_all"]
        ad = len(d["active_dates"])
        wd = total_wd[name]
        developers[name] = {
            "commits": cm, "commits_all_branches": ca, "commits_main": cm,
            "insertions": d["insertions"], "deletions": d["deletions"],
            "tickets": tickets, "tickets_in_progress": len(d["tickets_all"] - d["tickets_main"]),
            "tickets_touched_total": len(d["tickets_all"]),
            "active_days": ad, "workdays_available": wd, "leave_days": leave_days[name],
            "utilization_pct": round(ad / wd * 100, 1) if wd > 0 else 0,
            "velocity_tickets_per_workday": round(tickets / wd, 2) if wd > 0 else 0,
            "fix_commits": d["fix"], "fix_ratio_pct": round(d["fix"] / cm * 100, 1) if cm else 0,
            "revert_commits": d["revert"], "no_ticket_commits": d["no_ticket"],
            "big_commits": d["big"], "tiny_commits": d["tiny"],
            "mean_lines_per_commit": round((d["insertions"] + d["deletions"]) / cm, 1) if cm else 0,
            "mean_files_per_commit": round(d["files_total"] / cm, 2) if cm else 0,
            "repos_touched": dict(d["repos"]),
            "primary_repo": d["repos"].most_common(1)[0][0] if d["repos"] else None,
            "repos_touched_count": sum(1 for _, n in d["repos"].items() if n >= cfg["noise_floor"]),
        }

    monthly = {"months": months, "commits": {}, "tickets": {}, "lines": {}, "active_days": {},
               "workdays_available": {}, "velocity": {}, "fix_ratio": {}, "utilization": {}}
    for name, d in devs.items():
        for key in monthly:
            if key != "months":
                monthly[key][name] = []
        for label in months:
            mb = d["monthly"].get(label, {"commits_main": 0, "tickets": set(), "lines": 0, "dates": set(), "fix": 0})
            wd = monthly_wd[name][label]
            cm, t, adm = mb["commits_main"], len(mb["tickets"]), len(mb["dates"])
            monthly["commits"][name].append(cm)
            monthly["tickets"][name].append(t)
            monthly["lines"][name].append(mb["lines"])
            monthly["active_days"][name].append(adm)
            monthly["workdays_available"][name].append(wd)
            monthly["velocity"][name].append(round(t / wd, 2) if wd > 0 else 0)
            monthly["fix_ratio"][name].append(round(mb["fix"] / cm * 100, 1) if cm > 0 else 0)
            monthly["utilization"][name].append(round(adm / wd * 100, 1) if wd > 0 else 0)

    json.dump({
        "developers": developers,
        "monthly": monthly,
        "metadata": {
            "since": since, "until": until, "months": months_count,
            "generated": datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
            "root": root, "repos": cfg["repos"], "noise_floor": cfg["noise_floor"],
            "hidden_from_charts": sorted(cfg["exclude"]),
            "holidays": sorted(holidays),
        },
    }, sys.stdout, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
