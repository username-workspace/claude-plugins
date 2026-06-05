---
name: claude-remote-spawn
description: Spawn a PERSISTENT, VISIBLE Claude Code session drivable from your phone/desktop (Remote Control) — or run a one-shot headless prompt. Terminal-agnostic, cross-platform. Use when asked to "lance claude headless", spawn a remote-controllable agent, or run a quick headless prompt. Subcommands via driver.sh — spawn / list / stop / oneshot / check.
---

# claude-remote-spawn

> `spawn` launches a **persistent,
> visible** Claude Code session — `claude --remote-control <name>` run inside a **PTY**
> (`script(1)`) — so it shows up in `claude agents` **and** in **Remote Control**
> (phone/desktop), and stays alive until you `stop` it. `oneshot` is a quick synchronous
> `claude -p`.

`spawn`/`oneshot` use `--permission-mode auto` (auto-approve) by default; set
`CRS_HEADLESS_DANGEROUS=1` for `--dangerously-skip-permissions`, or `CRS_HEADLESS_PERM_FLAGS`
for an exact override.

## Usage

    driver.sh <spawn|list|stop|oneshot|check> [args]

| Subcommand | Effect |
|---|---|
| `spawn [name]` | Launch a **persistent, visible** session (Remote Control + `claude agents`); prints the name |
| `list` | List spawned sessions (live/dead) |
| `stop <name>` | Stop a session (kills the PTY + claude, cleans state) |
| `oneshot "<prompt>"` | One-shot synchronous run -> prints the answer |
| `check` | Health: claude, script, model, perms, remoteControlAtStartup, session count |

## How `spawn` works (and why it stays visible)

- Runs `claude --remote-control <name>` inside a **PTY** via `script(1)` — the only way an
  interactive Remote-Control session survives detached — the same pattern a persistent
  launchd/systemd KeepAlive service uses (`script -q … claude …`).
- The session **stays alive** (a real long-running process) → it appears in `claude agents`
  and, with `"remoteControlAtStartup": true` in `~/.claude/settings.json`, in **Remote
  Control** on your phone/desktop. You drive it from there.
- This is the opposite of `claude -p`, which runs once and exits (invisible). `oneshot` is
  the only `-p` path here — for quick non-interactive answers.

## Requirements / gotchas

- **cwd must be a TRUSTED folder** — otherwise the session blocks on Claude Code's
  workspace-trust dialog and never registers (stays invisible). Runs in `$PWD`; override
  with `CRS_SPAWN_CWD`.
- Needs `script(1)` (present on macOS + Linux).
- State lives in `~/.claude/headless/<name>.{spawn,log}`.

## Env

- `CRS_CLAUDE_MODEL` — model for `oneshot` (default `claude-opus-4-8[1m]`)
- `CRS_CLAUDE_BIN` — path to `claude` (default `~/.local/bin/claude`)
- `CRS_HEADLESS_STATE` — state dir (default `~/.claude/headless`)
- `CRS_SPAWN_CWD` — working dir for `spawn` (must be TRUSTED; default `$PWD`)
- `CRS_HEADLESS_DANGEROUS` — use `--dangerously-skip-permissions` instead of the `auto` default
- `CRS_HEADLESS_PERM_FLAGS` — exact permission-flags override (`""` = none)
