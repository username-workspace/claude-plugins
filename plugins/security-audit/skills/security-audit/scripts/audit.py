#!/usr/bin/env python3
"""
security-audit — full Trivy scan (vulnerabilities + secrets + IaC misconfig) across every
ecosystem, rendered as an adapted Markdown report.

Only external dependency: Trivy (https://trivy.dev). Parses Trivy's JSON with the stdlib — no jq.
Language-agnostic by design: Trivy detects npm/yarn/pnpm/bun, pip/poetry/uv, Go, Cargo, Composer,
Maven/Gradle, NuGet, RubyGems, pub, and more, plus OS packages, hard-coded secrets, and IaC
misconfigurations. Report-only — it never modifies code; fixed versions are surfaced for the human.

Staying current: Trivy auto-refreshes its vulnerability DB on a daily cycle, and this script
triggers that refresh before scanning, then reports the DB's freshness and warns if it is stale
(e.g. offline). It never disables DB updates. Every run also validates the installed Trivy binary
against the latest release (cached 24h, fail-open offline); `--no-version-check` skips that.

By default the scan reflects what actually lives in the repo: it honours .gitignore (across
submodules too), and also skips nested git worktrees (duplicate checkouts) and test directories
(tests/test/__tests__ — not shipped to prod). --skip-dirs adds more; --include-gitignored /
--include-worktrees / --include-tests turn the defaults off.

Usage: audit.py [path] [--scanners ...] [--severity ...] [--limit N] [--skip-dirs a,b]
                [--include-gitignored] [--include-worktrees] [--include-tests] [--no-version-check]
Writes the Markdown report to stdout. Exit 3 if Trivy is missing, 1 on scan failure.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

SEV_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "UNKNOWN": 4}
TEST_GLOBS = ["**/tests/**", "**/test/**", "**/__tests__/**"]
WORKTREE_GLOBS = ["**/.worktrees/**"]


def by_severity(items):
    return sorted(items, key=lambda x: SEV_ORDER.get(x["sev"].upper(), 9))


def link(text, url):
    return f"[{text}]({url})" if url else text


def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ").strip()


INSTALL_DOCS = "https://trivy.dev/latest/getting-started/installation/"
INSTALL_SCRIPT = ("curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh "
                  "| sudo sh -s -- -b /usr/local/bin")


def trivy_hint(verb):
    if shutil.which("brew"):
        return f"`brew {verb} trivy`"
    if shutil.which("apk"):
        return "`apk add -u trivy`" if verb == "upgrade" else "`apk add trivy`"
    if shutil.which("pacman"):
        return "`pacman -S trivy`"
    if any(shutil.which(p) for p in ("apt-get", "apt", "dnf", "yum")):
        # apt/yum lack trivy without Aqua's repo; the install script is the portable path.
        return f"`{INSTALL_SCRIPT}` (or add Aqua's repo — see {INSTALL_DOCS})"
    return f"see {INSTALL_DOCS}"


def trivy_version():
    try:
        out = subprocess.run(["trivy", "--version"], capture_output=True, text=True).stdout
    except OSError:
        return "?"
    for line in out.splitlines():
        if line.strip().lower().startswith("version:"):
            return line.split(":", 1)[1].strip()
    return "?"


def cache_dir():
    env = os.environ.get("TRIVY_CACHE_DIR")
    if env:
        return Path(env)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "trivy"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "trivy"


def _parse_iso(s):
    # Trivy stamps nanoseconds; Python 3.9's fromisoformat rejects >6 fractional digits.
    return datetime.fromisoformat(re.sub(r"\.\d+", "", s).replace("Z", "+00:00"))


def db_freshness():
    """Return (freshness_line, warning_or_None) from Trivy's DB metadata."""
    try:
        meta = json.loads((cache_dir() / "db" / "metadata.json").read_text(encoding="utf-8"))
        updated = _parse_iso(meta["UpdatedAt"])
        nxt = _parse_iso(meta["NextUpdate"])
    except (OSError, ValueError, KeyError):
        return "vuln DB: age unknown", None
    now = datetime.now(timezone.utc)
    age_h = (now - updated).total_seconds() / 3600
    line = f"vuln DB updated {updated:%Y-%m-%d %H:%M} UTC ({age_h:.0f}h ago)"
    if now > nxt:
        overdue_h = (now - nxt).total_seconds() / 3600
        return line, (f"Trivy's vuln DB is {overdue_h:.0f}h past its refresh window — the update "
                      f"likely failed (offline?). Results may miss recent CVEs; reconnect and re-run.")
    return line, None


def _fetch_latest_trivy():
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/aquasecurity/trivy/releases/latest",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "security-audit"},
        )
        with urllib.request.urlopen(req, timeout=4) as r:
            return (json.load(r).get("tag_name") or "").lstrip("v")
    except Exception:
        return None


def latest_trivy():
    cache = cache_dir() / "security-audit-latest.json"
    try:
        c = json.loads(cache.read_text(encoding="utf-8"))
        if (datetime.now(timezone.utc) - _parse_iso(c["checked"])).total_seconds() < 86400:
            return c.get("latest")
    except (OSError, ValueError, KeyError, TypeError):
        pass
    latest = _fetch_latest_trivy()
    if latest:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(
                json.dumps({"latest": latest, "checked": datetime.now(timezone.utc).isoformat()}),
                encoding="utf-8",
            )
        except OSError:
            pass
        return latest
    try:
        return json.loads(cache.read_text(encoding="utf-8")).get("latest")
    except (OSError, ValueError):
        return None


def _vtuple(s):
    out = []
    for p in re.split(r"[.\-+]", s or ""):
        if not p.isdigit():
            break
        out.append(int(p))
    return tuple(out)


def newer(latest, installed):
    lt, it = _vtuple(latest), _vtuple(installed)
    if lt and it:
        return lt > it
    return bool(latest) and latest != installed


def worktree_skips(path):
    """Relative paths of linked git worktrees nested under `path` (duplicate checkouts)."""
    try:
        out = subprocess.run(["git", "-C", path, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True).stdout
    except OSError:
        return []
    root = Path(path).resolve()
    skips = []
    for line in out.splitlines():
        if line.startswith("worktree "):
            wt = Path(line[9:].strip()).resolve()
            if wt != root and root in wt.parents:
                skips.append(wt.relative_to(root).as_posix())
    return skips


def _repo_paths(root):
    paths = [Path(root)]
    try:
        out = subprocess.run(
            ["git", "-C", root, "submodule", "foreach", "--recursive", "--quiet", "echo $displaypath"],
            capture_output=True, text=True).stdout
    except OSError:
        return paths
    paths += [Path(root) / rel.strip() for rel in out.splitlines() if rel.strip()]
    return paths


def gitignored_skips(root):
    """(dirs, files) git-ignored across the repo and its submodules, relative to root."""
    rootp = Path(root).resolve()
    dirs, files = set(), set()
    for repo in _repo_paths(root):
        try:
            out = subprocess.run(["git", "-C", str(repo), "status", "--ignored", "--porcelain", "-z"],
                                 capture_output=True, text=True).stdout
        except OSError:
            continue
        for entry in out.split("\0"):
            if not entry.startswith("!! "):
                continue
            raw = entry[3:]
            p = (Path(repo) / raw).resolve()
            if p != rootp and rootp not in p.parents:
                continue
            (dirs if raw.endswith("/") else files).add(p.relative_to(rootp).as_posix())
    return sorted(dirs), sorted(files)


def run_trivy(path, scanners, severity, skip_dirs, skip_files):
    subprocess.run(["trivy", "fs", "--download-db-only", path],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cmd = ["trivy", "fs", "--quiet", "--format", "json",
           "--scanners", scanners, "--severity", severity]
    for d in skip_dirs:
        cmd += ["--skip-dirs", d]
    for f in skip_files:
        cmd += ["--skip-files", f]
    cmd.append(path)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if not proc.stdout.strip():
        print(f"trivy scan failed: {proc.stderr.strip()[:400] or 'no output'}", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(proc.stdout)
    except ValueError:
        print("trivy returned unparseable JSON", file=sys.stderr)
        sys.exit(1)


def collect(data):
    vulns, secrets, misconfigs = [], [], []
    for res in data.get("Results") or []:
        target = res.get("Target", "?")
        for v in res.get("Vulnerabilities") or []:
            vulns.append({
                "sev": v.get("Severity", "UNKNOWN"),
                "id": v.get("VulnerabilityID", "?"),
                "url": v.get("PrimaryURL", ""),
                "pkg": v.get("PkgName", "?"),
                "installed": v.get("InstalledVersion", ""),
                "fixed": v.get("FixedVersion", ""),
                "target": target,
            })
        for m in res.get("Misconfigurations") or []:
            misconfigs.append({
                "sev": m.get("Severity", "UNKNOWN"),
                "id": m.get("ID") or m.get("AVDID", "?"),
                "title": m.get("Title", ""),
                "target": target,
            })
        for s in res.get("Secrets") or []:
            secrets.append({
                "sev": s.get("Severity", "UNKNOWN"),
                "rule": s.get("RuleID") or s.get("Category", "?"),
                "title": s.get("Title", ""),
                "target": f"{target}:{s.get('StartLine', '?')}",
            })
    return vulns, secrets, misconfigs


def table(rows, header, make_row, limit):
    ncols = header.count("|") - 1
    out = [header, "|" + "---|" * ncols]
    out += [make_row(r) for r in rows[:limit]]
    if len(rows) > limit:
        cells = [f"_+{len(rows) - limit} more (raise --limit)_"] + [""] * (ncols - 1)
        out.append("| " + " | ".join(cells) + " |")
    return out


def report(path, vulns, secrets, misconfigs, limit, footer, warn):
    total = len(vulns) + len(secrets) + len(misconfigs)
    counts = Counter(x["sev"].upper() for x in vulns + secrets + misconfigs)
    fixable = by_severity([v for v in vulns if v["fixed"]])
    nofix = by_severity([v for v in vulns if not v["fixed"]])

    sev = " · ".join(f"{counts[s]} {s.lower()}" for s in sorted(counts, key=lambda s: SEV_ORDER.get(s, 9)))
    md = [f"# Security audit — `{path}`", ""]
    md.append(f"> **{total} findings** — {sev or 'none'}")
    md.append(">")
    md.append(f"> vulnerabilities: {len(vulns)} ({len(fixable)} fixable) · secrets: {len(secrets)} · misconfig: {len(misconfigs)}")
    md.append(">")
    md.append(f"> _{footer}_")
    md.append("")
    if warn:
        md.append("> [!WARNING]")
        md.append(f"> {warn}")
        md.append("")
    if total == 0:
        md.append("No findings at the requested severities. ✅")
        return "\n".join(md) + "\n"

    if fixable:
        md.append("## Vulnerabilities — fixable")
        md += table(
            fixable,
            "| Sev | Package | Installed | → Fixed | Advisory | Target |",
            lambda v: f"| {v['sev']} | `{cell(v['pkg'])}` | {cell(v['installed'])} | **{cell(v['fixed'])}** | {link(cell(v['id']), v['url'])} | {cell(v['target'])} |",
            limit,
        )
        md.append("")
    if nofix:
        md.append("## Vulnerabilities — no fix available")
        md += table(
            nofix,
            "| Sev | Package | Installed | Advisory | Target |",
            lambda v: f"| {v['sev']} | `{cell(v['pkg'])}` | {cell(v['installed'])} | {link(cell(v['id']), v['url'])} | {cell(v['target'])} |",
            limit,
        )
        md.append("")
    if secrets:
        md.append("## Secrets")
        md += table(
            by_severity(secrets),
            "| Sev | Rule | Location |",
            lambda s: f"| {s['sev']} | {cell(s['rule'])} | {cell(s['target'])} |",
            limit,
        )
        md.append("")
    if misconfigs:
        md.append("## Misconfigurations (IaC)")
        md += table(
            by_severity(misconfigs),
            "| Sev | ID | Issue | Target |",
            lambda m: f"| {m['sev']} | {cell(m['id'])} | {cell(m['title'])} | {cell(m['target'])} |",
            limit,
        )
        md.append("")
    return "\n".join(md).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser(description="Full Trivy security audit → Markdown report.")
    ap.add_argument("path", nargs="?", default=".")
    ap.add_argument("--scanners", default="vuln,secret,misconfig")
    ap.add_argument("--severity", default="CRITICAL,HIGH,MEDIUM")
    ap.add_argument("--limit", type=int, default=100, help="max rows per table")
    ap.add_argument("--skip-dirs", default="", help="extra comma-separated dirs/globs to skip")
    ap.add_argument("--include-gitignored", action="store_true",
                    help="don't auto-skip git-ignored paths")
    ap.add_argument("--include-worktrees", action="store_true",
                    help="don't auto-skip nested git worktrees")
    ap.add_argument("--include-tests", action="store_true",
                    help="don't auto-skip test directories")
    ap.add_argument("--no-version-check", action="store_true",
                    help="skip the (cached, daily) Trivy version check")
    args = ap.parse_args()

    if shutil.which("trivy") is None:
        print(f"trivy not found — install it: {trivy_hint('install')}. Then re-run.", file=sys.stderr)
        sys.exit(3)

    target = str(Path(args.path))
    skip_dirs, skip_files = [], []
    if not args.include_gitignored:
        gdirs, gfiles = gitignored_skips(target)
        skip_dirs += gdirs
        skip_files += gfiles
    if not args.include_worktrees:
        skip_dirs += worktree_skips(target) + WORKTREE_GLOBS
    if not args.include_tests:
        skip_dirs += TEST_GLOBS
    skip_dirs += [s.strip() for s in args.skip_dirs.split(",") if s.strip()]
    skip_dirs = list(dict.fromkeys(skip_dirs))
    skip_files = list(dict.fromkeys(skip_files))
    data = run_trivy(target, args.scanners, args.severity, skip_dirs, skip_files)
    vulns, secrets, misconfigs = collect(data)

    version = trivy_version()
    fresh_line, db_warn = db_freshness()

    latest = None if args.no_version_check else latest_trivy()
    known = version != "?"
    behind = bool(latest) and known and newer(latest, version)
    status = f" (update available → {latest})" if behind else (" (latest)" if latest and known else "")
    notes = (([] if args.include_gitignored else ["gitignored"])
             + ([] if args.include_worktrees else ["worktrees"])
             + ([] if args.include_tests else ["test dirs"]))
    skip_note = f" · skipped {', '.join(notes)}" if notes else ""
    footer = f"scanner: Trivy {version}{status} · {fresh_line}{skip_note}"
    print(report(target, vulns, secrets, misconfigs, args.limit, footer, db_warn))

    if behind:
        print(f"\n> Trivy {version} is behind {latest} — update it: {trivy_hint('upgrade')}.")


if __name__ == "__main__":
    main()
