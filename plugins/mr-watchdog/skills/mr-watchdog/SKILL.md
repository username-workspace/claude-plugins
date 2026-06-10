---
name: mr-watchdog
description: >-
  Triggered by an open merge request, mr-watchdog watches the MR's remote CI as a background task your
  MAIN session owns — read-only: it never commits, pushes, or merges. The watcher is launched with
  run_in_background and tracked by the harness, which re-invokes your session the moment it resolves, so
  the verdict reaches you IN the conversation: green → "ok, all good"; red → the failing job log so your
  session fixes the *root cause* (no bypass), with `verify` to self-check the fix for fake-green. Engages
  only a branch THIS session pushed; opt out per repo. Forge-agnostic (GitHub via gh, GitLab via glab).
  The CI-watch step after ship-when-done → merge-review.
---

# mr-watchdog

You open the MR; this watches its CI land — in the background, and the result **comes back to you in the
conversation**. The trigger is the **merge request**, not a command.

The watcher runs as a **background task your session owns**: it is launched with `run_in_background`,
the **harness tracks it across turns**, and when it exits the harness **re-invokes your session** with
the result. There is no detached daemon, no status file, no polling-by-hook — the harness's own
background-task tracking is the delivery channel.

It is **read-only** — it never commits, pushes, or merges. On green it tells you `ok, all good`; on red
it hands back the failing job log so your session fixes the **root cause** (no bypass).

## How it fires

A **`Stop` hook** (`hooks/stop-hook.py` → `watch.py hook`) checks, at end-of-turn, whether the current
branch has an **open MR with live CI** that this session pushed and hasn't watched yet for this HEAD. If
so it emits a **`block`** asking your session to launch the watcher in the background:

```bash
python3 scripts/watch.py run --repo <repo>   # launch with run_in_background=true, then carry on
```

You launch it once (the nudge is dedup'd per pipeline HEAD). A companion `UserPromptSubmit` hook stamps
the branch's pushed state at the start of each turn so engagement only ever covers a branch **this
session actually pushed** (its `@{u}` advanced) — a stale MR or someone else's MR is never touched. Opt a
repo **out** with `{ "enabled": false }` in `.mr-watchdog.json`.

## The watcher (`run`) — poll until resolved, then exit

`run` is a foreground poll loop **meant to be launched with run_in_background**. It polls the CI and
**exits the moment the pipeline resolves**, printing the verdict — and the harness re-invokes your
session with that output:

| CI status | What `run` does |
|---|---|
| `pending` | wait `poll_interval`, poll again |
| `success` | print `ok, all good — CI green on '<branch>'`, **exit 0** |
| `failed`  | print the failing job log + the fix directive, **exit 1** |
| MR closed / HEAD moved | print why, exit (a fresh watcher starts after the next push) |

When your session is re-invoked: **green** → tell the user `ok, all good`; **red** → fix the ROOT cause
from the log (no bypass), run `verify`, push the fix. The push re-triggers the chain, and a fresh
watcher is launched for the new HEAD.

`on_red: "notify"` makes `run` print the red log as a passive report instead of a fix directive.

## `verify` — the fake-green gate, in your hands

Run it before committing a CI fix. It scans your working-tree change and **fails (exit 1)** if the
"fix" hides the failure instead of resolving it — a **deleted** or **weakened** test (an edit that
drops an assertion), `assert True`, `--no-verify`, `|| true`, `continue-on-error`, `allow_failure`,
`when: never`, blanket `eslint-disable` / `# type: ignore` / `@ts-ignore` / `@ts-expect-error`,
`--maxfail`, etc. Clean change → exit 0.

```bash
python3 scripts/watch.py verify --repo .
```

## Guardrails

- **Read-only**: never commits, pushes, or merges — there is no git-write path in the watcher.
- **Only watches**: it polls CI and reads logs — the fix is done by your interactive session.
- **Never the default branch**, never a `wip/` branch, never a detached HEAD (it just won't watch).
- **Engagement**: only a branch this session pushed; the launch nudge fires **once per pipeline HEAD**.

## Enable & configure

No config is required — it engages on its own. Drop a `.mr-watchdog.json` only to tune it or opt out:
```jsonc
{
  "enabled": true,         // set false to opt this repo OUT (engagement is otherwise automatic)
  "on_red": "fix",         // fix (hand the failure to your session to fix) | notify (just report it)
  "forge": null,           // github | gitlab — auto-detected from the remote unless set
  "poll_interval": 30,     // seconds between CI polls
  "log_lines": 200,        // failing-log lines carried into the handoff
  "skip_marker": "wip/",
  "watch_timeout": 3600    // seconds before a still-pending watch gives up (the poll loop is always bounded)
}
```

## Manual / debug

```bash
python3 scripts/watch.py run    --repo .     # the bg watcher: poll until resolved, then exit (run_in_background)
python3 scripts/watch.py hook   --repo .     # what the Stop hook calls: emit the launch block if due
python3 scripts/watch.py tick   --repo .     # run ONE poll in the foreground (no loop)
python3 scripts/watch.py verify --repo .     # check the current working-tree fix for fake-green
```

## Dependencies

`git`, Python 3 (stdlib only), and a forge CLI — **`gh`** (GitHub) or **`glab`** (GitLab) — to read CI
status and logs. The fix runs in your interactive session.

## Caveats

- It opens no MR and merges nothing — it's the CI-watch step after **ship-when-done** (which pushes and
  opens the MR once **merge-review** has passed) for the full open → review → green → (you merge) chain.
- Reading CI status relies on the forge CLI's output; if the CLI can't see a pipeline it reports `none`
  and the watcher idles rather than guessing.
- Delivery rides the harness: the watcher is a background task **your session launched**, so its verdict
  re-invokes that session when it resolves. The only remote dependency in the whole chain lives here.
