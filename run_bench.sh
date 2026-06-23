#!/usr/bin/env zsh
# run_bench.sh — THE STANDARD bot benchmark. Always run it the same way:
#   - all 4 scenarios (endless / large-garbage / factor / combo-storm) in PARALLEL, one process each (~4x faster).
#   - each played until the bot DIES: a high frame cap, and the rise speed ramps up over a long game, so nothing
#     survives forever -> the reported time is a real death time, not an artificial cap.
#   - full-speed bot (cursorMoveInterval=1) so we measure the HARD ceiling.
# Reports median survival time + score + garbage broke/sent + biggest clear + peak chain per scenario.
#   usage: zsh run_bench.sh [maxFrames]      # default 18000 (~5 min game-time; plenty for death)
cd "${0:A:h}"
eval "$(luarocks path --local --lua-version 5.1)" 2>/dev/null
MAXF=${1:-18000}
echo "=== BOT BENCH — 4 scenarios in parallel, run until death, maxFrames=$MAXF ==="
for S in endless large-garbage factor combo-storm; do
  PA_BEAM_D=1 luajit bot/botBench.lua 1 "$MAXF" "$S" 2>/dev/null | grep -vE "DEBUG|WARN" | grep -E "###|MEDIAN" > "/tmp/bench_$S.txt" &
done
wait
for S in endless large-garbage factor combo-storm; do cat "/tmp/bench_$S.txt"; done
