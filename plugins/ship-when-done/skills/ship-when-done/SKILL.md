---
name: ship-when-done
description: >-
  A Stop-hook harness that commits at each milestone, pushes the feature branch to keep work safe
  (mandatory when a remote exists), and opens a draft PR/MR once the work is *provably* done — the
  checklist derived from the initiating goal is satisfied AND the project's quality gate is actually
  green. Forge-agnostic (GitHub, GitLab, Bitbucket): uses gh/glab if present, else GitLab push
  options, else surfaces the PR-creation URL — no CLI dependency. Branch-first; never commits or
  pushes the default branch; never merges; no AI attribution. Opt-in per repo. Use when you want the
  agent to commit/push/open-PR on its own instead of being asked each time. Horizontal: any repo with
  a remote and a detectable gate.
---

# ship-when-done

Turns "did you commit / push / open the MR?" from a thing the human keeps asking into a thing the
agent does — gated on **real signals**, not the model's self-confidence.

## How it fires

It registers a **`Stop` hook** (end of an agent turn — `hooks/hooks.json` → `hooks/stop-hook.py` →
`scripts/ship.py engage`). It is **opt-in per repo**: it stays completely silent unless the repo has a
`.ship-when-done.json` file **or** `SHIP_WHEN_DONE=1` is set — it never auto-mutates a random repo.
When engaged, it acts only if there is work in flight (uncommitted changes or unshipped commits).

## The autonomy ladder

| Trigger | Action |
|---|---|
| Work changed this turn | **commit** on a feature branch (Conventional / `[TICKET-123]` message) |
| A remote exists | **push** the feature branch — *mandatory* (anti-loss) |
| Verdict `done` **and** the gate is **green** | open a **draft PR/MR** (`on_done`: `draft-pr`\|`ready-pr`\|`suggest`) |

The PR step is the only one gated on "done". Push is mandatory whenever a remote exists.

## Forge support (no CLI required)

The forge is detected from the remote URL (overridable via `forge`), and the PR/MR is opened by the
best available path — so the skill works whether or not a CLI is installed:

| Case | How the PR/MR is opened |
|---|---|
| `gh` (GitHub) or `glab` (GitLab) on `PATH` | the CLI opens the draft PR/MR |
| GitLab, no `glab` | the **push carries it**: `git push -o merge_request.create …` (title + target) |
| Anything else (Bitbucket, self-hosted, no CLI) | the **PR-creation URL is surfaced** for one-click open |

`suggest` mode never auto-opens — it always just surfaces the URL.

## Deciding when it's done

The completion check makes **no extra model call**. `done` requires **either**:

1. **The live agent's `mark-done`** — when the agent believes the task is complete and verified, it runs
   `ship.py mark-done --summary "…"`, dropping a marker in `.git/` (never committed). **Agent: do this
   when you finish & verify a task in an opted-in repo, so the Stop hook can escalate to a PR.**
2. **All todos complete** — `TodoWrite` was used and every item is `completed`.

…and is **always cross-checked**: the gate must actually run **green** and no fresh `TODO/FIXME` may
have landed. Without an explicit signal it still commits & pushes (anti-loss) but opens no PR. When
unsure → **not done**. The marker is consumed once a PR opens.

To plug an independent judge, set `judge_command` (your own command) — off by default; it can only
*downgrade* `done`.

## Guardrails (never crossed)

- **Branch-first** — if on the default branch with changes, it creates a feature branch first; it
  never commits or pushes the default branch.
- **Never merges** — there is no merge path in the code; the PR is opened (draft), the human merges.
- **No AI attribution** in commit messages.
- **`wip/` escape hatch** — a branch whose name starts with `skip_marker` is left untouched.

## Enable & configure

```bash
echo '{ "on_done": "draft-pr" }' > .ship-when-done.json   # opt this repo in
```
> ⚠️ `gate` and `judge_command` are shell commands run on **every** turn in an opted-in repo. Only
> enable ship-when-done in repos you trust.
```jsonc
{
  "on_done": "draft-pr",        // draft-pr (default) | ready-pr | suggest
  "gate": null,                  // auto-detected (pnpm ts:check / npm test / composer test…) unless set
  "ticket_pattern": "\\b([A-Z][A-Z0-9]+-\\d+)\\b",
  "commit_convention": "conventional", // conventional | ticket ([TICKET] type: desc)
  "require_green_gate_for_pr": true,
  "judge_command": null,        // optional independent judge — YOUR own (API-keyed) command; off by default
  "skip_marker": "wip/",
  "forge": null,                 // github | gitlab | bitbucket — auto-detected from the remote unless set
  "default_base": null           // PR/MR target branch — defaults to the remote's default branch
}
```

## Manual / debug

```bash
python3 scripts/ship.py state                                   # show git state JSON
python3 scripts/ship.py mark-done --summary "<one line>"        # agent: declare the task complete
python3 scripts/ship.py ladder --verdict '{"done":true}' --gate pass   # run the ladder with an explicit verdict
python3 scripts/ship.py engage --goal "<ticket/prompt>"         # full flow (opt-in repos only)
```

## Dependencies

Only **`git`** and **Python 3** (stdlib only) — both already present wherever Claude Code runs. `gh`
and `glab` are **optional**: used if installed, otherwise the GitLab push-option / URL paths above
take over, so the PR/MR step never hard-depends on a forge CLI.

## Caveats

- Models over-claim "done" — that is why the PR step requires the gate to *actually run green*, not a
  self-report. Keep `require_green_gate_for_pr: true`.
- **No model call**, by design. The optional `judge_command` is yours to wire (e.g. an API-keyed
  judge) and is off by default.
- Runs at end-of-turn and can run the gate then; keep the gate fast or scope the opt-in to repos where
  that is acceptable.
- Commits the full working tree (`git add -A`); start from a clean tree so milestones stay scoped.
