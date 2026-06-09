---
name: coding-agent-usage
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
python3 "${CLAUDE_PLUGIN_ROOT}/skills/coding-agent-usage/scripts/collect-usage.py" [CLAUDE_DIR] > /tmp/cc-diag-data.json
```
`[CLAUDE_DIR]` is optional — defaults to `$CLAUDE_CONFIG_DIR` or `~/.claude` (the script appends
`/projects`). One pass over every `*.jsonl`, no network. Token/cost are **deduplicated by
`message.id`** (Claude Code writes one transcript line per content block, each replaying the same
`usage`) and replayed lines are dropped by `uuid`; tool calls are counted per `tool_use` block. Cost
is computed locally from token counts at Anthropic list prices (see `assets/benchmarks.json`) and
lands within ~1% of `ccusage` for Claude usage.

### 2. Build HTML
1. Read `${CLAUDE_PLUGIN_ROOT}/skills/coding-agent-usage/assets/report-template.html`
2. Read `/tmp/cc-diag-data.json`
3. Inject `<script>window.DATA = <json>;</script>` right before `</head>`
4. Write to `/tmp/coding-agent-usage.html` and `open` it.

### 3. Text summary
Concise markdown: headline (cost, cost/active-day, percentile band), model mix, where the tokens go
(top projects), engagement signals (cache hit, thinking %, subagent %, tools/turn), and the
benchmark read with caveats below.

## Multi-provider mode (optional)

For a cross-agent view (Claude Code **+** Codex, Gemini CLI, …), use `ccusage` as the authoritative
per-token source instead of re-parsing each agent's directory:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/coding-agent-usage/scripts/collect-multiprovider.py" [ccusage-daily.json] > /tmp/cc-multi-data.json
```
With no argument it runs `npx ccusage@latest daily --json`; pass a pre-saved ccusage JSON to skip the
network call. It attributes every `modelBreakdown` to a provider (Anthropic / OpenAI / Google / Other)
by model name and emits per-provider cost, token and monthly-trend series. Build with
`assets/report-multiprovider-template.html` (inject as `window.MDATA`, write to
`/tmp/coding-agent-usage-multiprovider.html`). Answers "what's my total AI-coding spend and how is it split
across providers" — the Claude-only diagnosis stays the primary, deeper view.

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

Anchored on two **officially published** Anthropic figures (`code.claude.com/docs/en/costs`): the
average **$13 per developer per active day** and **90% of users below $30/active-day**. `scripts/benchmark.py`
**fetches these live on every run** (stdlib `urllib`, no API key) and **caches them for 24h** in
`~/.cache/coding-agent-usage/benchmark.json`; on a network failure it falls back to the stale cache,
then to the committed seed in `assets/benchmarks.json` — so the skill never blocks. From the two anchors
it **fits a lognormal** (`fit_lognormal`, implied median ≈ $6/active-day) and recomputes μ/σ whenever
Anthropic changes the numbers, so mid-range percentiles are modelled, not measured. The fetched figures,
source URL and origin (`live`/`cached`/`seed`) are surfaced in the report's hero citation. `benchmarks.json`
remains the seed and holds the (separately-sourced) pricing table.

## Caveats to flag

1. **Cost is an estimate, not a bill** — list prices, computed locally. Subscription (Pro/Max/Team)
   usage is included in the plan; this measures the *API-equivalent value* of the work, not what was charged.
2. **Claude Code only** — scope is `~/.claude/projects`. Other agents (Codex, Gemini CLI) live in their
   own dirs and are out of scope; use `ccusage` for a cross-agent view.
3. **Anthropic publishes distributions only for cost/active-day** — token, session, tool, cache and
   subagent rows show your values with directional context, not a measured percentile.
4. **Local-clone dependent** — only transcripts present on this machine are counted; usage from other
   devices or claude.ai is invisible.
