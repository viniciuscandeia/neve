#!/bin/bash
# On-screen performance check: runs scripts/perf.sh over a fixed set of scenarios on the real screen and fails (exit 1) when a budget is broken.
# Usage: scripts/perf-suite.sh [--quick]     env: SECS (30), RUNS (2), MAX_CPU (10 = % of one core), NEVE_LOCK_TIMEOUT
# Moves the cursor during the --sweep scenarios (put back after each run) and opens two Finder windows: leave the Mac alone while it runs (~10 min).
# Report: build/perf-report.md. Never touches the user's Neve (own dev bundle and defaults suite).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS=${SECS:-30}; RUNS=${RUNS:-2}; MAX_CPU=${MAX_CPU:-10}
[ "${1:-}" = --quick ] && { SECS=15; RUNS=1; }
NAME=perf-$(basename "$ROOT" | shasum | cut -c1-4)
NEVE_DEV=$NAME "$ROOT/scripts/make-app.sh" >&2
BIN="$ROOT/build/Neve-$NAME.app/Contents/MacOS/Neve-dev-$NAME"

# name | perf.sh args | extra check (awk condition on fps / cpu / base = fps of the first scenario; empty = CPU budget only) | what the check means
SCENARIOS=(
  "Média, cursor parado|media --no-figures|fps <= 40|calm snow runs mostly at 30 fps (gusts and spills raise it briefly)"
  "Média, mouse sobre os montes|media --no-figures --sweep --pointer on||"
  "Média, mouse no vazio, empurrão desligado|media --no-figures --sweep --pointer off --segs 300,1100,620|fps <= base + 2|a fast cursor away from any snow does not raise the rate when the push is off"
  "Nevasca, cursor parado|nevasca --no-figures||"
  "Nevasca, mouse sobre os montes|nevasca --no-figures --sweep --pointer on||"
)

REPORT="$ROOT/build/perf-report.md"; FAIL=0; BASE=""
{ echo "# Neve — performance na tela"; echo; echo "$(date '+%Y-%m-%d %H:%M') · $(git -C "$ROOT" log --oneline -1) · $(sysctl -n machdep.cpu.brand_string) · ${SECS}s × ${RUNS} execuções · limite ${MAX_CPU}% de um núcleo"; echo
  echo "| cenário | CPU % | quadros/s | passo ms | flocos ms | GPU ms | WindowServer % | resultado |"; echo "|---|---|---|---|---|---|---|---|"; } > "$REPORT"

for s in "${SCENARIOS[@]}"; do
  IFS='|' read -r title args check why <<< "$s"
  echo "== $title" >&2
  # shellcheck disable=SC2086
  segs=""; [[ "$args" == *--segs* ]] && { segs=${args##*--segs }; args=${args% --segs *}; }
  line=$(SWEEP_SEGS="$segs" "$ROOT/scripts/perf.sh" $args "$SECS" --runs "$RUNS" --bin "$BIN" | tee /dev/stderr | grep '^SUMMARY' || true)
  if [ -z "$line" ]; then echo "| $title | — | — | — | — | — | — | ✗ sem medição |" >> "$REPORT"; FAIL=1; continue; fi
  eval "$(echo "${line#SUMMARY }" | tr ' ' '\n' | sed 's/^/m_/')"
  verdict="✓"
  awk -v c="$m_cpu" -v m="$MAX_CPU" 'BEGIN { exit !(c <= m) }' || { verdict="✗ CPU acima de ${MAX_CPU}%"; FAIL=1; }
  if [ -n "$check" ] && ! awk -v fps="$m_fps" -v cpu="$m_cpu" -v base="${BASE:-$m_fps}" "BEGIN { exit !($check) }"; then verdict="✗ $why ($check)"; FAIL=1; fi
  [ -z "$BASE" ] && BASE=$m_fps
  echo "| $title | $m_cpu | $m_fps | $m_step | $m_flakesim | $m_gpu | $m_ws | $verdict |" >> "$REPORT"
done

echo >> "$REPORT"; echo "CPU: mediana do \`top\` (Neve). Quadros e custos: média das linhas do NEVE_PERF após o aquecimento. Bichos, boneco e trenó desligados para a taxa de quadros não depender de sorteio." >> "$REPORT"
cat "$REPORT"
exit $FAIL
