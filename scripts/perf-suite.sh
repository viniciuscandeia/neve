#!/bin/bash
# AGENT HEADER - scripts/perf-suite.sh
# Role: on-screen performance gate. Runs scripts/perf.sh over a fixed SCENARIOS table (Média/Nevasca x still cursor / --sweep over the piles / sweep over empty space with
# pointer push off) and exits 1 if a budget breaks. Report: build/perf-report.md (markdown table); per-run logs in build/perf-logs/.
# Usage: scripts/perf-suite.sh [--quick]. Env: SECS (30), RUNS (2), MAX_CPU (10 % of one core; the Nevasca sweep row has its own 11), MAX_HITCH (5 ms/s), MAX_MEM (150 MB), NEVE_LOCK_TIMEOUT.
# Scenario row format: "title|perf.sh args|awk check on fps/cpu/base|why[| cpu limit]"; the check compares against BASE = fps of the first scenario. perf.sh prints a
#   `SUMMARY k=v ...` line that this script parses via eval (keys cpu fps step flakesim gpu hitch power wspower memMB ws idlew).
# Side effects: builds its own dev bundle (NEVE_DEV=perf-<hash>), moves the REAL cursor and opens/hides Finder windows (done inside perf.sh, restored on exit), holds the screen lock
#   (~10 min; leave the Mac alone). Never touches the user's Neve (dev bundle + dev defaults suite). Never run it concurrently with other screen work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS=${SECS:-30}; RUNS=${RUNS:-2}; MAX_CPU=${MAX_CPU:-10}; MAX_HITCH=${MAX_HITCH:-5}; MAX_MEM=${MAX_MEM:-150}
[ "${1:-}" = --quick ] && { SECS=15; RUNS=1; }
NAME=perf-$(basename "$ROOT" | shasum | cut -c1-4)
NEVE_DEV=$NAME "$ROOT/scripts/make-app.sh" >&2
BIN="$ROOT/build/Neve-$NAME.app/Contents/MacOS/Neve-dev-$NAME"

# name | perf.sh args | extra check (awk condition on fps / cpu / base = fps of the first scenario; empty = CPU budget only) | what the check means
# Verdict also fails when hitch > MAX_HITCH ms/s (5) or memory > MAX_MEM MB (150: three full-screen drawables plus Metal are ~100 MB).
# Optional 5th field: this scenario's own CPU limit. The Nevasca sweep is a worst case (cursor cutting through the piles nonstop for the whole run;
# the snow it throws up keeps 60 fps), so it gets 11% instead of MAX_CPU.
SCENARIOS=(
  "Média, cursor parado|media --no-figures|fps <= 40|calm snow runs mostly at 30 fps (gusts and spills raise it briefly)"
  "Média, mouse sobre os montes|media --no-figures --sweep --pointer on||"
  "Média, mouse no vazio, empurrão desligado|media --no-figures --sweep --pointer off --segs 300,1100,620|fps <= base + 2|a fast cursor away from any snow does not raise the rate when the push is off"
  "Nevasca, cursor parado|nevasca --no-figures||"
  "Nevasca, mouse sobre os montes|nevasca --no-figures --sweep --pointer on||| 11"
)

REPORT="$ROOT/build/perf-report.md"; FAIL=0; BASE=""
{ echo "# Neve — performance na tela"; echo; echo "$(date '+%Y-%m-%d %H:%M') · $(git -C "$ROOT" log --oneline -1) · $(sysctl -n machdep.cpu.brand_string) · ${SECS}s × ${RUNS} execuções · limite ${MAX_CPU}% de um núcleo"; echo
  echo "| cenário | CPU % | quadros/s | passo ms | flocos ms | GPU ms | WindowServer % | hitch ms/s | energia | energia WS | memória MB | resultado |"; echo "|---|---|---|---|---|---|---|---|---|---|---|---|"; } > "$REPORT"

for s in "${SCENARIOS[@]}"; do
  IFS='|' read -r title args check why lim <<< "$s"; lim=${lim// /}; lim=${lim:-$MAX_CPU}
  echo "== $title" >&2
  # shellcheck disable=SC2086
  segs=""; [[ "$args" == *--segs* ]] && { segs=${args##*--segs }; args=${args% --segs *}; }
  line=$(SWEEP_SEGS="$segs" "$ROOT/scripts/perf.sh" $args "$SECS" --runs "$RUNS" --bin "$BIN" | tee /dev/stderr | grep '^SUMMARY' || true)
  if [ -z "$line" ]; then echo "| $title | — | — | — | — | — | — | — | — | — | — | ✗ sem medição |" >> "$REPORT"; FAIL=1; continue; fi
  eval "$(echo "${line#SUMMARY }" | tr ' ' '\n' | sed 's/^/m_/')"
  verdict="✓"
  awk -v c="$m_cpu" -v m="$lim" 'BEGIN { exit !(c <= m) }' || { verdict="✗ CPU acima de ${lim}%"; FAIL=1; }
  if [ -n "$check" ] && ! awk -v fps="$m_fps" -v cpu="$m_cpu" -v base="${BASE:-$m_fps}" "BEGIN { exit !($check) }"; then verdict="✗ $why ($check)"; FAIL=1; fi
  awk -v h="$m_hitch" -v m="$MAX_HITCH" 'BEGIN { exit !(h <= m) }' || { verdict="$verdict ✗ hitch acima de ${MAX_HITCH} ms/s"; FAIL=1; }
  awk -v h="$m_memMB" -v m="$MAX_MEM" 'BEGIN { exit !(h <= m) }' || { verdict="$verdict ✗ memória acima de ${MAX_MEM} MB"; FAIL=1; }
  [ -z "$BASE" ] && BASE=$m_fps
  [ "$lim" != "$MAX_CPU" ] && verdict="$verdict (limite ${lim}%)"
  echo "| $title | $m_cpu | $m_fps | $m_step | $m_flakesim | $m_gpu | $m_ws | $m_hitch | $m_power | $m_wspower | $m_memMB | $verdict |" >> "$REPORT"
done

echo >> "$REPORT"; echo "CPU: mediana do \`top\` (Neve). Hitch: milissegundos de atraso por segundo em quadros apresentados além de 1,5× o intervalo previsto. Energia: coluna POWER do \`top\` (Energy Impact, estimativa). Memória: footprint no fim da execução (crescimento no SUMMARY como memGrowMB). Quadros e custos: média das linhas do NEVE_PERF após o aquecimento. Bichos, boneco e trenó desligados para a taxa de quadros não depender de sorteio." >> "$REPORT"
cat "$REPORT"
exit $FAIL
