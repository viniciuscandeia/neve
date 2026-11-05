#!/bin/bash
# Usage: scripts/perf.sh [heavy|media|max] [secs=60] [--drag] [--runs N=3] [--bin PATH]
# Runs its own dev instance (never touches the user's Neve) under the screen lock. Measures Neve CPU / idle wakeups and WindowServer CPU (top) over N runs. See README "Desenvolvimento".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=media; SECS=60; DRAG=0; RUNS=3; BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    heavy|media|max) MODE=$1 ;;
    --drag) DRAG=1 ;;
    --runs) RUNS=$2; shift ;;
    --bin) BIN=$2; shift ;;
    [0-9]*) SECS=$1 ;;
    *) echo "usage: $0 [heavy|media|max] [secs] [--drag] [--runs N] [--bin PATH]" >&2; exit 2 ;;
  esac
  shift
done

USER_APP=/Users/viniciuscandeia/development/neve/build/Neve.app
NAME=perf-$(basename "$ROOT" | shasum | cut -c1-4)
SUITE=io.github.viniciuscandeia.neve.dev.$NAME
TMP=$(mktemp -d)
WINS=(); NEVE_PID=""; CAFF_PID=""; DRAG_PID=""
source "$ROOT/scripts/dev-lock.sh"
export NEVE_LOCK_PID=$$; LOCKED=0

cleanup() {
  set +e
  [ -n "$DRAG_PID" ] && kill "$DRAG_PID" 2>/dev/null
  [ -n "$NEVE_PID" ] && kill "$NEVE_PID" 2>/dev/null   # only our own pid; never the user's Neve
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  for w in ${WINS[@]+"${WINS[@]}"}; do osascript -e "tell application \"Finder\" to close (window id $w)" 2>/dev/null; done
  defaults delete "$SUITE" 2>/dev/null   # the dev suite is ours alone; the user's domain is never written
  [ "$LOCKED" = 1 ] && neve_lock_release "perf:$NAME"
  rm -rf "$TMP"
}
trap cleanup EXIT

# The screen is shared with other agents: hold the lock for the whole run.
neve_lock_acquire "perf:$NAME" "${NEVE_LOCK_TIMEOUT:-1800}"; LOCKED=1

if [ -z "$BIN" ]; then NEVE_DEV=$NAME "$ROOT/scripts/make-app.sh" >&2; BIN="$ROOT/build/Neve-$NAME.app/Contents/MacOS/Neve-dev-$NAME"; fi

defaults write "$SUITE" intensity -int 1
defaults write "$SUITE" enabled -bool true
defaults write "$SUITE" ambient -bool true   # Modo ambiente: Neve otherwise pauses after 5 min without input, which would measure 0%

# Finder windows (bounds are left, top, right, bottom in top-left-origin points).
open_win() { # l t r b
  osascript -e "tell application \"Finder\"
    set w to make new Finder window to (path to home folder)
    set bounds of w to {$1, $2, $3, $4}
    return id of w
  end tell"
}
if [ "$MODE" = max ]; then
  read -r L T R B < <(osascript -l JavaScript -e 'ObjC.import("AppKit");
    const s=$.NSScreen.screens.objectAtIndex(0), f=s.frame, v=s.visibleFrame;
    [v.origin.x, f.size.height-(v.origin.y+v.size.height), v.origin.x+v.size.width, f.size.height-v.origin.y].map(Math.round).join(" ")')
  WINS+=("$(open_win "$L" "$T" "$R" "$B")")
else
  WINS+=("$(open_win 100 100 700 500)" "$(open_win 760 160 1360 560)")
fi

if [ "$DRAG" = 1 ]; then
  ( while true; do
      osascript -e "tell application \"Finder\" to repeat 90 times
        set b to bounds of window id ${WINS[0]}
        set bounds of window id ${WINS[0]} to {(item 1 of b) + 6, item 2 of b, (item 3 of b) + 6, item 4 of b}
      end repeat" >/dev/null 2>&1 || true
      sleep 7
    done ) & DRAG_PID=$!
fi

ENVV=(NEVE_PERF=1 NEVE_INSTANCE="$NAME")
[ "$MODE" = heavy ] && ENVV+=(NEVE_SCENARIO=heavy)
caffeinate -dimsu -t $(( RUNS * (SECS + 25) + 60 )) & CAFF_PID=$!; disown

if pgrep -f "$USER_APP/Contents/MacOS/" >/dev/null; then
  echo "WARNING: the user's Neve ($USER_APP) is running; WindowServer numbers include it. Not killed."
fi
echo "mode=$MODE secs=$SECS runs=$RUNS drag=$DRAG bin=$BIN"
: > "$TMP/runs"
for r in $(seq 1 "$RUNS"); do
  LOG="$TMP/perf$r.log"
  env "${ENVV[@]}" NEVE_PERF_LOG="$LOG" "$BIN" >/dev/null 2>&1 & NEVE_PID=$!
  sleep 10 # warm-up
  kill -0 "$NEVE_PID" 2>/dev/null || { echo "Neve exited early" >&2; exit 1; }
  # top's first sample is an average since start, so take secs+1 and drop it.
  top -l $((SECS + 1)) -s 1 -stats pid,command,cpu,idlew | awk -v p="$NEVE_PID" '
    function st(x,c,  i,m,t,t2,y){ t=0; for(i=1;i<=c;i++){t+=x[i]; y[i]=x[i]}
      for(i=1;i<=c;i++)for(m=i+1;m<=c;m++)if(y[m]<y[i]){t2=y[i];y[i]=y[m];y[m]=t2}
      return sprintf("%.2f %.2f", c?t/c:0, c?((c%2)?y[(c+1)/2]:(y[c/2]+y[c/2+1])/2):0) }
    $1=="PID" {s++; next}
    s>=2 && $1==p {n[++a]=$3; w[a]=$4}
    s>=2 && $2=="WindowServer" {ws[++b]=$3}
    END { print st(n,a), st(w,a), st(ws,b) }' >> "$TMP/runs"
  echo "run $r: $(tail -1 "$TMP/runs")  (neve cpu mean/med, idlew mean/med, WS cpu mean/med)"
  if [ -s "$LOG" ]; then echo "  perf log:"; tail -n 3 "$LOG" | sed 's/^/    /'; else echo "  (no NEVE_PERF_LOG output)"; fi
  kill "$NEVE_PID" 2>/dev/null || true; wait "$NEVE_PID" 2>/dev/null || true; NEVE_PID=""
  sleep 1
done

awk 'function med(i,  j,k,t,y){ for(j=1;j<=N;j++)y[j]=v[i,j]
      for(j=1;j<=N;j++)for(k=j+1;k<=N;k++)if(y[k]<y[j]){t=y[j];y[j]=y[k];y[k]=t}
      return (N%2)?y[(N+1)/2]:(y[N/2]+y[N/2+1])/2 }
  function sd(i,  j,m,s){ m=0; s=0; for(j=1;j<=N;j++)m+=v[i,j]; m/=N; for(j=1;j<=N;j++)s+=(v[i,j]-m)^2; return sqrt(s/N) }
  { for(i=1;i<=6;i++) v[i,NR]=$i; N=NR }
  END { printf "\n%-24s %10s %10s\n","metric","median","stddev"
    split("Neve_CPU%_mean Neve_CPU%_median Neve_idlew_mean Neve_idlew_median WS_CPU%_mean WS_CPU%_median",nm," ")
    for(i=1;i<=6;i++) printf "%-24s %10.2f %10.2f\n",nm[i],med(i),sd(i) }' "$TMP/runs"
