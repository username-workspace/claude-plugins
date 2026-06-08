---
name: security-audit
description: Run a full Trivy security scan of a project — dependency vulnerabilities across every ecosystem (npm, pip, Go, Cargo, Composer, Maven, RubyGems, NuGet…), plus hard-coded secrets and IaC misconfigurations — and produce an adapted, prioritised Markdown report. Report-only: it surfaces fixed versions but never edits code. Use when the user asks to audit security, scan for vulnerabilities/CVEs, check dependencies, find leaked secrets or IaC misconfigs, or "is this repo vulnerable".
argument-hint: "[path — defaults to the current directory]"
allowed-tools: Bash
---

# Security Audit

## Overview

A language-agnostic security audit powered by Trivy. One full filesystem scan covers dependency
CVEs across **every** ecosystem Trivy detects, hard-coded **secrets**, and **IaC misconfigurations**
(Dockerfile, Terraform, Kubernetes…). The bundled script parses Trivy's JSON and renders a
prioritised Markdown report — fixable vulnerabilities first, with target fix versions.

This is **report-only**: it never modifies code or lockfiles. It tells the user *what* is vulnerable
and *to which version* to upgrade; applying the fix is their call.

## Workflow

### 1. Run the audit

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/security-audit/scripts/audit.py" [path] \
  [--scanners vuln,secret,misconfig] [--severity CRITICAL,HIGH,MEDIUM] [--limit 100] \
  [--format md|html|both] [--out security-audit.html]
```

- `path` defaults to the current directory; pass a repo root or subdirectory.
- **Output**: `--format md` (default) prints Markdown to stdout (terminal/agent-friendly). `--format
  html` writes a self-contained **dark dashboard** (Username design system, like delivery-metrics) to
  `--out`; `both` does Markdown to stdout **and** the HTML file. For a human-readable / shareable
  review, prefer `both`, then `open` the HTML.
- Defaults scan vulns + secrets + misconfig at CRITICAL/HIGH/MEDIUM. Narrow with `--severity`
  (e.g. `CRITICAL,HIGH`) on noisy repos, or scope with `--scanners` (e.g. `vuln` only).
- **The scan reflects the repo, not local junk.** By default it honours `.gitignore` (across
  submodules) — so `node_modules`, `.pnpm-store`, `vendor`, `.env.local`, build output etc. are out
  of scope — and also skips nested git worktrees (duplicate checkouts) and test dirs
  (`tests`/`test`/`__tests__`, not prod-shipped). The footer notes what was dropped. Add more with
  `--skip-dirs`; restore any with `--include-gitignored` / `--include-worktrees` / `--include-tests`.
- Only external dependency is **Trivy**; the script parses its JSON with the stdlib (no jq).
- The report footer shows the Trivy version (validated against the latest release on every run,
  cached for 24h) and the vuln-DB freshness; `--no-version-check` skips the version check (offline/CI).

Markdown goes to stdout; the HTML dashboard (when requested) is written to `--out`.

### 2. Report

Relay the report. Lead with the summary line (counts by severity, fixable count) and the
**fixable critical/high** rows — those are the actionable wins. Then secrets (treat any as urgent)
and misconfigurations. Offer to save the report to a file if the user wants to share it.

Be honest about scope: "no fix available" vulnerabilities still matter (they need a workaround,
a different package, or risk acceptance) — don't bury them.

## Staying current

- **Vulnerability DB** — Trivy auto-refreshes it on a daily cycle; the script triggers that refresh
  before every scan and prints the DB's age in the footer. If the DB is stale and the refresh failed
  (offline), the report carries a `[!WARNING]` that results may miss recent CVEs. DB updates are
  never disabled.
- **Trivy binary** — kept current by your package manager. The skill never upgrades a system binary,
  but **every run validates the installed version** against the latest release (cached 24h, fail-open
  offline) — the footer shows `(latest)` or `(update available → x.y.z)`. It **detects your package
  manager** and nudges with the matching command:
  `brew upgrade trivy` (macOS), `apk add -u trivy` (Alpine), `pacman -S trivy` (Arch), or the official
  install script for apt/yum/dnf (Debian/Ubuntu/RHEL & WSL), since Trivy needs Aqua's repo there
  ([trivy.dev/.../installation](https://trivy.dev/latest/getting-started/installation/)).

## Halt conditions

- Trivy not installed → the script exits with an install hint matched to your package manager
  (brew / apk / pacman, else the install script for apt/yum via trivy.dev); relay it and stop.
- Scan error → the script reports Trivy's stderr; relay and stop.

## Anti-patterns

- Do **not** dump raw Trivy JSON — the script's curated report is the output.
- Do **not** edit code or bump dependencies — this skill audits and reports only.
- Do **not** present only the fixable rows — flag secrets and "no fix available" findings too.
