#!/usr/bin/env bash
# Start, restart or stop the two-bot fight on the Bramp server: one GitHub Actions
# run per bot, each on its own runner (see bot/fight.sh, bot-prod-smoke-test.yml).
#
#   bot/pair.sh start [HOURS]         cancel any fight runs going, then start both:
#                                     BitBot sits in the lobby, WasmSurvivor_Bot challenges it
#   bot/pair.sh start-bitbot [HOURS]  cancel BitBot's run if going, start only BitBot
#   bot/pair.sh start-wasm [HOURS]    cancel WasmSurvivor_Bot's run if going, start only it
#   bot/pair.sh wasm-vs LOBBY_PROFILE CHALLENGER_PROFILE [HOURS]
#                                     two WasmSurvivors, each on its own profile (a bot/profiles/*.wasm.json,
#                                     or "default" for GameCreator's survivor.profile.json). LOBBY_PROFILE
#                                     sits in the lobby, CHALLENGER_PROFILE challenges it. Cancels the runs
#                                     of its own two accounts first; other pairs are left alone.
#
# AN ACCOUNT IS NAMED FOR THE PROFILE IT PLAYS: Sv + the profile's name (press2 -> SvPress2, default ->
# SvDefault; a challenger on the lobby's own profile gets a 2). The name cannot be given. A name with no
# saved account takes a spare one (bot/identities/*.txt not named Sv..., not BitBot...): its saved id is
# moved to the new name, and the server renames the account when it logs in.
#   bot/pair.sh profiles              list the profiles wasm-vs can take (and "default")
#   bot/pair.sh stop                  cancel every fight run that is going
#   bot/pair.sh status                list the fight runs that are going
#
# A start always cancels the run it replaces first (at once), then waits only until that
# run has finished, because the server keeps its bot's name held until it has.
# Restart ONE bot with start-bitbot / start-wasm: the challenger keeps challenging,
# so the other side does not need to restart.
#
# Uses only `gh api`, so it works with the GitHub CLI (logged in with access to the
# repo) and with Claude Code's built-in gh. Needs jq.
# Each run checks out GameCreator's main when it STARTS, so it is only as new as that.
set -eu

REPO=${PA_REPO:-briankeegan/panel-game}
REF=${PA_REF:-bramp/multi-player}
WORKFLOW=bot-prod-smoke-test.yml
SERVER=${PA_SERVER:-104.156.250.136:49569}
PROFILE=${PA_WASM_PROFILE:-bot/profiles/wasmbot.wasm.json}
RELEASE_WAIT=${PA_RELEASE_WAIT:-120}   # the most to wait for a cancelled run to finish
HOURS=${2:-5}   # start takes HOURS second; wasm-vs takes it fourth

# every fight run going, one "id<TAB>title" per line
running() {
  gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?per_page=50" \
    | jq -r '.workflow_runs[] | select(.status != "completed") | "\(.id)\t\(.display_title)"'
}

# cancel the runs whose title matches PATTERN; print what was cancelled ("cancelled ID"), then the count
cancel_matching() {
  local pattern=$1 n=0 id title
  while IFS=$'\t' read -r id title; do
    [ -n "$id" ] || continue
    printf '%s' "$title" | grep -q -E -- "$pattern" || continue
    gh api -X POST "repos/$REPO/actions/runs/$id/cancel" > /dev/null && echo "pair: cancelled $id  ($title)"
    n=$((n + 1))
  done < <(running)
  echo "$n"
}

# a cancelled run takes a little while to finish shutting down, and the server holds its
# bot's name until it has: wait until the runs just cancelled are finished (at most RELEASE_WAIT s)
stop_and_wait() {   # PATTERN
  local out n ids waited=0 left id
  out=$(cancel_matching "$1")
  printf '%s\n' "$out" | sed '$d'
  n=$(printf '%s\n' "$out" | tail -1)
  [ "$n" -gt 0 ] || return 0
  ids=$(printf '%s\n' "$out" | sed -n 's/^pair: cancelled \([0-9]*\) .*/\1/p')
  while [ "$waited" -lt "$RELEASE_WAIT" ]; do
    left=0
    for id in $ids; do
      [ "$(gh api "repos/$REPO/actions/runs/$id" | jq -r .status)" = completed ] || left=1
    done
    [ "$left" = 0 ] && break
    sleep 5; waited=$((waited + 5))
  done
  echo "pair: the cancelled run(s) finished after ${waited}s"
  sleep 5   # the server notices the dropped connection
}

dispatch() {   # a JSON object of the workflow's inputs
  printf '{"ref":"%s","inputs":%s}' "$REF" "$1" \
    | gh api -X POST "repos/$REPO/actions/workflows/$WORKFLOW/dispatches" --input - > /dev/null
}
dispatch_bitbot() {
  dispatch "{\"mode\":\"fight\",\"bot\":\"bitbot\",\"opponent\":\"you\",\"name\":\"BitBot\",\"hours\":\"$HOURS\",\"server\":\"$SERVER\"}"
  echo "pair: BitBot queued (sits in the lobby)"
}
dispatch_wasm() {
  dispatch "{\"mode\":\"fight\",\"bot\":\"wasm\",\"opponent\":\"challenge\",\"name\":\"WasmSurvivor_Bot,BitBot\",\"hours\":\"$HOURS\",\"profile\":\"$PROFILE\",\"server\":\"$SERVER\"}"
  echo "pair: WasmSurvivor_Bot queued (challenges BitBot)"
}

HOST=${SERVER%%:*}
IDS=bot/identities
# the account name for a profile
account() {   # PROFILE [SUFFIX]
  local p=$1
  p=${p##*/}; p=${p%.wasm.json}; p=${p%.json}
  p=$(printf '%s' "$p" | tr -cd 'A-Za-z0-9' | cut -c1-12)
  printf 'Sv%s%s' "${p^}" "${2:-}"
}
# the saved account of NAME exists on the branch
has_identity() { gh api "repos/$REPO/contents/$IDS/$1_$HOST.txt?ref=$REF" > /dev/null 2>&1; }
# NAME has an account: if not, a spare one is renamed to it
claim() {   # NAME
  local name=$1 busy spare sha content
  has_identity "$name" && return 0
  busy=$(running)
  spare=$(gh api "repos/$REPO/contents/$IDS?ref=$REF" --jq '.[] | select(.name | endswith("_'"$HOST"'.txt")) | .name | sub("_'"$HOST"'.txt$"; "")' \
          | grep -v -E '^(Sv|BitBot)' | while read -r n; do printf '%s' "$busy" | grep -q -F "$n" || { echo "$n"; break; }; done)
  [ -n "$spare" ] || { echo "pair: no spare account to name $name -- every saved account is in use"; exit 1; }
  sha=$(gh api "repos/$REPO/contents/$IDS/${spare}_$HOST.txt?ref=$REF" --jq .sha)
  content=$(gh api "repos/$REPO/contents/$IDS/${spare}_$HOST.txt?ref=$REF" --jq .content | tr -d '\n')
  gh api -X PUT "repos/$REPO/contents/$IDS/${name}_$HOST.txt" -f message="identities: $spare is named $name" -f content="$content" -f branch="$REF" > /dev/null
  gh api -X DELETE "repos/$REPO/contents/$IDS/${spare}_$HOST.txt" -f message="identities: $spare is named $name" -f sha="$sha" -f branch="$REF" > /dev/null
  echo "pair: account $spare is now named $name"
}

# one WasmSurvivor pair: the lobby bot (profile LP) and the challenger (profile CP), each named for its profile
wasm_vs() {   # LP CP
  local lp=$1 cp=$2 lobby chal sfx=""
  lobby=$(account "$lp")
  [ "$(account "$cp")" = "$lobby" ] && sfx=2
  chal=$(account "$cp" "$sfx")
  [ "$lp" = default ] && lp=bot/profiles/beverly.json
  [ "$cp" = default ] && cp=bot/profiles/beverly.json
  stop_and_wait "· $lobby \\(wasm\\) vs you|· $chal,$lobby \\(wasm\\)"
  claim "$lobby"; claim "$chal"
  dispatch "{\"mode\":\"fight\",\"bot\":\"wasm\",\"opponent\":\"you\",\"name\":\"$lobby\",\"hours\":\"$HOURS\",\"profile\":\"$lp\",\"server\":\"$SERVER\"}"
  echo "pair: $lobby ($lp) queued (sits in the lobby)"
  dispatch "{\"mode\":\"fight\",\"bot\":\"wasm\",\"opponent\":\"challenge\",\"name\":\"$chal,$lobby\",\"hours\":\"$HOURS\",\"profile\":\"$cp\",\"server\":\"$SERVER\"}"
  echo "pair: $chal ($cp) queued (challenges $lobby)"
}

BITBOT_RUN='BitBot \(bitbot\)'
WASM_RUN='\(wasm\) vs challenge'

case "${1:-}" in
  start)        stop_and_wait .;             dispatch_bitbot; sleep 2; dispatch_wasm ;;
  start-bitbot) stop_and_wait "$BITBOT_RUN"; dispatch_bitbot ;;
  start-wasm)   stop_and_wait "$WASM_RUN";   dispatch_wasm ;;
  wasm-vs)      HOURS=${4:-5}; wasm_vs "${2:?lobby profile}" "${3:?challenger profile}" ;;
  profiles)     echo default; git ls-files 'bot/profiles/*.wasm.json' | sed 's/^/ /' ;;
  stop)         out=$(cancel_matching .); printf '%s\n' "$out" | sed '$d'
                [ "$(printf '%s\n' "$out" | tail -1)" -gt 0 ] || echo "pair: nothing running" ;;
  status)       out=$(running); if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "pair: nothing running"; fi ;;
  *)            sed -n '2,19p' "$0"; exit 2 ;;
esac
