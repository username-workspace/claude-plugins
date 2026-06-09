---
name: mr-watchdog
description: >-
  Triggered by an open merge request, a detached background watchdog monitors the MR's remote CI —
  read-only: it never commits, pushes, or merges. On a red pipeline it fetches the failing job log and,
  by default (`on_red: "fix"`), continues your interactive session to fix the *root cause* (no bypass),
  or just surfaces it (`on_red: "notify"`). `verify` lets that session self-check its fix for fake-green
  (deleted/weakened tests, --no-verify, || true, lowered thresholds) before committing. Opt-in per
  repo. Forge-agnostic (GitHub via gh, GitLab via glab). The sequel to ship-when-done.
---

# mr-watchdog

You open the MR; this watches its CI land — in the background, for free. The trigger is the **merge
request**, not a command: once an MR with live CI exists for the current branch, a **detached watcher**
starts on its own and keeps polling while you move on.

It is a **read-only** watcher — it never commits, pushes, or merges. When CI goes red it pulls the
failing job log and, by default, **continues your interactive session to fix the root cause**. Set
`on_red: "notify"` to just surface it instead.

## How it fires

A **`Stop` hook** (`hooks/hooks.json` → `hooks/stop-hook.py`) at end-of-turn does two cheap things:
1. **(re)launches** the background watcher (idempotent — no-op if one runs already or there's no open MR),
2. acts on the watcher's latest result — a `green` notice, or a red **handoff** (see below) — once.

Opt-in per repo: silent unless the repo has a `.mr-watchdog.json` file **or** `MR_WATCHDOG=1` is set.
The watcher is a **detached process** that survives the turn and the Claude session.

## The loop (read-only)

| CI status | Action |
|---|---|
| `success` | "ok c'est bon", stop |
| `pending` | wait `poll_interval`, poll again |
| `failed` | fetch the failing job log → record a **handoff**, keep polling |

It keeps polling through red, so once a fix lands the same watcher sees the new pipeline through to
green. A fresh red pipeline (new commit) is handed off once.

## The handoff — fix in your live session

On the next end-of-turn after a red pipeline, the Stop hook acts on `on_red`:

- **`on_red: "fix"` (default)** — it returns a `Stop`-hook **block** decision, which makes Claude Code
  **continue your current interactive session** with: *"the CI is failing — fix the root cause, no
  bypass, run `verify`, then commit."* Your live agent fixes it. Re-entrancy is guarded by
  `stop_hook_active`, so it triggers **once** per failing pipeline — never an infinite loop. It fires
  at a turn boundary while you're active (not while you're fully away with no session).
- **`on_red: "notify"`** — it just prints the failing log + the "fix the root cause … then `verify`"
  notice, and you drive the fix yourself.

Either way the fix happens in your interactive session; **`verify`** keeps it honest; **ship-when-done**
(if enabled) commits/pushes; and the watcher then sees the new pipeline through.

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
- **Only watches**: it polls CI and reads logs — the fix itself is done by your interactive session.
- **Never the default branch**, never a `wip/` branch, never a detached HEAD (it just won't watch).
- **One watcher per branch** (atomic pid lock); re-launches are no-ops.

## Enable & configure

```bash
echo '{ "poll_interval": 30 }' > .mr-watchdog.json   # opt this repo in
```
```jsonc
{
  "on_red": "fix",         // fix (continue your live session to fix it) | notify (just surface it)
  "forge": null,           // github | gitlab — auto-detected from the remote unless set
  "poll_interval": 30,     // seconds between CI polls
  "log_lines": 200,        // failing-log lines carried into the handoff
  "notify": "status-file", // status-file | desktop (macOS notification on red/green)
  "skip_marker": "wip/"
}
```

## Manual / debug

```bash
python3 scripts/watch.py start   --repo .     # launch the detached watcher (opt-in repos only)
python3 scripts/watch.py status  --repo .     # the watcher's JSON status
python3 scripts/watch.py announce --repo .    # surface the latest handoff / green (what the hook prints)
python3 scripts/watch.py verify  --repo .     # check the current working-tree fix for fake-green
python3 scripts/watch.py tick    --repo .     # run ONE poll in the foreground
python3 scripts/watch.py stop    --repo .     # kill the watcher
```

## Dependencies

`git`, Python 3 (stdlib only), and a forge CLI — **`gh`** (GitHub) or **`glab`** (GitLab) — to read CI
status and logs. The fix runs in your interactive session.

## Caveats

- It opens no MR and merges nothing — pair it with **ship-when-done** (which opens the draft MR) for
  the full open → green → (you merge) chain.
- Reading CI status relies on the forge CLI's output; if the CLI can't see a pipeline it reports
  `none` and the watcher idles rather than guessing.
- Autonomy lives in **your** session: with `on_red: "fix"` the watchdog continues your live session to
  do the fix — but that fires at a **turn boundary while you're active**, not
  while you're fully away with no running session. The watcher keeps monitoring regardless.
- `manual` debug also has `hook` (what the Stop hook calls: emits the block decision or the notice) —
  you normally don't call it directly.
