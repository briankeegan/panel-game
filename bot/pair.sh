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
#                                     or "defensive" (the old "default") for GameCreator's survivor.profile.json). LOBBY_PROFILE
#                                     sits in the lobby, CHALLENGER_PROFILE challenges it. Cancels the runs
#                                     of its own two accounts first; other pairs are left alone.
#
# AN ACCOUNT IS NAMED FOR THE PROFILE IT PLAYS: Sv + the profile's name (press2 -> SvPress2, defensive ->
# SvDefensive; a challenger on the lobby's own profile gets a 2). The name cannot be given. A name with no
# saved account takes a spare one (bot/identities/*.txt not named Sv..., not BitBot...): its saved id is
# moved to the new name, and the server renames the account when it logs in.
#   bot/pair.sh beta [BOT] [NAME] [HOURS] [PROFILE]
#                                     a bot in the lobby of the real Panel Attack server (default panelattack.com:49569; PA_UPSTREAM_SERVER overrides)
#                                     (running upstream's beta branch) -- the real Panel Attack game, not
#                                     the Bramp fork. BOT is beverly (default), plamp, wasm (WasmSurvivor) or
#                                     bitbot. Cancels its earlier beta run first. Upstream assigns the account
#                                     id; the run commits it back so the name is reused. Pin the build with
#                                     PA_UPSTREAM_REF=<commit/tag/branch> (default: the betaserver-live tag if
#                                     upstream has one, else the latest beta).
#   bot/pair.sh beta-vs OPPONENT [HOURS] [PROFILE]
#                                     WasmSurvivor_CPU on the real server, challenging the player named
#                                     OPPONENT in the lobby (a bot or a person) and rematching until the
#                                     hours run out. Same as `beta wasm`, with a target.
#   bot/pair.sh duo [HOURS]           on the real server (panelattack.com), one of each, both sitting in the lobby
#                                     and taking any challenge: WasmAgro_CPU (bot/profiles/agro.wasm.json) and
#                                     WasmDefense_CPU (GameCreator's own default profile). Each cancels only its
#                                     own earlier run. HOURS default 3.
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
  local p=$1 f named
  # a profile that names its account ("account") is played under that name
  f="bot/profiles/${p##*/}"; f=${f%.wasm.json}; f=${f%.json}.wasm.json
  if [ -f "$f" ] && named=$(jq -r '.account // empty' "$f") && [ -n "$named" ]; then printf '%s%s' "$named" "${2:-}"; return; fi
  p=${p##*/}; p=${p%.wasm.json}; p=${p%.json}
  [ "$p" = default ] && p=defensive
  p=$(printf '%s' "$p" | tr -cd 'A-Za-z0-9' | cut -c1-12)
  printf 'Sv%s%s' "${p^}" "${2:-}"
}
# NAME has a saved account: if not, a spare one is renamed to it (the checkout's branch, committed and pushed)
claim() {   # NAME
  local name=$1 busy spare
  git pull -q --no-rebase origin "$REF"
  [ -s "$IDS/${name}_$HOST.txt" ] && return 0
  busy=$(running)
  spare=$(ls "$IDS" | sed -n 's/_'"$HOST"'\.txt$//p' | grep -v -E '^(Sv|BitBot)' \
          | while read -r n; do printf '%s' "$busy" | grep -q -F "$n" || { echo "$n"; break; }; done)
  [ -n "$spare" ] || { echo "pair: no spare account to name $name -- every saved account is in use"; exit 1; }
  git mv "$IDS/${spare}_$HOST.txt" "$IDS/${name}_$HOST.txt"
  git commit -q -m "identities: $spare is named $name" -- "$IDS"
  git push -q origin "HEAD:$REF"
  echo "pair: account $spare is now named $name"
}

# a profile name (press2) or path as the file the run loads; "default" is GameCreator's own profile. A name with no
# file is refused: the run would fall back to the default and say nothing.
profile_path() {   # NAME-OR-PATH
  local p=$1
  case "$p" in default|defensive) echo bot/profiles/beverly.json; return;; esac
  [ -f "bot/profiles/$p.wasm.json" ] && { echo "bot/profiles/$p.wasm.json"; return; }
  [ -f "$p" ] && case "$p" in *.wasm.json) echo "$p"; return;; esac
  echo "pair: no profile '$p' (bot/profiles/$p.wasm.json)" >&2; exit 1
}

# one WasmSurvivor pair: the lobby bot (profile LP) and the challenger (profile CP), each named for its profile
wasm_vs() {   # LP CP
  local lp=$1 cp=$2 lobby chal sfx=""
  lobby=$(account "$lp")
  [ "$(account "$cp")" = "$lobby" ] && sfx=2
  chal=$(account "$cp" "$sfx")
  lp=$(profile_path "$lp"); cp=$(profile_path "$cp")
  stop_and_wait "· $lobby \\(wasm\\) vs you|· $chal,$lobby \\(wasm\\)"
  claim "$lobby"; claim "$chal"
  dispatch "{\"mode\":\"fight\",\"bot\":\"wasm\",\"opponent\":\"you\",\"name\":\"$lobby\",\"hours\":\"$HOURS\",\"profile\":\"$lp\",\"server\":\"$SERVER\"}"
  echo "pair: $lobby ($lp) queued (sits in the lobby)"
  dispatch "{\"mode\":\"fight\",\"bot\":\"wasm\",\"opponent\":\"challenge\",\"name\":\"$chal,$lobby\",\"hours\":\"$HOURS\",\"profile\":\"$cp\",\"server\":\"$SERVER\"}"
  echo "pair: $chal ($cp) queued (challenges $lobby)"
}

BITBOT_RUN='BitBot \(bitbot\)'
WASM_RUN='\(wasm\) vs challenge'

dispatch_beta() {   # BOT NAME HOURS PROFILE
  local ref=${PA_UPSTREAM_REF:-}
  dispatch "{\"mode\":\"live\",\"server\":\"${PA_UPSTREAM_SERVER:-panelattack.com:49569}\",\"bot\":\"$1\",\"name\":\"$2\",\"hours\":\"$3\",\"profile\":\"$4\",\"upstream_ref\":\"$ref\"}"
  echo "pair: $2 ($1) queued on ${PA_UPSTREAM_SERVER:-panelattack.com:49569} (upstream Panel Attack; the server assigns its account id)"
}
# the profile a bot plays by default
beta_profile() {   # BOT
  case "$1" in
    wasm)            echo bot/profiles/wasmbot.wasm.json ;;
    gambit)          echo survivor-profiles/gambit.json ;;   # (under GameCreator's eval dir)
    beverly|plamp)   echo "bot/profiles/$1.json" ;;
    bitbot)          echo bot/profiles/beverly.json ;;   # (BitBot has no profile; the field is unused)
    *) echo "pair: no bot '$1' (beverly, plamp, wasm, gambit or bitbot)" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  start)        stop_and_wait .;             dispatch_bitbot; sleep 2; dispatch_wasm ;;
  start-bitbot) stop_and_wait "$BITBOT_RUN"; dispatch_bitbot ;;
  start-wasm)   stop_and_wait "$WASM_RUN";   dispatch_wasm ;;
  wasm-vs)      HOURS=${4:-5}; wasm_vs "${2:?lobby profile}" "${3:?challenger profile}" ;;
  beta)         bot=${2:-beverly}; name=${3:-$(case $bot in wasm) echo WasmSurvivor_CPU;; gambit) echo Ranmaru_CPU;; bitbot) echo BitBot;; plamp) echo Plamp;; *) echo Beverly;; esac)}
                prof=${5:-$(beta_profile "$bot")}
                stop_and_wait "(betaserver|panelattack\.com).* ${name//./\\.}(,|\$)"; dispatch_beta "$bot" "$name" "${4:-5}" "$prof" ;;
  duo)          h=${2:-3}
                stop_and_wait "(betaserver|panelattack\.com).* WasmAgro_CPU(,|\$)"
                stop_and_wait "(betaserver|panelattack\.com).* WasmDefense_CPU(,|\$)"
                dispatch_beta wasm WasmAgro_CPU "$h" bot/profiles/agro.wasm.json
                dispatch_beta wasm WasmDefense_CPU "$h" default ;;
  beta-vs)      opp=${2:?the opponent\'s lobby name}; prof=${4:-$(beta_profile wasm)}
                stop_and_wait "(betaserver|panelattack\.com).* WasmSurvivor_CPU(,|\$)"; dispatch_beta wasm "WasmSurvivor_CPU,$opp" "${3:-5}" "$prof" ;;
  profiles)     echo defensive; git ls-files 'bot/profiles/*.wasm.json' | sed 's/^/ /' ;;
  stop)         out=$(cancel_matching '^fight · '); printf '%s\n' "$out" | sed '$d'
                [ "$(printf '%s\n' "$out" | tail -1)" -gt 0 ] || echo "pair: nothing running" ;;
  status)       out=$(running); if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "pair: nothing running"; fi ;;
  *)            sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 2 ;;
esac
