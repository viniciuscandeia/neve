#!/bin/bash
# AGENT HEADER - scripts/agent-run.sh
# Role: run ANY command against a private, disposable Neve instance without touching the user's app.
# Usage: scripts/agent-run.sh [--screen] [--name N] [--defaults k=v ...] -- <command...>
# Flow: NEVE_DEV=$NAME scripts/make-app.sh -> build/Neve-$NAME.app (own bundle id ...neve.dev) -> launch Neve-dev-$NAME in background
#   (env NEVE_INSTANCE=$NAME) -> export NEVE_PID / NEVE_APP / NEVE_DEFAULTS_SUITE (= io.github.viniciuscandeia.neve.dev.$NAME) -> run <command> -> EXIT trap.
# --defaults k=v writes the dev suite via `defaults write` (type inferred: true|false -> -bool, digits -> -int, else -string). Default NAME = 4-char hash of the worktree dir.
# --screen: acquires the shared screen lock (scripts/dev-lock.sh, /tmp/neve-screen.lock, NEVE_LOCK_TIMEOUT s, default 600) + caffeinate -dimsu. Use it for anything
#   that needs the screen (captures, perf): screen-bound work must be idle-gated and one agent at a time.
# Gotchas: the cleanup kills ONLY the pids it launched ($NEVE_PID, caffeinate). NEVER kill/pkill/pgrep Neve by name: it would hit the user's app and other agents.
# Callers: agents/humans directly; README "Vários agentes em paralelo" documents it. Sleeps 2 s after launch and aborts if the app died.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREEN=0; NAME=""; DEFS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --screen) SCREEN=1 ;;
    --name) NAME=$2; shift ;;
    --defaults) DEFS+=("$2"); shift ;;
    --) shift; break ;;
    *) echo "usage: $0 [--screen] [--name N] [--defaults k=v ...] -- <command...>" >&2; exit 2 ;;
  esac
  shift
done
[ $# -gt 0 ] || { echo "agent-run: missing command after --" >&2; exit 2; }
[ -n "$NAME" ] || NAME=$(basename "$ROOT" | shasum | cut -c1-4)
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "agent-run: bad --name '$NAME'" >&2; exit 2; }

source "$ROOT/scripts/dev-lock.sh"
export NEVE_LOCK_PID=$$
NEVE_PID=""; CAFF_PID=""; LOCKED=0
cleanup() {
  set +e
  [ -n "$NEVE_PID" ] && kill "$NEVE_PID" 2>/dev/null
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  [ "$LOCKED" = 1 ] && neve_lock_release "agent-run:$NAME"
}
trap cleanup EXIT

NEVE_DEV=$NAME "$ROOT/scripts/make-app.sh" >&2
export NEVE_APP="$ROOT/build/Neve-$NAME.app"
export NEVE_DEFAULTS_SUITE=io.github.viniciuscandeia.neve.dev.$NAME
for kv in ${DEFS[@]+"${DEFS[@]}"}; do
  k=${kv%%=*}; v=${kv#*=}
  case "$v" in true|false) t=-bool ;; ""|*[!0-9-]*) t=-string ;; *) t=-int ;; esac
  defaults write "$NEVE_DEFAULTS_SUITE" "$k" $t "$v"
done
if [ "$SCREEN" = 1 ]; then
  neve_lock_acquire "agent-run:$NAME" "${NEVE_LOCK_TIMEOUT:-600}"; LOCKED=1
  caffeinate -dimsu & CAFF_PID=$!
fi

NEVE_INSTANCE=$NAME "$NEVE_APP/Contents/MacOS/Neve-dev-$NAME" >/dev/null 2>&1 & NEVE_PID=$!
export NEVE_PID
sleep 2
kill -0 "$NEVE_PID" 2>/dev/null || { echo "agent-run: dev Neve exited early" >&2; NEVE_PID=""; exit 1; }
set +e; "$@"; rc=$?; exit $rc
