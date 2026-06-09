---
name: mr-watchdog
description: >-
  Triggered by an open merge request, a detached background watchdog monitors the MR's remote CI and
  drives it to green. On a red pipeline it fetches the failing job log, spawns a headless agent to fix
  the *root cause* — never a bypass (no skipped/deleted tests, no `--no-verify`, no `|| true`, no
  lowered thresholds) — commits the fix on the branch to re-trigger CI, and loops until green or a
  bounded attempt cap, then reports back. Never merges, never touches the default branch, never
  force-pushes. Opt-in per repo. Forge-agnostic (GitHub via `gh`, GitLab via `glab`). The sequel to
  ship-when-done.
---

# mr-watchdog

You open the MR; this watches it land. The trigger is the **merge request**, not a command you run —
once an MR with live CI exists for the current branch, a **detached background watcher** starts on its
own and keeps working while you move on.

## How it fires

A **`Stop` hook** (`hooks/hooks.json` → `hooks/stop-hook.py`) does two cheap things at end-of-turn:
1. **announces** the watcher's latest terminal result (`green` / `blocked` / `exhausted`) once,
2. **launches** a watcher (idempotent — no-op if one is already running or there is no open MR).

It is **opt-in per repo**: silent unless the repo has a `.mr-watchdog.json` file **or**
`MR_WATCHDOG=1` is set. The watcher itself is a **detached process** that survives the turn and polls
the remote CI in the background.

## The loop (one `tick` = one poll → at most one fix)

| CI status | Action |
|---|---|
| `success` | write **green**, announce "ok c'est bon", stop |
| `pending` | wait `poll_interval`, poll again |
| `failed` | fetch the failing job log → **fix the root cause** → commit on the branch → push (re-triggers CI) → poll again |
| failed, attempts exhausted | stop as **exhausted** — hands back to you |

The fix is produced by a **headless agent** (`claude -p` by default, or your `fix_command`). Its change
is **gate-kept** before it is allowed to land.

## The anti-bypass gate (the soul)

A "fix" that hides the failure instead of resolving it is **reverted, never committed**. The gate scans
the staged diff and refuses, among others: `--no-verify`, `|| true`, `continue-on-error: true`,
`allow_failure: true`, skipped/`xfail`/deleted tests (`@pytest.mark.skip`, `it.skip`, `xit`…), blanket
`eslint-disable` / `# type: ignore` / `@ts-ignore` / blanket `# noqa`, and `skip_tests`. If the only way
to green is a workaround, the watchdog **stops and tells you** rather than faking it.

## Guardrails (never crossed)

- **Never merges** — there is no merge path in the code; you merge.
- **Never the default branch** — refuses to run/commit/push on `main`/`master`/`develop`/`trunk`.
- **Never force-pushes**; commits only on the MR's own branch.
- **Bounded** — `max_fix_attempts` caps autonomous rounds (and the Agent SDK spend).
- **`wip/` escape hatch** — a branch named `skip_marker*` is left alone.
- **One watcher per branch** (pid lock); re-entrant launches are no-ops.

## Enable & configure

```bash
echo '{ "max_fix_attempts": 3 }' > .mr-watchdog.json   # opt this repo in
```
> ⚠️ When red, the watchdog runs a headless agent that **edits and commits** on your branch, and the
> `fix_command`/`gate` run on your machine. Only enable in repos you trust. The headless fixer
> (`claude -p`) draws from the Agent SDK credit pool.
```jsonc
{
  "forge": null,             // github | gitlab — auto-detected from the remote unless set
  "poll_interval": 30,       // seconds between CI polls
  "max_fix_attempts": 3,     // hard cap on autonomous fix rounds
  "fix_command": null,       // your own fixer (gets the failing log in $MR_WATCHDOG_LOG); defaults to `claude -p`
  "fix_timeout": 1200,       // seconds per fix attempt
  "notify": "status-file",   // status-file | desktop (macOS notification)
  "skip_marker": "wip/"
}
```

## Manual / debug

```bash
python3 scripts/watch.py start  --repo .     # launch the detached watcher (opt-in repos only)
python3 scripts/watch.py status --repo .     # show the watcher's JSON status
python3 scripts/watch.py tick   --repo .     # run ONE poll→maybe-fix cycle in the foreground
python3 scripts/watch.py stop   --repo .     # kill the watcher
```

## Dependencies

`git`, Python 3 (stdlib only), and a forge CLI — **`gh`** (GitHub) or **`glab`** (GitLab) — to read CI
status and logs. The default fixer is **`claude -p`** (override with `fix_command`).

## Caveats

- It opens no PR and merges nothing — pair it with **ship-when-done** (which opens the draft MR) for
  the full open→green→(you merge) chain.
- Reading CI status relies on the forge CLI's output; if the CLI can't see a pipeline it reports
  `none` and the watcher idles rather than guessing.
- It only fixes when the tracked tree is **clean** — if you have uncommitted changes on the branch it
  stops (`dirty-tree`) rather than risk your work. Commit or stash, and it resumes.
- The anti-bypass gate is deliberately **strict** and heuristic: it blocks any test-file edit that drops
  an assertion (even a legitimate refactor) and the common fake-green markers, but it can't catch every
  semantic cheat. The real backstops are the clean-tree rule, the bounded attempts, and **you** merging.
- Each fix round spends Agent SDK credits; keep `max_fix_attempts` modest and the gate fast.
