---
name: claude-remote-spawn
description: Spawn a PERSISTENT, VISIBLE Claude Code session you can drive from your phone or desktop (Remote Control). Runs `claude --remote-control <name>` inside a PTY so it appears in `claude agents` and in Remote Control and stays alive until you stop it. Terminal-agnostic, cross-platform (macOS + Linux). Use when asked to spawn a remote-controllable Claude session, launch a persistent agent you can steer from your phone, keep a Claude session running detached from your terminal, or resume/respawn an existing session remotely from its id (or from a description, by composing with the find-session skill). Subcommands via driver.sh — spawn / resume / list / stop / check.
---

# claude-remote-spawn

> `spawn` launches a **persistent, visible** Claude Code session — `claude --remote-control <name>`
> run inside a **PTY** (`script(1)`) — so it shows up in `claude agents` **and** in **Remote
> Control** (phone/desktop), and stays alive until you `stop` it.

`spawn` uses `--permission-mode auto` (auto-approve) by default; set `CRS_HEADLESS_DANGEROUS=1`
for `--dangerously-skip-permissions`, or `CRS_HEADLESS_PERM_FLAGS` for an exact override.

## Usage

    driver.sh <spawn|resume|list|stop|check> [args]

| Subcommand | Effect |
|---|---|
| `spawn [name] [--model M] [--prompt 'text']` | Launch a **persistent, visible** session; name from context (else NATO: alpha/bravo/charlie…). `--prompt` submits an initial instruction, so the session starts working unattended |
| `resume <id> [name] [--in-place] [--model M]` | Respawn an **existing** session by id; forks a fresh drivable id by default (`--in-place` = same id) |
| `list` | List spawned sessions (live/dead, with the model if one was set) |
| `stop <name>` | Stop a session (kills the PTY + claude, cleans state) |
| `check` | Health: claude, script, perms, **available models**, remoteControlAtStartup, session count |

## Choosing the model

`--model` picks the model for the spawned session. It takes **any value your `claude` accepts** — an
alias (`opus`, `sonnet`, `fable`, …) or a full id (`claude-fable-5`) — and is passed **straight to
`claude --model`, which validates it**. Nothing is hardcoded, so new models work the day `claude` ships
them. Omit it to use your default; `check` prints the alias list from your own `claude --help`.

    driver.sh spawn reviewer --model opus
    driver.sh resume <id> --model sonnet

## Naming

Sessions should be **recognizable**, not random:

- **spawn** — pass a descriptive `name` from the task/context (the feature, repo, or goal you're
  spawning the agent for). If you omit it, the next **NATO phonetic** name is assigned
  (`alpha`, `bravo`, `charlie`…).
- **resume** — the name is **auto-recovered** from the session's own title (Claude Code's generated
  title, which also tracks the latest exchanges) and shown as the Remote Control display name; pass
  a `name` to override.

## How `spawn` works (and why it stays visible)

- Runs `claude --remote-control <name>` inside a **PTY** via `script(1)` — the only way an
  interactive Remote-Control session survives detached — the same pattern a persistent
  launchd/systemd KeepAlive service uses (`script -q … claude …`).
- The session **stays alive** (a real long-running process) → it appears in `claude agents`
  and, with `"remoteControlAtStartup": true` in `~/.claude/settings.json`, in **Remote
  Control** on your phone/desktop. You drive it from there.
- It's a **long-running, visible** session — not a one-shot that exits immediately and leaves nothing
  to drive.

## Resume an existing session

`resume` respawns a **past** session as a Remote-Control session, so you can pick it back up from
your phone:

    driver.sh resume <session-id> [name] [--in-place]

- It resolves the session's original working directory from its transcript and respawns there, named
  by the session's recovered title.
- **Forks by default** (`--fork-session` → a fresh session id) — this is what makes the resumed
  session show up as a new, drivable Remote Control entry. Resuming **in place** an id that Remote
  Control already knows does *not* surface a new entry, so `--in-place` (continue the same id) is the
  exception, not the default.
- To resume **from a description** instead of an id, resolve the id with the **find-session** skill
  first, then pass it here — the two compose, no hard dependency:
  *"reopen the session about the payload-hash work, remotely"* → `find-session` → id →
  `driver.sh resume <id>`.

## Requirements / gotchas

- **cwd must be a TRUSTED folder** — otherwise the session blocks on Claude Code's
  workspace-trust dialog and never registers (stays invisible). Runs in `$PWD`; override
  with `CRS_SPAWN_CWD`.
- Needs `script(1)` (present on macOS + Linux).
- State lives in `~/.claude/headless/<name>.{spawn,log}`.

## Env

- `CRS_CLAUDE_BIN` — path to `claude` (default `~/.local/bin/claude`)
- `CRS_HEADLESS_STATE` — state dir (default `~/.claude/headless`)
- `CRS_SPAWN_CWD` — working dir for `spawn` (must be TRUSTED; default `$PWD`)
- `CRS_HEADLESS_DANGEROUS` — use `--dangerously-skip-permissions` instead of the `auto` default
- `CRS_HEADLESS_PERM_FLAGS` — exact permission-flags override (`""` = none)
