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

Usage: audit.py [path ...] [--scanners ...] [--severity ...] [--limit N] [--skip-dirs a,b]
                [--include-gitignored] [--include-worktrees] [--include-tests] [--no-version-check]
Writes the Markdown report to stdout. Exit 3 if Trivy is missing, 1 on scan failure.
"""

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from collections import Counter, defaultdict
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
    vulns, secrets, misconfigs, dep_targets = [], [], [], set()
    for res in data.get("Results") or []:
        target = res.get("Target", "?")
        if res.get("Class") == "lang-pkgs":
            dep_targets.add(target)
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
    return vulns, secrets, misconfigs, dep_targets


def classify_vulns(vulns, dep_targets):
    """Tag each vuln primary (prod) vs secondary. A lockfile nested under another lockfile of the
    same kind is a bundled sub-project / tooling (e.g. Magento's update/ updater) — not the prod
    dependency set — so its vulns are separated out. Tool-agnostic: works for any ecosystem."""
    def parts(t):
        return (t.rsplit("/", 1)[0] if "/" in t else "", t.rsplit("/", 1)[-1])
    dirs_by_lockfile = defaultdict(set)
    for t in dep_targets:
        d, base = parts(t)
        dirs_by_lockfile[base].add(d)
    for v in vulns:
        d, base = parts(v["target"])
        v["primary"] = not any(
            od != d and (od == "" or d.startswith(od + "/")) for od in dirs_by_lockfile[base]
        )


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
    fixable = by_severity([v for v in vulns if v["fixed"] and v.get("primary", True)])
    nofix = by_severity([v for v in vulns if not v["fixed"] and v.get("primary", True)])
    nested = by_severity([v for v in vulns if not v.get("primary", True)])

    sev = " · ".join(f"{counts[s]} {s.lower()}" for s in sorted(counts, key=lambda s: SEV_ORDER.get(s, 9)))
    nested_note = f" · {len(nested)} in nested sub-projects" if nested else ""
    md = [f"# Security audit — `{path}`", ""]
    md.append(f"> **{total} findings** — {sev or 'none'}")
    md.append(">")
    md.append(f"> vulnerabilities: {len(vulns) - len(nested)} prod ({len(fixable)} fixable){nested_note} · secrets: {len(secrets)} · misconfig: {len(misconfigs)}")
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
    if nested:
        md.append("## Vulnerabilities — nested sub-projects (likely tooling, not shipped to prod — verify)")
        md += table(
            nested,
            "| Sev | Package | Installed | → Fixed | Advisory | Target |",
            lambda v: f"| {v['sev']} | `{cell(v['pkg'])}` | {cell(v['installed'])} | {cell(v['fixed']) or '—'} | {link(cell(v['id']), v['url'])} | {cell(v['target'])} |",
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


SEV_CLASS = {"CRITICAL": "crit", "HIGH": "high", "MEDIUM": "med", "LOW": "low", "UNKNOWN": "unk"}

HTML_CSS = """
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@500;600&family=Newsreader:ital,opsz,wght@0,6..72,400..600;1,6..72,400..500&display=swap');
:root{--dark:#0c0d10;--on-dark:#fafafa;--stamp:#a8231f;--blueprint:#3d5a7f;--ink-faint:#8f8c86;--hairline:rgba(255,255,255,.14);--hairline-faint:rgba(255,255,255,.07);--surface:rgba(255,255,255,.025);--fd:'Newsreader',Georgia,serif;--fb:'Inter',system-ui,sans-serif;--fm:'JetBrains Mono',ui-monospace,Menlo,monospace;--bp:rgba(255,255,255,.04)}
*{margin:0;padding:0;box-sizing:border-box}
html{-webkit-font-smoothing:antialiased}
body{font-family:var(--fb);color:var(--on-dark);padding:48px 40px;min-height:100vh;background:radial-gradient(900px 520px at 88% -8%,rgba(168,35,31,.16),transparent 60%),radial-gradient(800px 520px at -5% 4%,rgba(61,90,127,.18),transparent 55%),linear-gradient(var(--bp) 1px,transparent 1px) 0 0/40px 40px,linear-gradient(90deg,var(--bp) 1px,transparent 1px) 0 0/40px 40px,var(--dark)}
.wrap{max-width:1180px;margin:0 auto}
.eyebrow{font-family:var(--fm);font-size:.72rem;font-weight:600;letter-spacing:.18em;text-transform:uppercase;color:var(--ink-faint);display:inline-flex;align-items:center;gap:10px}
.eyebrow::before{content:'';width:22px;height:2px;background:var(--stamp);display:inline-block}
h1{font-family:var(--fd);font-weight:500;font-size:2.4rem;line-height:1.05;letter-spacing:-.025em;margin:14px 0 6px}
h1 em{font-style:italic;color:var(--stamp);font-weight:600}
.subtitle{font-family:var(--fm);color:var(--ink-faint);font-size:.7rem;letter-spacing:.03em;margin-bottom:32px;word-break:break-all}
.warn{font-family:var(--fm);font-size:.72rem;color:#d2a36a;border:1px solid rgba(154,123,74,.5);background:rgba(154,123,74,.1);padding:12px 16px;margin-bottom:28px}
.kpi-strip{display:flex;flex-wrap:wrap;border-top:1px solid var(--hairline);border-bottom:1px solid var(--hairline);padding:22px 0;margin-bottom:40px}
.kpi{padding:2px 26px;border-left:1px solid var(--hairline-faint);flex:1;min-width:115px}
.kpi:first-child{padding-left:0;border-left:none}
.kpi .value{font-family:var(--fd);font-weight:600;font-size:2.1rem;line-height:1}
.kpi.lead .value{color:var(--stamp)}
.kpi .label{font-family:var(--fm);font-size:.58rem;font-weight:500;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-faint);margin-top:11px}
section{margin-bottom:32px}
section h2{font-family:var(--fm);font-weight:600;color:var(--ink-faint);text-transform:uppercase;letter-spacing:.12em;font-size:.68rem;margin-bottom:14px}
table{width:100%;border-collapse:collapse;font-size:.82rem}
th{text-align:left;padding:10px 12px;border-bottom:1px solid var(--hairline);color:var(--ink-faint);font-family:var(--fm);font-weight:500;font-size:.58rem;text-transform:uppercase;letter-spacing:.1em}
td{padding:10px 12px;border-bottom:1px solid var(--hairline-faint);font-family:var(--fm);font-variant-numeric:tabular-nums;vertical-align:top;word-break:break-word}
tr:last-child td{border-bottom:none}
td a{color:var(--blueprint);text-decoration:none}td a:hover{text-decoration:underline}
.fix{color:#8fbf9f}
.sev{font-family:var(--fm);font-size:.56rem;font-weight:600;letter-spacing:.06em;padding:3px 7px;border:1px solid;text-transform:uppercase;white-space:nowrap}
.sev.crit{color:#e5827f;border-color:rgba(168,35,31,.6);background:rgba(168,35,31,.14)}
.sev.high{color:#d2a36a;border-color:rgba(154,123,74,.5);background:rgba(154,123,74,.12)}
.sev.med{color:#8fa9c9;border-color:rgba(61,90,127,.55);background:rgba(61,90,127,.12)}
.sev.low,.sev.unk{color:var(--ink-faint);border-color:var(--hairline)}
.empty{font-family:var(--fb);color:var(--ink-faint);font-size:1.1rem;padding:32px 0}
footer{font-family:var(--fm);font-size:.62rem;color:var(--ink-faint);margin-top:40px;border-top:1px solid var(--hairline-faint);padding-top:16px}
"""


def _badge(sev):
    return f'<span class="sev {SEV_CLASS.get(sev.upper(), "unk")}">{html.escape(sev)}</span>'


def _table(headers, rows):
    th = "".join(f"<th>{html.escape(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table>"


def report_html(path, vulns, secrets, misconfigs, footer, warn):
    e = html.escape
    counts = Counter(x["sev"].upper() for x in vulns + secrets + misconfigs)
    fixable = by_severity([v for v in vulns if v["fixed"] and v.get("primary", True)])
    nofix = by_severity([v for v in vulns if not v["fixed"] and v.get("primary", True)])
    nested = by_severity([v for v in vulns if not v.get("primary", True)])
    total = len(vulns) + len(secrets) + len(misconfigs)
    prod_vulns = len(vulns) - len(nested)

    def adv(v):
        return f'<a href="{e(v["url"])}">{e(v["id"])}</a>' if v["url"] else e(v["id"])

    kpis = [("findings", total, True), ("critical", counts.get("CRITICAL", 0), False),
            ("high", counts.get("HIGH", 0), False), ("medium", counts.get("MEDIUM", 0), False),
            ("vulns fixable", f"{len(fixable)}/{prod_vulns}", False),
            ("secrets", len(secrets), False), ("misconfig", len(misconfigs), False)]
    if nested:
        kpis.append(("nested (tooling)", len(nested), False))
    kpi_html = "".join(
        f'<div class="kpi{" lead" if lead else ""}"><div class="value">{v}</div>'
        f'<div class="label">{e(l)}</div></div>' for l, v, lead in kpis)

    sections = []
    if fixable:
        rows = [[_badge(v["sev"]), f'<code>{e(v["pkg"])}</code>', e(v["installed"]),
                 f'<span class="fix">{e(v["fixed"])}</span>', adv(v), e(v["target"])] for v in fixable]
        sections.append(("Vulnerabilities — fixable",
                         _table(["Sev", "Package", "Installed", "→ Fixed", "Advisory", "Target"], rows)))
    if nofix:
        rows = [[_badge(v["sev"]), f'<code>{e(v["pkg"])}</code>', e(v["installed"]), adv(v), e(v["target"])] for v in nofix]
        sections.append(("Vulnerabilities — no fix available",
                         _table(["Sev", "Package", "Installed", "Advisory", "Target"], rows)))
    if nested:
        rows = [[_badge(v["sev"]), f'<code>{e(v["pkg"])}</code>', e(v["installed"]),
                 f'<span class="fix">{e(v["fixed"])}</span>' if v["fixed"] else "—", adv(v), e(v["target"])] for v in nested]
        sections.append(("Vulnerabilities — nested sub-projects (likely tooling, not shipped to prod — verify)",
                         _table(["Sev", "Package", "Installed", "→ Fixed", "Advisory", "Target"], rows)))
    if secrets:
        rows = [[_badge(s["sev"]), e(s["rule"]), e(s["target"])] for s in by_severity(secrets)]
        sections.append(("Secrets", _table(["Sev", "Rule", "Location"], rows)))
    if misconfigs:
        rows = [[_badge(m["sev"]), e(m["id"]), e(m["title"]), e(m["target"])] for m in by_severity(misconfigs)]
        sections.append(("Misconfigurations (IaC)", _table(["Sev", "ID", "Issue", "Target"], rows)))

    body = "".join(f"<section><h2>{e(t)}</h2>{tbl}</section>" for t, tbl in sections)
    if not body:
        body = '<p class="empty">No findings at the requested severities. ✅</p>'
    warn_html = f'<div class="warn">⚠ {e(warn)}</div>' if warn else ""

    return (
        '<!DOCTYPE html>\n<html lang="en"><head><meta charset="UTF-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>Security audit — {e(path)}</title><style>{HTML_CSS}</style></head>\n"
        '<body><div class="wrap">'
        '<div class="eyebrow">Security audit</div>'
        f"<h1><em>{total}</em> findings</h1>"
        f'<div class="subtitle">{e(path)} · {e(footer)}</div>'
        f"{warn_html}"
        f'<div class="kpi-strip">{kpi_html}</div>'
        f"{body}"
        "<footer>Generated by security-audit (Trivy) · report-only</footer>"
        "</div></body></html>\n"
    )


def main():
    ap = argparse.ArgumentParser(description="Full Trivy security audit → Markdown report.")
    ap.add_argument("paths", nargs="*", default=["."], metavar="path",
                    help="one or more dirs to scan (default: cwd); each scanned recursively")
    ap.add_argument("--scanners", default="vuln,secret,misconfig")
    ap.add_argument("--severity", default="CRITICAL,HIGH,MEDIUM")
    ap.add_argument("--limit", type=int, default=100, help="max rows per table")
    ap.add_argument("--format", choices=["md", "html", "both"], default="md",
                    help="md (stdout), html (dark dashboard file), or both")
    ap.add_argument("--out", default=None,
                    help="HTML output path (default: /tmp/security-audit-<root>-<timestamp>.html)")
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

    paths = args.paths or ["."]
    multi = len(paths) > 1
    all_vulns, all_secrets, all_misconfigs = [], [], []
    for p in paths:
        target = str(Path(p))
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
        vulns, secrets, misconfigs, dep_targets = collect(data)
        classify_vulns(vulns, dep_targets)
        if multi:
            label = Path(target).resolve().name if target == "." else target
            for it in vulns + secrets + misconfigs:
                if it.get("target") and it["target"] != "?":
                    it["target"] = f"{label}/{it['target']}"
        all_vulns += vulns
        all_secrets += secrets
        all_misconfigs += misconfigs
    vulns, secrets, misconfigs = all_vulns, all_secrets, all_misconfigs
    target = str(Path(paths[0])) if not multi else ", ".join(str(Path(p)) for p in paths)

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

    if args.format in ("md", "both"):
        print(report(target, vulns, secrets, misconfigs, args.limit, footer, db_warn))
        if behind:
            print(f"\n> Trivy {version} is behind {latest} — update it: {trivy_hint('upgrade')}.")
    if args.format in ("html", "both"):
        if args.out:
            out = Path(args.out)
        else:
            root = Path(paths[0]).resolve().name if not multi else "multi"
            out = Path(f"/tmp/security-audit-{root or 'root'}-{datetime.now():%Y%m%d-%H%M%S}.html")
        out.write_text(report_html(target, vulns, secrets, misconfigs, footer, db_warn), encoding="utf-8")
        print(f"HTML report → {out.resolve()}", file=sys.stderr if args.format == "both" else sys.stdout)


if __name__ == "__main__":
    main()
