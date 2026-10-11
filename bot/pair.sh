#!/usr/bin/env bash
# Start, restart or stop the two-bot fight on the Bramp server: one GitHub Actions
# run per bot, each on its own runner (see bot/fight.sh, bot-prod-smoke-test.yml).
#
#   bot/pair.sh start [HOURS]         cancel any fight runs going, then start both:
#                                     BitBot sits in the lobby, WasmSurvivor_Bot challenges it
#   bot/pair.sh start-bitbot [HOURS]  cancel BitBot's run if going, start only BitBot
#   bot/pair.sh start-wasm [HOURS]    cancel WasmSurvivor_Bot's run if going, start only it
#   bot/pair.sh stop                  cancel every fight run that is going
#   bot/pair.sh status                list the fight runs that are going
#
# A start always cancels the run it replaces first, then waits for the cancelled run
# to let go of its account (the server keeps a name held until it does).
# Restart ONE bot with start-bitbot / start-wasm: the challenger keeps challenging,
# so the other side does not need to restart.
#
# Needs the GitHub CLI (gh), logged in with access to the repo.
# Each run checks out GameCreator's main when it STARTS, so it is only as new as that.
set -eu

REPO=${PA_REPO:-briankeegan/panel-game}
REF=${PA_REF:-bramp/multi-player}
WORKFLOW=bot-prod-smoke-test.yml
SERVER=${PA_SERVER:-104.156.250.136:49569}
PROFILE=${PA_WASM_PROFILE:-bot/profiles/wasmbot.wasm.json}
RELEASE_WAIT=${PA_RELEASE_WAIT:-70}
HOURS=${2:-5}

# every fight run going, one "id<TAB>title" per line
running() {
  gh run list -R "$REPO" --workflow "$WORKFLOW" --status in_progress --json databaseId,displayTitle \
    --jq '.[] | "\(.databaseId)\t\(.displayTitle)"'
}

# cancel the runs whose title matches PATTERN (default: all); say how many
cancel_matching() {
  local pattern=${1:-.} n=0 id title
  while IFS=$'\t' read -r id title; do
    [ -n "$id" ] || continue
    printf '%s' "$title" | grep -q -E -- "$pattern" || continue
    gh run cancel -R "$REPO" "$id" && echo "pair: cancelled $id  ($title)"
    n=$((n + 1))
  done < <(running)
  echo "$n"
}

stop_and_wait() {   # PATTERN
  local out n
  out=$(cancel_matching "$1")
  printf '%s\n' "$out" | sed '$d'
  n=$(printf '%s\n' "$out" | tail -1)
  if [ "$n" -gt 0 ]; then
    echo "pair: waiting ${RELEASE_WAIT}s for the cancelled run(s) to let go of their accounts"
    sleep "$RELEASE_WAIT"
  fi
}

dispatch_bitbot() {
  gh workflow run "$WORKFLOW" -R "$REPO" --ref "$REF" \
    -f mode=fight -f bot=bitbot -f opponent=you -f name=BitBot -f hours="$HOURS" -f server="$SERVER"
  echo "pair: BitBot queued (sits in the lobby)"
}
dispatch_wasm() {
  gh workflow run "$WORKFLOW" -R "$REPO" --ref "$REF" \
    -f mode=fight -f bot=wasm -f opponent=challenge -f name=WasmSurvivor_Bot,BitBot \
    -f hours="$HOURS" -f profile="$PROFILE" -f server="$SERVER"
  echo "pair: WasmSurvivor_Bot queued (challenges BitBot)"
}

BITBOT_RUN='BitBot \(bitbot\)'
WASM_RUN='\(wasm\) vs challenge'

case "${1:-}" in
  start)        stop_and_wait .;          dispatch_bitbot; sleep 2; dispatch_wasm ;;
  start-bitbot) stop_and_wait "$BITBOT_RUN"; dispatch_bitbot ;;
  start-wasm)   stop_and_wait "$WASM_RUN";   dispatch_wasm ;;
  stop)         out=$(cancel_matching .); printf '%s\n' "$out" | sed '$d'
                [ "$(printf '%s\n' "$out" | tail -1)" -gt 0 ] || echo "pair: nothing running" ;;
  status)       running ;;
  *)            sed -n '2,19p' "$0"; exit 2 ;;
esac
