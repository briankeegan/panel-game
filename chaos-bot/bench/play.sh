#!/usr/bin/env bash
# ONE GAME of the chaos bot in the real chaos v3 client, headless (GitHub Actions only: plans/chaos-goal.md §1.2).
#   chaos-bot/bench/play.sh PATTERN SEED GLEVEL GSPEED QUEUE FRAMES OUT_DIR
# Needs: LOVE (a LÖVE 12 AppImage), xvfb-run, clang. Builds libgambit.so on this machine, fetches the pinned v3 build, lays the
# launcher (client/chaosbot) into the extracted game -- never into the repo -- and plays until FRAMES frames of play or the loss.
# Writes OUT_DIR/result.txt (one RESULT line of data), OUT_DIR/gambit.log (Gambit's own log), OUT_DIR/client.log.
set -euo pipefail
pattern=$1 seed=$2 glevel=$3 gspeed=$4 queue=$5 frames=$6 out=$7
here="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${GITHUB_ACTIONS:-}" ] || { echo "play.sh: games run on GitHub Actions only"; exit 2; }
mkdir -p "$out"
work="$(mktemp -d)"

# the bot, built on this machine (its CPU), on the chaos engine
gd="$work/gambit"
mkdir -p "$gd/lua"
(cd "$here/gambit" && clang -O3 -march=native -pthread -fPIC -shared -Wl,-z,nodelete -DPA_HEAP -w native.c host.c -lm -o "$gd/libgambit.so")
cp "$here/gambit/lua/GambitNative.lua" "$here/gambit/lua/board.lua" "$gd/lua/"
cp "$here/profiles/${CHAOSBOT_PROFILE:-chaos}.words" "$gd/gambit.words"   # (profiles/<name>.words: chaos by default)

# the game, pinned, with the launcher laid in
"$here/game/fetch.sh" "$work/build" > /dev/null
game="$work/build/game"
cp -r "$here/client/chaosbot" "$game/chaosbot"
cp "$here/client/chaosbot/InputBudget.lua" "$here/client/chaosbot/ThinkBudget.lua" "$game/chaosbot/"
printf '\nrequire("chaosbot.boot")\n' >> "$game/main.lua"
# GambitNative finds the budgets as bot.<name> when the engine has none of its own
mkdir -p "$game/bot" && cp "$here/client/chaosbot/InputBudget.lua" "$here/client/chaosbot/ThinkBudget.lua" "$game/bot/"

export GC_GAMBIT_DIR="$gd" GC_GAMBIT_WORDS="$gd/gambit.words" GC_GAMBIT_LOG="$out/gambit.log"
# (run 295: TWO SEARCH WORKERS -- Gambit's searches run on its own thread alone unless GC_GAMBIT_WORKERS names workers (host.c
# hostWorkers), and no run set it: the runners have 4 cpus, the game's thread and Gambit's take two. Each decision gets the same wall-clock
# time, so the workers are more search in it -- the owner's runner data: a slower model searches less and loses more)
export GC_GAMBIT_WORKERS="${GC_GAMBIT_WORKERS:-2}"
# (run 301: THE MACHINE LAID OUT AS THE VANILLA BOT'S IS -- GameCreator eval/training.sh, the build that holds every vanilla mode at 28/28:
# the client on CPU 0 with one software-render thread (LP_NUM_THREADS: llvmpipe otherwise spreads its drawing over every core), Gambit's
# own thread alone on a CPU of the other core, its workers on the CPUs left (at the idle class, host.c, they take only what is spare).
# A runner's four CPUs are two cores (/sys topology core_id); run 297 pinned without reading the cores and without holding the client)
NCPU=$(nproc); CLIENT_CPU=0; GAMBIT_CPU=; WORKER_CPUS=
core() { cat "/sys/devices/system/cpu/cpu$1/topology/core_id" 2>/dev/null || echo "$1"; }
if [ "$NCPU" -ge 2 ]; then
  for c in $(seq 1 $(( NCPU - 1 ))); do
    if [ -z "$GAMBIT_CPU" ] && [ "$(core "$c")" != "$(core "$CLIENT_CPU")" ]; then GAMBIT_CPU=$c; else WORKER_CPUS=${WORKER_CPUS:+$WORKER_CPUS,}$c; fi
  done
  [ -z "$GAMBIT_CPU" ] && GAMBIT_CPU="1-$(( NCPU - 1 ))"
  export GC_GAMBIT_CPUS="${GC_GAMBIT_CPUS:-$GAMBIT_CPU}" GC_GAMBIT_WORKER_CPUS="${GC_GAMBIT_WORKER_CPUS:-${WORKER_CPUS:-$GAMBIT_CPU}}" LP_NUM_THREADS="${LP_NUM_THREADS:-1}"
  PIN="taskset -c $CLIENT_CPU"
  echo "play.sh: the client on CPU $CLIENT_CPU, Gambit on $GC_GAMBIT_CPUS, its workers on $GC_GAMBIT_WORKER_CPUS (cores: $(for c in $(seq 0 $(( NCPU - 1 ))); do printf '%s:%s ' "$c" "$(core "$c")"; done))" > "$out/cpus.txt"
else
  PIN=
fi
export CHAOSBOT_SEED="$seed" CHAOSBOT_PATTERN="$pattern" CHAOSBOT_GLEVEL="$glevel" CHAOSBOT_GSPEED="$gspeed" CHAOSBOT_QUEUE="$queue"
export CHAOSBOT_FRAMES="$frames" CHAOSBOT_OUT="$out/result.txt" CHAOSBOT_LEVEL="${CHAOSBOT_LEVEL:-9}"
# a game of FRAMES frames at 60 a second, plus the client's boot, plus room for frames the runner falls behind on
limit=$(( frames / 60 + 240 ))
set +e
APPIMAGE_EXTRACT_AND_RUN=1 timeout "$limit" xvfb-run -a -s "-screen 0 1280x720x24" $PIN "$LOVE" "$game" > "$out/client.log" 2>&1
code=$?
set -e
grep '^CHAOSBOT ' "$out/client.log" || true
if [ ! -s "$out/result.txt" ]; then
  echo "RESULT seed $seed pattern $pattern glevel $glevel gspeed $gspeed queue $queue survived 0 frames -1 reason crash exit $code" > "$out/result.txt"
  tail -40 "$out/client.log"
fi
cat "$out/result.txt"
