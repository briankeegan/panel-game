#!/usr/bin/env bash
# Start or stop the two-bot fight on the Bramp server: one GitHub Actions run per
# bot, each on its own runner (see bot/fight.sh, bot-prod-smoke-test.yml).
#
#   bot/pair.sh start [HOURS]   BitBot sits in the lobby; WasmSurvivor_Bot challenges it
#   bot/pair.sh stop            cancel every fight run that is going
#   bot/pair.sh status          list the fight runs that are going
#
# Needs the GitHub CLI (gh), logged in with access to the repo. Restart ONE bot
# by cancelling just its run and dispatching just it again: the challenger keeps
# challenging, so the other side does not need to restart.
#   bot/pair.sh start-bitbot [HOURS]     only BitBot
#   bot/pair.sh start-wasm   [HOURS]     only WasmSurvivor_Bot (challenging BitBot)
#
# Each run checks out GameCreator's main when it STARTS, so it is only as new as that.
set -eu

REPO=${PA_REPO:-briankeegan/panel-game}
REF=${PA_REF:-bramp/multi-player}
WORKFLOW=bot-prod-smoke-test.yml
SERVER=${PA_SERVER:-104.156.250.136:49569}
PROFILE=${PA_WASM_PROFILE:-bot/profiles/wasmbot.wasm.json}
HOURS=${2:-5}

start_bitbot() {
  gh workflow run "$WORKFLOW" -R "$REPO" --ref "$REF" \
    -f mode=fight -f bot=bitbot -f opponent=you -f name=BitBot -f hours="$HOURS" -f server="$SERVER"
  echo "pair: BitBot queued (sits in the lobby)"
}
start_wasm() {
  gh workflow run "$WORKFLOW" -R "$REPO" --ref "$REF" \
    -f mode=fight -f bot=wasm -f opponent=challenge -f name=WasmSurvivor_Bot,BitBot \
    -f hours="$HOURS" -f profile="$PROFILE" -f server="$SERVER"
  echo "pair: WasmSurvivor_Bot queued (challenges BitBot)"
}
running() {
  gh run list -R "$REPO" --workflow "$WORKFLOW" --status in_progress --json databaseId,displayTitle \
    --jq '.[] | "\(.databaseId)\t\(.displayTitle)"'
}

case "${1:-}" in
  start)         start_bitbot; sleep 2; start_wasm ;;
  start-bitbot)  start_bitbot ;;
  start-wasm)    start_wasm ;;
  status)        running ;;
  stop)
    ids=$(running | cut -f1)
    [ -n "$ids" ] || { echo "pair: nothing running"; exit 0; }
    for id in $ids; do gh run cancel -R "$REPO" "$id" && echo "pair: cancelled $id"; done
    echo "pair: a cancelled run takes about a minute to let go of its account -- wait before starting again"
    ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
