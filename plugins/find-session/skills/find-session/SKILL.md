---
name: find-session
description: Find and resume a past Claude Code session from a search term (keyword, file name, topic, or ticket). Decomposes the query into concept terms, cross-matches them against the local ~/.claude/projects transcripts, ranks candidates by mentions and recency (with density and the dominant key as signals), and returns the best session ID with a ready `claude --resume <id>` command. Use when the user wants to reopen earlier work — "which session did we work on X", "find the session about Y", "retrouve la session où on a fait Z", "resume the conversation about", "what session touched <file>".
argument-hint: <search term — keyword, file name, topic, or ticket>
allowed-tools: Bash
---

# Find Session

## Overview

Locate the ID of a past Claude Code session from a search term, ranked by relevance, and hand back a
ready-to-run `claude --resume <id>`. It reads the user's **local** `~/.claude/projects/*/*.jsonl`
transcripts — so it only makes sense in interactive Claude Code on the developer's machine. If you
are running non-interactively (no local transcript history, no terminal to resume into), say session
lookup is interactive-only and stop.

The mechanical work (directory resolution, cross-matching, ranking) is in the bundled script. Your
job is the part it cannot do: turning a natural-language request into good concept terms.

## Workflow

### 1. Decompose the query into concepts

`$ARGUMENTS` is usually a sentence, not a clean term. Do **not** search it literally — a literal
match almost always returns nothing. Extract:

- **1–3 concept terms**, each as a case-insensitive regex alternation covering obvious variants:
  - `flaky tests` → `flaky` (reduce a phrase to its key term)
  - `rate limiting` → `rate.?limit` (cover hyphen / spacing / spelling variants)
  - `OAuth / SSO login` → `oauth|sso|single.?sign.?on` (cover synonyms and acronyms)
  - a file → its basename, e.g. `use-auth`
- **Time filter** (optional) — "recent", "last 2 weeks", "yesterday", "this month" → an ISO cutoff
  date relative to today, passed as `--since YYYY-MM-DD`. Add `--recent` to sort by recency first.

Each concept is one positional argument; the script requires **all** of them to appear in a file.
Two well-chosen concepts beat one. If `$ARGUMENTS` is empty, ask once what to look for.

### 2. Run the search

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/find-session/scripts/find_session.py" \
  '<concept1>' '<concept2>' [--since YYYY-MM-DD] [--recent] [--all]
```

- Defaults to the **current project's** transcripts; auto-widens to all projects if that directory
  is absent or empty. Pass `--all` to force an all-projects search (the project is shown per result).
- Override the transcripts root with `CLAUDE_PROJECTS_DIR` if needed.

### 3. Report the result

Relay the best match and its `claude --resume <id>` command, then the secondary candidates. Read the
signals before declaring a winner:

- **mentions** — primary relevance.
- **density** (per 1k lines) — a short, very dense file is usually a report or summary that *lists*
  the topic, not a work session; flag it rather than crowning it.
- **key** — a single dominant ticket-style key (e.g. `ABC-1234 (x40)`) confirms a focused work
  session; a flat spread suggests a report.

Say so explicitly when the top hit is weak (1–2 mentions), is a report, or when the result is not
clear-cut. Only list IDs the script actually returned — never invent one.

## Halt conditions

- No transcripts root → the script reports it; relay and stop.
- No cross-match → retry once with relaxed concepts (drop the least essential, or loosen `--since`);
  if still nothing, report it.
- `$ARGUMENTS` empty after one clarification → stop.

## Anti-patterns

- Do **not** grep the raw sentence — decompose into concepts first.
- Do **not** rank on mentions alone — weigh density and the dominant key so a report is not mistaken
  for a work session.
- Do **not** read whole transcripts — the script's counting pass is enough.
