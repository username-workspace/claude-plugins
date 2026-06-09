#!/usr/bin/env bash
# claude-remote-spawn — driver.sh (terminal-agnostic, cross-platform: macOS + Linux)
# spawn = a PERSISTENT, VISIBLE Claude Code session: `claude --remote-control <name>` run in a
#   PTY via script(1), so it shows up in `claude agents` + Remote Control (phone/desktop) and
#   stays alive until `stop`. Same pattern a persistent launchd/systemd KeepAlive service uses.
# Permissions: default "--permission-mode auto"; CRS_HEADLESS_DANGEROUS=1 -> --dangerously-skip-permissions;
#   CRS_HEADLESS_PERM_FLAGS overrides with an exact value (incl. "").
set -euo pipefail

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

# Feeds claude's stdin: keeps it open (tail), and auto-answers the "resume from summary?" startup
# prompt so an unattended session never hangs. Only acts if the prompt actually appears (a normal
# spawn is unaffected). "2" = resume the full session as-is, preserving context.
session_stdin(){
  local log="$1" i=0
  until grep -aq "Resume from summary" "$log" 2>/dev/null || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
  grep -aq "Resume from summary" "$log" 2>/dev/null && printf '2\r'
  tail -f /dev/null
}

# Launch a persistent Remote-Control session in a PTY; extra args ($3+) go to claude (e.g. --resume). Shared by spawn/resume.
launch_session(){
  local name="$1" cwd="$2"; shift 2
  local log="$STATE_DIR/$name.log"
  cd "$cwd" || die "cannot cd to $cwd"
  case "$(uname -s)" in
    Darwin) ( export TERM=xterm-256color; session_stdin "$log" | script -q "$log" "$CLAUDE" --remote-control "$name" "$@" $PERM ) >/dev/null 2>&1 & ;;
    Linux)  local cmd; printf -v cmd '%q ' "$CLAUDE" --remote-control "$name" "$@" $PERM
            ( export TERM=xterm-256color; session_stdin "$log" | script -qec "$cmd" "$log" ) >/dev/null 2>&1 & ;;
    *)      die "unsupported OS $(uname -s)" ;;
  esac
  printf 'name=%s\ncwd=%s\nstarted=%s\nsubshell=%s\n' "$name" "$cwd" "$(date -u +%FT%TZ)" "$!" >"$STATE_DIR/$name.spawn"
}

slugify(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-48 | sed 's/-*$//'; }
nato_name(){
  for w in alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike \
           november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu; do
    [ -e "$STATE_DIR/$w.spawn" ] || { echo "$w"; return; }
  done
  echo "claude-$(date +%H%M%S)"
}

usage(){ cat >&2 <<EOF
usage: driver.sh <spawn|resume|list|stop|check> [args]
  spawn [name] [--model M]  launch a session; name from context, else NATO (alpha/bravo/charlie…)
  resume <id> [name] [--in-place] [--model M]  respawn an existing session by id (forks a fresh id; --in-place=same id)
  list                     list spawned sessions (live/dead)
  stop <name>              stop a session
  check                    health (claude, script, perms, models, remote-control, sessions)
spawn/resume run 'claude --remote-control <name> [--resume <id>]' in a PTY (script) so the session
stays visible & drivable from your phone/desktop. --model takes any value your 'claude' accepts (an
alias like opus/sonnet/fable, or a full id like claude-fable-5); it is passed straight to
'claude --model' and validated there — nothing is hardcoded. To resume from a description, get the id
with find-session, then 'resume <id>'. cwd MUST be a TRUSTED folder (default \$PWD; override CRS_SPAWN_CWD).
env: CRS_CLAUDE_BIN, CRS_HEADLESS_STATE, CRS_SPAWN_CWD,
     CRS_HEADLESS_DANGEROUS, CRS_HEADLESS_PERM_FLAGS
EOF
exit 2; }

cmd="${1:-}"; shift || true
case "$cmd" in
  spawn)
    need_claude; need_script
    name=""; model=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model)   [ -n "${2:-}" ] || die "--model needs a value (an alias like opus/sonnet/fable, or a full model id)"; model="$2"; shift 2 ;;
        --model=*) model="${1#--model=}"; shift ;;
        -*)        die "unknown flag: $1" ;;
        *)         [ -z "$name" ] && name="$1"; shift ;;
      esac
    done
    [ -n "$name" ] || name="$(nato_name)"
    [ -e "$STATE_DIR/$name.spawn" ] && die "session '$name' already exists (stop it first)"
    cwd="${CRS_SPAWN_CWD:-$PWD}"
    model_args=(); [ -n "$model" ] && model_args=(--model "$model")
    launch_session "$name" "$cwd" -n "$name" ${model_args[@]+"${model_args[@]}"}
    [ -n "$model" ] && echo "model=$model" >>"$STATE_DIR/$name.spawn"
    echo "$name"
    echo "spawned '$name'${model:+ (model: $model)} in $cwd — visible in Claude Code Remote Control (phone/desktop) + 'claude agents'. (cwd must be TRUSTED.)" >&2
    ;;
  resume)
    need_claude; need_script
    id=""; name=""; fork="--fork-session"; model=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --in-place|--no-fork) fork=""; shift ;;
        --fork)               fork="--fork-session"; shift ;;
        --model)   [ -n "${2:-}" ] || die "--model needs a value (an alias like opus/sonnet/fable, or a full model id)"; model="$2"; shift 2 ;;
        --model=*) model="${1#--model=}"; shift ;;
        -*)                   die "unknown flag: $1" ;;
        *)                    if [ -z "$id" ]; then id="$1"; elif [ -z "$name" ]; then name="$1"; fi; shift ;;
      esac
    done
    [ -n "$id" ] || die "resume needs a <session-id> (use find-session to resolve one from a description)"
    projects="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    tx="$(find "$projects" -maxdepth 2 -name "$id.jsonl" 2>/dev/null | head -1)"
    [ -n "$tx" ] || die "no transcript for session '$id' under $projects (check the id)"
    # recover Claude Code's own session title (last ai-title) so the resume is recognizable, not random
    title="$(grep -o '"aiTitle": *"[^"]*"' "$tx" | tail -1 | sed 's/.*"aiTitle": *"//; s/"$//')"
    display="${name:-${title:-resumed session}}"
    [ -n "$name" ] || name="$(slugify "$title")"
    [ -n "$name" ] || name="$(nato_name)"
    [ -e "$STATE_DIR/$name.spawn" ] && die "session '$name' already exists (stop it first)"
    rcwd="$(grep -m1 -o '"cwd":"[^"]*"' "$tx" | sed 's/^"cwd":"//; s/"$//')"
    cwd="${CRS_SPAWN_CWD:-${rcwd:-$PWD}}"
    [ -d "$cwd" ] || die "session cwd '$cwd' not found (override with CRS_SPAWN_CWD)"
    model_args=(); [ -n "$model" ] && model_args=(--model "$model")
    launch_session "$name" "$cwd" --resume "$id" -n "$display" $fork ${model_args[@]+"${model_args[@]}"}
    { echo "resumed=$id"; echo "title=$display"; [ -n "$model" ] && echo "model=$model"; } >>"$STATE_DIR/$name.spawn"
    mode=$([ -n "$fork" ] && echo "new forked id" || echo "in-place, same id")
    echo "$name"
    echo "resumed $id as '$display' (handle: $name) in $cwd — Remote Control + 'claude agents' ($mode)." >&2
    ;;
  list)
    shopt -s nullglob; spawns=("$STATE_DIR"/*.spawn)
    if [ ${#spawns[@]} -eq 0 ]; then echo "(no sessions)"; exit 0; fi
    for s in "${spawns[@]}"; do
      n="$(basename "$s" .spawn)"
      state="dead"; if is_running "$(spawn_get "$n" subshell)"; then state="live"; fi
      ri="$(spawn_get "$n" resumed)"; ri="${ri:+  resumed=$ri}"
      mi="$(spawn_get "$n" model)"; mi="${mi:+  model=$mi}"
      printf '%-22s %-6s started=%s  cwd=%s%s%s\n' "$n" "$state" "$(spawn_get "$n" started)" "$(spawn_get "$n" cwd)" "$ri" "$mi"
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
  check)
    echo "claude : $([ -n "$CLAUDE" ] && "$CLAUDE" --version 2>/dev/null || echo 'NOT FOUND')"
    echo "script : $(command -v script >/dev/null 2>&1 && echo ok || echo 'NOT FOUND')"
    echo "perms  : $PERM"
    mh="$({ "$CLAUDE" --help 2>/dev/null | grep -aA3 -- '--model <model>' | tr '\n' ' ' | tr -s ' ' | sed 's/.*--model <model> *//'; } 2>/dev/null || true)"
    echo "model  : 'spawn --model <alias|id>' — passed to 'claude --model', validated there. ${mh:-run 'claude --help' for current aliases}"
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
