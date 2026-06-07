---
name: delivery-metrics
description: >-
  Generate a developer productivity + quality report from git history — for a single repo or a
  workspace of submodules. Produces an interactive HTML dashboard tracking tickets delivered,
  velocity (tickets / available workday), fix-ratio, reverts, WIP vs delivered, utilization, and
  per-repo specialization, with monthly time series. Repo-agnostic and configurable (ticket
  pattern, holidays, leaves, author aliases). Use when asked about developer productivity, team
  velocity, delivery metrics, engineering throughput, or performance-review data. Optional period:
  1m, 3m (default), 6m, 12m, 24m.
---

# Developer Productivity + Quality Report

Analyze git history (one repo or a submodule workspace) and produce an interactive HTML dashboard.
Tracks **delivered output adjusted for availability** plus **quality signals**, not raw commit counts.

## Workflow

### 1. Parse period
From the request/argument: no arg → **3 months** (default; single-month trends aren't meaningful);
`1m` (charts fall back to bars), `3m`, `6m`, `12m`, `24m`. Compute `SINCE` (first day of start
month), `UNTIL` (first day of current month + 1), `MONTHS` count.

### 2. Collect data
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/delivery-metrics/scripts/collect-metrics.py" <ROOT> <SINCE> <UNTIL> <MONTHS> [config.json] > /tmp/delivery-metrics-data.json
```
`<ROOT>` is the repo or workspace root. Config is optional (also auto-loaded from
`<ROOT>/.delivery-metrics.json`). The script runs **one `git log --all` per repo**, splits
*delivered* (on the default branch) from *WIP* (on branches, by SHA and by subject to survive
rebases/cherry-picks), aggregates per dev + per month, and computes available workdays from the
calendar minus configured holidays and leaves. No network, no external services.

### 3. Build HTML
1. Read `${CLAUDE_PLUGIN_ROOT}/skills/delivery-metrics/assets/report-template.html`
2. Read `/tmp/delivery-metrics-data.json`
3. Inject `<script>window.DATA = <json>;</script>` right before `</head>`
4. Write to `<ROOT>/.delivery-metrics-report.html` and `open` it.

### 4. Text summary
Concise markdown: top KPIs (tickets delivered, mean velocity, best fix-ratio); ranking by velocity
(tickets / available day, adjusted for leaves); quality flags (fix-ratio > 40%, many reverts,
WIP > delivered, recurring big commits); per-repo breakdown; month-over-month trend; caveats below.

## Configuration (optional — all fields have defaults)

```jsonc
{
  "repos": ["."],                 // relative paths; default: auto-detect submodules, else ["."]
  "ticket_pattern": "\\b([A-Z][A-Z0-9]+-\\d+)\\b",   // default: JIRA-style KEY-123
  "fix_pattern": "\\b(fix|hotfix|bugfix)\\b",
  "big_commit_lines": 500, "tiny_commit_lines": 5, "noise_floor": 5,
  "author_aliases": { "Jane": "Jane Doe" },
  "exclude": ["CI Bot"],          // hidden from charts (kept in raw developers)
  "holidays": ["2026-01-01"],     // ISO dates removed from working days
  "leaves": [ { "author": "Jane Doe", "start": "2026-05-01", "end": "2026-05-05", "fraction": 1.0 } ]
}
```
Without config: auto-detects submodules (or treats `<ROOT>` as one repo), generic ticket pattern,
no holidays/leaves (available days = weekdays). Set `fraction` to `0.5` for half-day leaves.

## Key metrics

| Metric | Formula | Read as |
|---|---|---|
| Tickets delivered | unique ticket keys on default branch | Output shipped |
| Velocity | tickets / available workdays | Headline efficiency, normalized for leaves |
| Available days | weekdays − holidays − leaves | What they could have worked |
| Utilization | active days / available days | Regularity |
| Fix ratio | fix commits / default-branch commits | Proxy for rework |
| Reverts | commits whose subject starts with `Revert` | Code that didn't survive |
| In progress | tickets on any branch with **zero** commits on default | Open, unshipped (robust to rebases) |
| Lines/commit | (ins + del) / commits | Reviewability |
| Main repo | most-touched repo | Specialization |

## Caveats to flag

1. **Git ≠ quality** — review, time-to-approve, oncall, mentoring, debug-only sessions are invisible.
2. **Specialization bias** — different stacks have different commit cadences; don't compare velocity blindly.
3. **In progress** depends on the local clone's branch state (old undeleted branches inflate it); it's
   ticket-level (dedupes rebase/cherry-pick noise) but local-clone dependent.
4. **Availability** is only as accurate as the configured holidays/leaves; without them it's weekdays only.
