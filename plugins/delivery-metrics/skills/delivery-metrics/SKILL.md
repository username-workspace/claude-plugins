---
name: delivery-metrics
description: >-
  Generate a developer productivity + quality report from git history — for a single repo or a
  workspace of submodules. Produces an interactive HTML dashboard tracking tickets delivered,
  velocity (tickets / available workday), fix-ratio, reverts, WIP vs delivered, utilization, and
  per-repo specialization, with weekly time series (the in-progress week is excluded). Repo-agnostic and configurable (ticket
  pattern, holidays, leaves, author aliases). Use when asked about developer productivity, team
  velocity, delivery metrics, engineering throughput, or performance-review data. Optional period:
  1m, 3m (default), 6m, 12m, 24m.
---

# Developer Productivity + Quality Report

Analyze git history (one repo or a submodule workspace) and produce an interactive HTML dashboard.
Tracks **delivered output adjusted for availability** plus **quality signals**, not raw commit counts.

## Workflow

### 1. Parse period (how far back)
From the request/argument: no arg → **3 months** (default); `1m`, `3m`, `6m`, `12m`, `24m`. Compute
`SINCE` (first day of the start month) and `UNTIL` (first day of next month). Buckets are **weekly
(Monday-based)**; the script **excludes the in-progress week** via the machine clock — on Mon–Fri the
running week is dropped, on Sat/Sun the finished work week is kept. Pass the label as `<PERIOD>`.

### 2. Collect data
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/delivery-metrics/scripts/collect-metrics.py" <ROOT> <SINCE> <UNTIL> <PERIOD> [config.json] > /tmp/delivery-metrics-data.json
```
`<ROOT>` is the repo or workspace root. Config is optional (also auto-loaded from
`<ROOT>/.delivery-metrics.json`). The script runs **one `git log --all` per repo**, splits
*delivered* (on the default branch) from *WIP* (on branches, by SHA and by subject to survive
rebases/cherry-picks), aggregates per dev + per **week**, clamps the window to the last complete week,
and computes available workdays from the calendar minus configured holidays and leaves. No network,
no external services.

### 3. Build HTML
1. Read `${CLAUDE_PLUGIN_ROOT}/skills/delivery-metrics/assets/report-template.html`
2. Read `/tmp/delivery-metrics-data.json`
3. Inject `<script>window.DATA = <json>;</script>` right before `</head>`
4. Write to `/tmp/delivery-metrics-<root>-<timestamp>.html` and `open` it — where `<root>` is the
   basename of `<ROOT>` (the analyzed repo/workspace) and `<timestamp>` is `date +%Y%m%d-%H%M%S`, so
   runs on different repos don't overwrite each other.

### 4. Text summary
Concise markdown: top KPIs (tickets delivered, mean velocity, best fix-ratio); ranking by velocity
(tickets / available day, adjusted for leaves); quality flags (fix-ratio > 40%, many reverts,
WIP > delivered, recurring big commits); per-repo breakdown; week-over-week trend; caveats below.

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
  "leaves": [ { "author": "Jane Doe", "start": "2026-05-01", "end": "2026-05-05", "fraction": 1.0 } ],
  "availability_command": "python3 hr-availability.py"  // optional provider
}
```
Without config: auto-detects submodules (or treats `<ROOT>` as one repo), generic ticket pattern,
no holidays/leaves (available days = weekdays — the report then hides the leave column). Set
`fraction` to `0.5` for half-day leaves.

**Availability provider (`availability_command`)** — for live leave/holiday data, point this at any
command that prints `{"holidays":[...iso...], "leaves":[{"author","start","end","fraction"}...]}` on
stdout. It runs in `<ROOT>` with `DM_SINCE`/`DM_UNTIL` in the environment, and its output is merged
into `holidays`/`leaves`. 🔒 Because it is a shell command, it is honored **only from an explicitly
passed config file** — in the auto-loaded `<ROOT>/.delivery-metrics.json` it is ignored (a file
arriving with a clone must not execute code). This keeps the skill generic: an org plugs its own HR source (e.g. a
TimeOff/Workday/calendar fetcher) opaquely, without that integration living in the skill.

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
