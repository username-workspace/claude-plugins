---
name: mr-watchdog
description: >-
  Triggered by an open merge request, a detached background watchdog monitors the MR's remote CI. It
  runs no model of its own and never commits, pushes, or merges — it watches, and on a red pipeline it
  fetches the failing job log and hands the failure to your live session to fix at the *root* (no
  bypass). `verify` lets that session self-check its change for fake-green before committing. Opt-in
  per repo. Forge-agnostic (GitHub via gh, GitLab via glab). The sequel to ship-when-done.
---

# mr-watchdog

You open the MR; this watches its CI land — in the background, for free. The trigger is the **merge
request**, not a command: once an MR with live CI exists for the current branch, a **detached watcher**
starts on its own and keeps polling while you move on.

It is a **monitor + handoff**, by design: it runs **no model of its own** (so it never touches the
Agent SDK / headless credit pool) and it is **read-only** — it never commits, pushes, or merges. When
CI goes red it pulls the failing job log and hands the failure to **your interactive session** (on your
subscription) to fix at the root.

## How it fires

A **`Stop` hook** (`hooks/hooks.json` → `hooks/stop-hook.py`) at end-of-turn does two cheap things:
1. **announces** the watcher's latest result (a red **handoff**, or `green`) once,
2. **launches** a watcher (idempotent — no-op if one is already running or there is no open MR).

Opt-in per repo: silent unless the repo has a `.mr-watchdog.json` file **or** `MR_WATCHDOG=1` is set.
The watcher is a **detached process** that survives the turn and the Claude session.

## The loop (read-only)

| CI status | Action |
|---|---|
| `success` | announce **"ok c'est bon"**, stop |
| `pending` | wait `poll_interval`, poll again |
| `failed` | fetch the failing job log → write a **handoff** (surfaced next turn), keep polling |

On red it **stops watching nothing** — it keeps polling, so once you push a fix the same watcher sees
the new pipeline through to green. A fresh red pipeline (new commit) is handed off once.

## The handoff → you fix it (on your subscription)

Next turn, the Stop hook surfaces:

> ⚠ CI rouge sur 'feat'. Corrige la **cause racine** — pas de contournement … Puis `watch.py verify`
> avant de committer. Log du job en échec : …

Your live session fixes the **root cause**, then self-checks with **`verify`**, then commits/pushes
(or lets **ship-when-done** do it). The watcher catches the new pipeline and continues.

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
- **Runs no model**: zero headless/Agent-SDK spend; the only LLM work is your interactive session.
- **Never the default branch**, never a `wip/` branch, never a detached HEAD (it just won't watch).
- **One watcher per branch** (atomic pid lock); re-launches are no-ops.

## Enable & configure

```bash
echo '{ "poll_interval": 30 }' > .mr-watchdog.json   # opt this repo in
```
```jsonc
{
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
status and logs. **No `claude -p`**: the fix runs in your interactive (subscription) session.

## Caveats

- It opens no MR and merges nothing — pair it with **ship-when-done** (which opens the draft MR) for
  the full open → green → (you merge) chain.
- Reading CI status relies on the forge CLI's output; if the CLI can't see a pipeline it reports
  `none` and the watcher idles rather than guessing.
- The fix is **not** unattended: it happens in your live session when you're back (on your
  subscription), with the failing log already pulled and `verify` to keep it honest.
