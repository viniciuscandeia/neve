#!/bin/bash
# AGENT HEADER - scripts/perf.sh
# Role: measure Neve CPU / idle wakeups / memory and WindowServer CPU on the real screen for one scenario, N runs, medians; building block of scripts/perf-suite.sh.
# Usage: scripts/perf.sh [heavy|media|nevasca|max|still] [secs=60] [--drag] [--sweep] [--fake] [--pointer on|off] [--no-figures] [--keep-windows] [--capture] [--runs N=3] [--bin PATH]
#   (env: SWEEP_SEGS="x0,x1,y ..." overrides the cursor segments (CG top-left coords), ADAPTIVE=true|false A/B for adaptiveFps, NEVE_LOCK_TIMEOUT).
# Flow: own dev bundle (NEVE_DEV=perf-<hash>) or --bin; writes the dev defaults suite io.github.viniciuscandeia.neve.dev.<name> (intensity, pointerPush, enabled, ambient=true so the 5-min
#   idle pause does not read 0 %, visitors/snowman/sleigh/walk=false for --no-figures, stillSnow, showInCaptures); hides other apps and minimises Finder windows via osascript (restored in
#   the EXIT trap unless --keep-windows); opens 1-2 Finder windows (bounds are top-left-origin pt); optional --drag (window dragger loop) and --sweep (build/cursor-sweep from
#   scripts/cursor-sweep.swift moves the real cursor); samples `top -l N` (drops the first sample), footprint for memory; app-side numbers come from NEVE_PERF=1 + NEVE_PERF_LOG
#   ([screen ...] lines: ticks/s, step, flakesim, gpu, hitch; see Sources/Neve/Perf.swift). Last output line: SUMMARY key=value ...
# --fake (with --sweep): no real cursor; passes NEVE_FAKE_POINTER=sweep (or $SWEEP_SEGS) so Sources/Neve/FakePointer.swift walks the same path in-app (no idle gate needed for the cursor, still needs it for the screen).
# Env passed to the app: NEVE_PERF=1, NEVE_INSTANCE, NEVE_PERF_LOG, NEVE_SCENARIO=heavy, NEVE_REDUCE_MOTION=1 (still mode).
# Side effects: holds the screen lock for the whole run, caffeinate, kills ONLY its own pids (NEVE_PID, sweep, dragger) - NEVER kill Neve by name (the user's app may run; it only warns).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKE=0; MODE=media; SECS=60; DRAG=0; SWEEP=0; POINTER=""; NOFIG=0; KEEP=0; RUNS=3; BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    heavy|media|nevasca|max|still) MODE=$1 ;;
    --drag) DRAG=1 ;;
    --sweep) SWEEP=1 ;;
    --fake) FAKE=1 ;;   # with --sweep: scripted in-app pointer (NEVE_FAKE_POINTER) instead of moving the real cursor
    --pointer) POINTER=$2; shift ;;
    --no-figures) NOFIG=1 ;;
    --keep-windows) KEEP=1 ;;
    --capture) CAPTURE=1 ;;   # snow visible to screencapture (for visual checks)
    --runs) RUNS=$2; shift ;;
    --bin) BIN=$2; shift ;;
    [0-9]*) SECS=$1 ;;
    *) echo "usage: $0 [heavy|media|nevasca|max|still] [secs] [--drag] [--sweep] [--fake] [--pointer on|off] [--no-figures] [--keep-windows] [--capture] [--runs N] [--bin PATH]" >&2; exit 2 ;;
  esac
  shift
done

NAME=perf-$(basename "$ROOT" | shasum | cut -c1-4)
SUITE=io.github.viniciuscandeia.neve.dev.$NAME
TMP=$(mktemp -d)
WINS=(); NEVE_PID=""; CAFF_PID=""; DRAG_PID=""; SWEEP_PID=""; HIDDEN=(); MINI=()
source "$ROOT/scripts/dev-lock.sh"
export NEVE_LOCK_PID=$$; LOCKED=0

cleanup() {
  set +e
  [ -n "$DRAG_PID" ] && kill "$DRAG_PID" 2>/dev/null
  [ -n "$SWEEP_PID" ] && kill "$SWEEP_PID" 2>/dev/null   # SIGTERM skips its restore: the cursor stays where it was
  [ -n "$NEVE_PID" ] && kill "$NEVE_PID" 2>/dev/null   # only our own pid; never the user's Neve
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  for w in ${WINS[@]+"${WINS[@]}"}; do osascript -e "tell application \"Finder\" to close (window id $w)" 2>/dev/null; done
  for w in ${MINI[@]+"${MINI[@]}"}; do osascript -e "tell application \"Finder\" to set collapsed of window id $w to false" 2>/dev/null; done
  for a in ${HIDDEN[@]+"${HIDDEN[@]}"}; do osascript -e "tell application \"System Events\" to set visible of application process \"$a\" to true" >/dev/null 2>&1; done
  defaults delete "$SUITE" 2>/dev/null   # the dev suite is ours alone; the user's domain is never written
  [ "$LOCKED" = 1 ] && neve_lock_release "perf:$NAME"
  rm -rf "$TMP"
}
trap cleanup EXIT

# The screen is shared with other agents: hold the lock for the whole run.
neve_lock_acquire "perf:$NAME" "${NEVE_LOCK_TIMEOUT:-1800}"; LOCKED=1

if [ -z "$BIN" ]; then NEVE_DEV=$NAME "$ROOT/scripts/make-app.sh" >&2; BIN="$ROOT/build/Neve-$NAME.app/Contents/MacOS/Neve-dev-$NAME"; fi

defaults write "$SUITE" intensity -int "$([ "$MODE" = nevasca ] && echo 3 || echo 1)"
case "$POINTER" in on) defaults write "$SUITE" pointerPush -bool true ;; off) defaults write "$SUITE" pointerPush -bool false ;; "") ;; *) echo "--pointer on|off" >&2; exit 2 ;; esac
[ "$NOFIG" = 1 ] && for k in visitors snowman sleigh walk; do defaults write "$SUITE" "$k" -bool false; done
defaults write "$SUITE" enabled -bool true
[ "${CAPTURE:-0}" = 1 ] && defaults write "$SUITE" showInCaptures -bool true
[ -n "${ADAPTIVE:-}" ] && defaults write "$SUITE" adaptiveFps -bool "$ADAPTIVE"   # A/B for the adaptive frame rate (ADAPTIVE=true|false)
[ "$MODE" = still ] && defaults write "$SUITE" stillSnow -bool true
defaults write "$SUITE" ambient -bool true   # Modo ambiente: Neve otherwise pauses after 5 min without input, which would measure 0%

# Only the test windows on screen: hide the other apps, minimise the user's Finder windows (both put back by cleanup).
if [ "$KEEP" = 0 ]; then
  while IFS= read -r a; do [ -n "$a" ] && HIDDEN+=("$a"); done < <(osascript -e 'tell application "System Events"
    set out to ""
    repeat with p in (every application process whose visible is true and background only is false and name is not "Finder")
      set out to out & name of p & linefeed
    end repeat
    return out
  end tell')
  for a in ${HIDDEN[@]+"${HIDDEN[@]}"}; do osascript -e "tell application \"System Events\" to set visible of application process \"$a\" to false" >/dev/null; done
  while IFS= read -r w; do [ -n "$w" ] && MINI+=("$w"); done < <(osascript -e 'tell application "Finder"
    set out to ""
    repeat with w in (every Finder window whose collapsed is false)
      set out to out & (id of w as text) & linefeed
    end repeat
    return out
  end tell')
  for w in ${MINI[@]+"${MINI[@]}"}; do osascript -e "tell application \"Finder\" to set collapsed of window id $w to true" >/dev/null; done
  echo "hidden apps: ${HIDDEN[*]:-none}; minimised Finder windows: ${#MINI[@]}"
fi

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

SWEEP_BIN=""
if [ "$SWEEP" = 1 ]; then
  SWEEP_BIN="$ROOT/build/cursor-sweep"
  [ "$SWEEP_BIN" -nt "$ROOT/scripts/cursor-sweep.swift" ] || swiftc -O "$ROOT/scripts/cursor-sweep.swift" -o "$SWEEP_BIN"
  SCREEN_H=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); Math.round($.NSScreen.screens.objectAtIndex(0).frame.size.height)')
  # Window tops (Finder bounds top) and the ground, in CG coordinates.
  if [ "$MODE" = max ]; then SEGS=("$((L + 40)),$((R - 40)),$T" "120,$((R - 120)),$SCREEN_H")
  else SEGS=("130,670,100" "790,1330,160" "120,1320,$SCREEN_H"); fi
  [ -n "${SWEEP_SEGS:-}" ] && read -r -a SEGS <<< "$SWEEP_SEGS"   # override: "x0,x1,y x0,x1,y ..."
fi

ENVV=(NEVE_PERF=1 NEVE_INSTANCE="$NAME")
[ "$FAKE" = 1 ] && [ "$SWEEP" = 1 ] && { ENVV+=(NEVE_FAKE_POINTER="${SWEEP_SEGS:-sweep}"); SWEEP_BIN=""; }
[ "$MODE" = heavy ] && ENVV+=(NEVE_SCENARIO=heavy)
[ "$MODE" = still ] && ENVV+=(NEVE_REDUCE_MOTION=1)   # still mode = Reduce Motion + Neve parada
caffeinate -dimsu -t $(( RUNS * (SECS + 25) + 60 )) & CAFF_PID=$!; disown

# Any installed / release Neve (executable "Neve"); our dev bundle runs as Neve-dev-<name>, and a --bin build has no bundle path.
if pgrep -f "/Contents/MacOS/Neve( |$)" >/dev/null; then
  echo "WARNING: another Neve.app is running; WindowServer numbers include it. Not killed."
fi
echo "mode=$MODE secs=$SECS runs=$RUNS drag=$DRAG sweep=$SWEEP pointer=${POINTER:-default} nofig=$NOFIG bin=$BIN"
: > "$TMP/runs"; : > "$TMP/app"; : > "$TMP/mem"; : > "$TMP/fast"
# Memory footprint in MB (footprint if available, else RSS from ps).
memmb() { local m; m=$(footprint "$1" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i < NF; i++) if ($i == "Footprint:") { v = $(i+1); u = $(i+2); print (u == "KB" ? v/1024 : u == "GB" ? v*1024 : u == "B" ? v/1048576 : v); exit } }')
  [ -n "$m" ] || m=$(ps -o rss= -p "$1" | awk '{ print $1 / 1024 }'); echo "${m:-0}"; }
for r in $(seq 1 "$RUNS"); do
  mkdir -p "$ROOT/build/perf-logs"; LOG="$ROOT/build/perf-logs/$MODE$([ "$SWEEP" = 1 ] && echo -sweep || true)${POINTER:+-pointer-$POINTER}-run$r.log"; : > "$LOG"   # kept for inspection
  env "${ENVV[@]}" NEVE_PERF_LOG="$LOG" "$BIN" >/dev/null 2>&1 & NEVE_PID=$!
  sleep 10 # warm-up
  kill -0 "$NEVE_PID" 2>/dev/null || { echo "Neve exited early" >&2; exit 1; }
  [ -n "$SWEEP_BIN" ] && { "$SWEEP_BIN" "$((SECS + 2))" "${SEGS[@]}" & SWEEP_PID=$!; }
  MEM0=$(memmb "$NEVE_PID")
  # top's first sample is an average since start, so take secs+1 and drop it.
  top -l $((SECS + 1)) -s 1 -stats pid,command,cpu,idlew,power | awk -v p="$NEVE_PID" '
    function st(x,c,  i,m,t,t2,y){ t=0; for(i=1;i<=c;i++){t+=x[i]; y[i]=x[i]}
      for(i=1;i<=c;i++)for(m=i+1;m<=c;m++)if(y[m]<y[i]){t2=y[i];y[i]=y[m];y[m]=t2}
      return sprintf("%.2f %.2f", c?t/c:0, c?((c%2)?y[(c+1)/2]:(y[c/2]+y[c/2+1])/2):0) }
    function mn(x,c,  i,t){ t=0; for(i=1;i<=c;i++)t+=x[i]; return sprintf("%.2f", c?t/c:0) }
    $1=="PID" {s++; next}
    s>=2 && $1==p {n[++a]=$3; w[a]=$4; pw[a]=$5}
    s>=2 && $2=="WindowServer" {ws[++b]=$3; wp[b]=$5}
    END { print st(n,a), st(w,a), st(ws,b), mn(pw,a), mn(wp,b) }' >> "$TMP/runs"
  MEM1=$(memmb "$NEVE_PID")
  echo "$MEM1 $MEM0" | awk '{ printf "%.1f %.1f\n", $1, $1 - $2 }' >> "$TMP/mem"
  echo "run $r: $(tail -1 "$TMP/runs")  (neve cpu mean/med, idlew mean/med, WS cpu mean/med, neve power, WS power); mem $(tail -1 "$TMP/mem") MB (end, growth)"
  [ -n "$SWEEP_PID" ] && { wait "$SWEEP_PID" 2>/dev/null || true; SWEEP_PID=""; }
  # Frame rate and in-app costs over the measured part (lines after warm-up), averaged.
  awk '/^\[screen/ { n++; for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "ticks/s") f += kv[2]; if (kv[1] == "hitch") h += kv[2]; if (kv[1] == "step") { sub("/f.*", "", kv[2]); st += kv[2] }
       if (kv[1] == "flakesim") { sub("ms.*", "", kv[2]); fs += kv[2] }; if (kv[1] == "gpu") { sub("ms.*", "", kv[2]); g += kv[2] } } }
       END { if (n) printf "%.1f %.3f %.3f %.3f %.2f\n", f / n, st / n, fs / n, g / n, h / n; else print "0 0 0 0 0" }' <(tail -n +3 "$LOG" 2>/dev/null) >> "$TMP/app"
  # frames/s where the cursor itself asked for 60 fps (`fast=` count of the [screen] lines, 5 s windows): isolates the cursor from busy bursts (avalanches, spills) that also raise the rate
  awk '/^\[screen/ { n++; for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "fast") s += kv[2] } } END { printf "%.2f\n", n ? s / (5 * n) : 0 }' <(tail -n +3 "$LOG" 2>/dev/null) >> "$TMP/fast"
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

# One machine-readable line: medians over runs.
paste -d' ' "$TMP/runs" "$TMP/app" "$TMP/mem" "$TMP/fast" | awk 'function med(i,  j,k,t,y){ for(j=1;j<=N;j++)y[j]=v[i,j]
    for(j=1;j<=N;j++)for(k=j+1;k<=N;k++)if(y[k]<y[j]){t=y[j];y[j]=y[k];y[k]=t}
    return (N%2)?y[(N+1)/2]:(y[N/2]+y[N/2+1])/2 }
  { for(i=1;i<=16;i++) v[i,NR]=$i; N=NR }
  END { printf "SUMMARY cpu=%.2f idlew=%.1f ws=%.2f fps=%.1f step=%.3f flakesim=%.3f gpu=%.3f hitch=%.2f power=%.1f wspower=%.1f memMB=%.1f memGrowMB=%.1f fastps=%.2f\n", med(2), med(4), med(6), med(9), med(10), med(11), med(12), med(13), med(7), med(8), med(14), med(15), med(16) }'
