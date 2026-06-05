#!/usr/bin/env bash
# claude-remote-spawn — driver.sh (terminal-agnostic, cross-platform: macOS + Linux)
# spawn = a PERSISTENT, VISIBLE Claude Code session: `claude --remote-control <name>` run in a
#   PTY via script(1), so it shows up in `claude agents` + Remote Control (phone/desktop) and
#   stays alive until `stop`. Same pattern a persistent launchd/systemd KeepAlive service uses.
#   oneshot = a quick synchronous `claude -p`.
# Permissions: default "--permission-mode auto"; CRS_HEADLESS_DANGEROUS=1 -> --dangerously-skip-permissions;
#   CRS_HEADLESS_PERM_FLAGS overrides with an exact value (incl. "").
set -euo pipefail

MODEL="${CRS_CLAUDE_MODEL:-claude-opus-4-8[1m]}"
CLAUDE_BIN="${CRS_CLAUDE_BIN:-$HOME/.local/bin/claude}"
STATE_DIR="${CRS_HEADLESS_STATE:-$HOME/.claude/headless}"
if   [ -n "${CRS_HEADLESS_PERM_FLAGS+set}" ]; then PERM="$CRS_HEADLESS_PERM_FLAGS"
elif [ -n "${CRS_HEADLESS_DANGEROUS:-}" ];    then PERM="--dangerously-skip-permissions"
else PERM="--permission-mode auto"; fi
mkdir -p "$STATE_DIR"

die(){ echo "x $*" >&2; exit 1; }
need_claude(){ [ -n "$CLAUDE" ] || die "claude not found (set CRS_CLAUDE_BIN)"; }
need_script(){ command -v script >/dev/null 2>&1 || die "script(1) not found"; }
spawn_get(){ sed -n "s/^$2=//p" "$STATE_DIR/$1.spawn" 2>/dev/null | head -1; }
is_running(){ [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

if   [ -x "$CLAUDE_BIN" ];               then CLAUDE="$CLAUDE_BIN"
elif command -v claude >/dev/null 2>&1;  then CLAUDE="claude"
else CLAUDE=""; fi

usage(){ cat >&2 <<EOF
usage: driver.sh <spawn|list|stop|oneshot|check> [args]
  spawn [name]          launch a PERSISTENT, VISIBLE session (Remote Control + 'claude agents')
  list                  list spawned sessions (live/dead)
  stop <name>           stop a session
  oneshot "<prompt>"    one-shot synchronous run (claude -p, model: $MODEL)
  check                 health (claude, script, model, perms, remote-control, sessions)
spawn runs 'claude --remote-control <name>' in a PTY (script) so it stays visible & drivable
from your phone/desktop. cwd MUST be a TRUSTED folder (default \$PWD; override CRS_SPAWN_CWD).
env: CRS_CLAUDE_MODEL, CRS_CLAUDE_BIN, CRS_HEADLESS_STATE, CRS_SPAWN_CWD,
     CRS_HEADLESS_DANGEROUS, CRS_HEADLESS_PERM_FLAGS
EOF
exit 2; }

cmd="${1:-}"; shift || true
case "$cmd" in
  spawn)
    need_claude; need_script
    name="${1:-claude-$(date +%H%M%S)}"
    if [ -e "$STATE_DIR/$name.spawn" ]; then die "session '$name' already exists (stop it first)"; fi
    cwd="${CRS_SPAWN_CWD:-$PWD}"
    log="$STATE_DIR/$name.log"
    cd "$cwd" || die "cannot cd to $cwd"
    case "$(uname -s)" in
      Darwin) ( export TERM=xterm-256color; tail -f /dev/null | script -q "$log" "$CLAUDE" --remote-control "$name" $PERM ) >/dev/null 2>&1 & ;;
      Linux)  ( export TERM=xterm-256color; tail -f /dev/null | script -qec "$CLAUDE --remote-control $name $PERM" "$log" ) >/dev/null 2>&1 & ;;
      *)      die "spawn: unsupported OS $(uname -s)" ;;
    esac
    printf 'name=%s\ncwd=%s\nstarted=%s\nsubshell=%s\n' "$name" "$cwd" "$(date -u +%FT%TZ)" "$!" >"$STATE_DIR/$name.spawn"
    echo "$name"
    echo "spawned '$name' in $cwd — visible in Claude Code Remote Control (phone/desktop) + 'claude agents'. (cwd must be TRUSTED.)" >&2
    ;;
  list)
    shopt -s nullglob; spawns=("$STATE_DIR"/*.spawn)
    if [ ${#spawns[@]} -eq 0 ]; then echo "(no sessions)"; exit 0; fi
    for s in "${spawns[@]}"; do
      n="$(basename "$s" .spawn)"
      state="dead"; if is_running "$(spawn_get "$n" subshell)"; then state="live"; fi
      printf '%-22s %-6s started=%s  cwd=%s\n' "$n" "$state" "$(spawn_get "$n" started)" "$(spawn_get "$n" cwd)"
    done
    ;;
  stop)
    name="${1:-}"; [ -n "$name" ] || die "stop needs a <name>"
    [ -f "$STATE_DIR/$name.spawn" ] || die "no session $name"
    sp="$(spawn_get "$name" subshell)"
    if is_running "$sp"; then pkill -P "$sp" 2>/dev/null || true; kill "$sp" 2>/dev/null || true; fi
    pkill -f "remote-control $name" 2>/dev/null || true
    rm -f "$STATE_DIR/$name.spawn" "$STATE_DIR/$name.log"
    echo "stopped $name"
    ;;
  oneshot)
    need_claude; [ $# -ge 1 ] || die "oneshot needs a prompt"
    "$CLAUDE" -p "$*" --model "$MODEL" $PERM
    ;;
  check)
    echo "claude : $([ -n "$CLAUDE" ] && "$CLAUDE" --version 2>/dev/null || echo 'NOT FOUND')"
    echo "script : $(command -v script >/dev/null 2>&1 && echo ok || echo 'NOT FOUND')"
    echo "model  : $MODEL"
    echo "perms  : $PERM"
    if grep -q '"remoteControlAtStartup": *true' "$HOME/.claude/settings.json" 2>/dev/null; then
      echo "remote : remoteControlAtStartup=true (every session is Remote-Control-visible)"
    else
      echo "remote : remoteControlAtStartup off — spawn still forces --remote-control <name>"
    fi
    shopt -s nullglob; spawns=("$STATE_DIR"/*.spawn)
    echo "spawns : ${#spawns[@]} session(s)"
    ;;
  ""|-h|--help) usage ;;
  *) die "unknown subcommand: $cmd (see --help)";;
esac
