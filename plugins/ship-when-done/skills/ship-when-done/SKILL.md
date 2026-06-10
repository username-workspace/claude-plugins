---
name: ship-when-done
description: >-
  A Stop-hook harness that commits at each milestone, pushes the feature branch to keep work safe
  (mandatory when a remote exists), and opens a draft PR/MR once the work is *provably* done — the
  checklist derived from the initiating goal is satisfied AND the project's quality gate is actually
  green. Forge-agnostic (GitHub, GitLab, Bitbucket): uses gh/glab if present, else GitLab push
  options, else surfaces the PR-creation URL — no CLI dependency. Branch-first; never commits or
  pushes the default branch; never merges; no AI attribution. Engages on its own only on work THIS
  session produced (never a pre-existing dirty tree); opt out per repo. Use when you want the agent to
  commit/push/open-PR on its own instead of being asked each time. Horizontal: any repo with a remote
  and a detectable gate.
---

# ship-when-done

Turns "did you commit / push / open the MR?" from a thing the human keeps asking into a thing the
agent does — gated on **real signals**, not the model's self-confidence.

## How it fires

It registers a **`Stop` hook** (end of an agent turn — `hooks/hooks.json` → `hooks/stop-hook.py` →
`scripts/ship.py engage`). It **engages itself** — no opt-in file, no env var. A companion
`UserPromptSubmit` hook stamps HEAD + the dirty set at the start of each turn; it acts **only if THIS
session produced the work** (HEAD advanced or the tree changed since that baseline), so it never
sweeps up a **pre-existing dirty tree** you didn't touch, or auto-mutates a repo you're just visiting.
Opt a repo **out** with `{ "enabled": false }` in `.ship-when-done.json`. When engaged, it still acts
only if there is work in flight (uncommitted changes or unshipped commits).

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
unsure → **not done**. The marker is consumed once a PR opens. When you claim done but no gate is
detectable, the withheld PR is said out loud (`pr-withheld:no-gate-detected`) instead of failing
silently — set `gate` in `.git/ship-when-done.json` to unlock it.

To plug an independent judge, set `judge_command` (your own command) — off by default; it can only
*downgrade* `done`.

## Guardrails (never crossed)

- **Branch-first** — if on the default branch with changes, it creates a feature branch first; it
  never commits or pushes the default branch.
- **Never merges** — there is no merge path in the code; the PR is opened (draft), the human merges.
- **No AI attribution** in commit messages.
- **`wip/` escape hatch** — a branch whose name starts with `skip_marker` is left untouched.

## Configure (optional — it engages on its own)

No config is required. Drop a `.ship-when-done.json` only to tune it or opt out.
> 🔒 `gate` and `judge_command` are shell commands run on **every** engaged turn, so they are **never
> read from the working-tree file** (which arrives with any clone). They are honored only from
> `.git/ship-when-done.json` (local to your clone, never committed) or an explicitly passed
> `--config` — set them there; in `.ship-when-done.json` they are ignored.
```jsonc
{
  "enabled": true,              // set false to opt this repo OUT (engagement is otherwise automatic)
  "on_done": "draft-pr",        // draft-pr (default) | ready-pr | suggest
  "gate": null,                  // auto-detected (pnpm/bun/yarn/npm scripts, composer test, pytest, go test, cargo test, make test) unless set — .git/ or --config only
  "ticket_pattern": "\\b([A-Z][A-Z0-9]+-\\d+)\\b",
  "commit_convention": "conventional", // conventional | ticket ([TICKET] type: desc)
  "require_green_gate_for_pr": true,
  "judge_command": null,        // optional independent judge — YOUR own (API-keyed) command; off by default — .git/ or --config only
  "skip_marker": "wip/",
  "forge": null,                 // github | gitlab | bitbucket — auto-detected from the remote unless set
  "default_base": null,          // PR/MR target branch — defaults to the remote's default branch
  "respect_merge_review": true   // hold the PR until a sibling merge-review gate passes (if one is active)
}
```

If the **merge-review** plugin is active in the same repo, ship-when-done still commits (the commit is
the anti-loss) but **holds the push** until merge-review has passed the current HEAD — the quality gate
runs **before anything reaches the remote**. It surfaces `push-held:merge-review-pending` and continues
your session to run `/merge-review`; once the pass is recorded, the very next Stop pushes and opens the
PR — no human prompt needed, and the review request fires at most once per work-state (capped per
session), so the Stop hook can never loop. When it creates a branch or pushes, it hands engagement to
the siblings explicitly (their session state is stamped), so a **single-shot delivery** — branch, work,
done in one turn — is still reviewed and its CI still watched; right after the PR opens it relays
mr-watchdog's watcher-launch nudge in the same turn. Loose coupling via the siblings' `.git` state —
absent, all of this is inert. (The only remote dependency in the ship-when-done → merge-review →
mr-watchdog chain is mr-watchdog itself.)

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
- Runs at end-of-turn and can run the gate then (capped at `gate_timeout`, default 120s). **Only a
  green verdict is cached** (per work-state) — a red gate carries no proof of determinism (timeout,
  flake, machine load), so it is re-run on the next Stop and a transient red self-heals instead of
  pinning the PR closed. A timeout is reported distinctly (`pr-withheld:gate-timeout`). Every gate run
  persists its verdict, output tail and duration in `.git/swd-gate.json`, so a red seen only inside a
  Stop hook is diagnosable after the fact.
- Commits the full working tree (`git add -A`); start from a clean tree so milestones stay scoped.
