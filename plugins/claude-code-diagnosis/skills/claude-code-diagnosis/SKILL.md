---
name: claude-code-diagnosis
description: >-
  Diagnose your own Claude Code usage and benchmark it against Anthropic's published per-developer
  figures. Parses local session transcripts (~/.claude/projects) into cost, tokens, sessions, model
  mix, tool distribution, cache efficiency, thinking and subagent rates, per-project and per-week
  breakdowns — then renders an interactive HTML dashboard with a percentile placement (where you sit
  in the population of Claude Code developers). Cost reconciles to within ~1% of ccusage. No network,
  no account access. Use when asked to evaluate Claude Code usage, estimate spend, benchmark against
  other developers, or prepare usage/percentile figures.
---

# Claude Code — Usage Diagnosis

Turn your local Claude Code transcripts into a usage diagnosis: **what you spend, how you work, and
where you sit** versus the average developer — as an interactive HTML dashboard in the same editorial
"blueprint" language as `delivery-metrics`.

## Workflow

### 1. Collect data
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/claude-code-diagnosis/scripts/collect-usage.py" [CLAUDE_DIR] > /tmp/cc-diag-data.json
```
`[CLAUDE_DIR]` is optional — defaults to `$CLAUDE_CONFIG_DIR` or `~/.claude` (the script appends
`/projects`). One pass over every `*.jsonl`, no network. Token/cost are **deduplicated by
`message.id`** (Claude Code writes one transcript line per content block, each replaying the same
`usage`) and replayed lines are dropped by `uuid`; tool calls are counted per `tool_use` block. Cost
is computed locally from token counts at Anthropic list prices (see `assets/benchmarks.json`) and
lands within ~1% of `ccusage` for Claude usage.

### 2. Build HTML
1. Read `${CLAUDE_PLUGIN_ROOT}/skills/claude-code-diagnosis/assets/report-template.html`
2. Read `/tmp/cc-diag-data.json`
3. Inject `<script>window.DATA = <json>;</script>` right before `</head>`
4. Write to `~/claude-code-usage-diagnosis.html` and `open` it.

### 3. Text summary
Concise markdown: headline (cost, cost/active-day, percentile band), model mix, where the tokens go
(top projects), engagement signals (cache hit, thinking %, subagent %, tools/turn), and the
benchmark read with caveats below.

## What it measures

| Metric | How | Read as |
|---|---|---|
| API-equivalent value | tokens × list price, deduped by `message.id` | What the work would cost at API rates |
| Cost / active day | total cost / distinct active days | The figure Anthropic benchmarks against |
| Percentile | lognormal fit of cost/active-day vs the benchmark | Where you sit in the developer population |
| Model mix | cost share per model | Opus-heavy vs Sonnet/Haiku balance |
| Cache hit rate | cache_read / (read + write + input) | Context-reuse efficiency |
| Thinking % | turns with a `thinking` block / turns | Extended-reasoning reliance |
| Subagent % | `isSidechain` turns / turns | Delegated/parallel work |
| Per-project | cost & tokens by `cwd` | Where effort concentrates |
| Weekly series | cost / sessions / tokens per Monday-week | Trend (in-progress week excluded) |

## Benchmark methodology

Anchored on two **officially published** Anthropic figures (`code.claude.com/docs/en/costs`, April 2026):
the average **$13 per developer per active day** and **90% of users below $30/active-day**. The
percentile curve is a **lognormal fitted to those two points** (implied median ≈ $7/active-day), so
mid-range percentiles are modelled, not measured. Constants live in `assets/benchmarks.json` — update
that file (and `retrieved` date) when Anthropic revises its figures; the report reads it at build time.

## Caveats to flag

1. **Cost is an estimate, not a bill** — list prices, computed locally. Subscription (Pro/Max/Team)
   usage is included in the plan; this measures the *API-equivalent value* of the work, not what was charged.
2. **Claude Code only** — scope is `~/.claude/projects`. Other agents (Codex, Gemini CLI) live in their
   own dirs and are out of scope; use `ccusage` for a cross-agent view.
3. **Anthropic publishes distributions only for cost/active-day** — token, session, tool, cache and
   subagent rows show your values with directional context, not a measured percentile.
4. **Local-clone dependent** — only transcripts present on this machine are counted; usage from other
   devices or claude.ai is invisible.
