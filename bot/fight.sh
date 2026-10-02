#!/usr/bin/env bash
# FIGHT: pick who plays who on the fork's server.
#
#   bot/fight.sh HOST PORT SECONDS BOT NAME [OPPONENT [OPPONENT_NAME]]
#
#   BOT       sits in the lobby as NAME and auto-accepts any challenge
#   OPPONENT  (optional) logs in as OPPONENT_NAME (default NAME2) and
#             challenges NAME whenever both are free, rematching until
#             SECONDS run out. Omit it, or pass "you", and BOT just waits for
#             a person to challenge it.
#
# The roster (both sides take any of these):
#   bitbot     GameCreator's BitBot (games/the-game/ai/eval/bitbot.js, as the
#              checkout at $GC_EVAL_DIR has it) through bot/bitbot_link.js
#   wasm       GameCreator's WasmSurvivor (games/the-game/ai/eval/survivor.js,
#              same checkout), the survival bot, through its own link
#   beverly    the fork's weighted bot, bot/profiles/beverly.json
#   plamp      the fork's weighted bot, bot/profiles/plamp.json
#   heuristic  the fork's original shape-catalog bot
#
# Every bot plays at the same cadence (cursor every 4 frames, 12-frame
# reaction) except heuristic, which keeps its own. Matches are unranked:
# BotClient never asks for ranked.
#
# Run from the repo root with the Lua toolchain on the path
# (eval "$(luarocks path --local --lua-version 5.1)"). bitbot and wasm also
# need node and GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval; each plays a
# 30-second pre-flight offline first, and nothing joins the lobby if its
# hookup is broken.
#
# Accounts: each name logs in with an id derived from the name and HOST, so a
# name is the same account every run (the fork's server accepts a
# client-chosen id for a free name). This is the fork's server only.
#
# Logs: fight-<NAME>.log per side; for bitbot/wasm also mind-<NAME>.log and
# preflight-<NAME>.log. In the workflow: mode `fight` (bot-prod-smoke-test.yml).
set -u
cd "$(dirname "$0")/.."

usage() { sed -n '2,20p' "$0"; exit 2; }
[ $# -ge 5 ] || usage
HOST=$1; PORT=$2; SECS=$3; BOT=$4; NAME=$5
OPP=${6:-you}; OPP_NAME=${7:-${NAME}2}
[ "$OPP" = you ] && OPP=""

kinds="bitbot wasm beverly plamp heuristic"
known() { case " $kinds " in *" $1 "*) return 0;; esac; return 1; }
known "$BOT" || { echo "fight: no bot '$BOT' (one of: $kinds)"; exit 2; }
[ -z "$OPP" ] || known "$OPP" || { echo "fight: no opponent '$OPP' (one of: $kinds, or you)"; exit 2; }
for n in "$NAME" ${OPP:+"$OPP_NAME"}; do
  [ ${#n} -le 16 ] || { echo "fight: name '$n' is ${#n} chars; the server limit is 16"; exit 2; }
  case "$n" in *[!A-Za-z0-9_]*) echo "fight: name '$n' may only have letters, digits and _"; exit 2;; esac
done
[ -z "$OPP" ] || [ "$NAME" != "$OPP_NAME" ] || { echo "fight: the two sides need different names"; exit 2; }

# ---- same name, same account
mkdir -p bot/identities
for n in "$NAME" ${OPP:+"$OPP_NAME"}; do
  id=$(BOT_IP="$HOST" BOT_NAME="$n" python3 -c '
import hashlib, os
msg = (os.environ["BOT_IP"] + "/" + os.environ["BOT_NAME"].lower()).encode()
print("1" + str(int(hashlib.sha256(msg).hexdigest(), 16) % 10**18).zfill(18))')
  printf '%s' "$id" > "bot/identities/${n}_${HOST}.txt"
done

# ---- a mind per side: BitBot and WasmSurvivor are Node processes the client
# asks every frame (bot/SurvivalLink.lua). Each side gets its own, on its own
# port, so two of them never wait on each other's thinking. Each plays a
# 30-second pre-flight offline first; nothing joins the lobby if it fails.
BASE_PORT=${MIND_PORT:-47777}
declare -A PORT_OF WAIT_OF
start_mind() {   # KIND NAME PORT
  local kind=$1 name=$2 port=$3 log="mind-$2.log"
  [ -n "${GC_EVAL_DIR:-}" ] || { echo "fight: $kind needs GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval"; exit 2; }
  case "$kind" in
    bitbot) node bot/bitbot_link.js --dir "$GC_EVAL_DIR" --port "$port" > "$log" 2>&1 &
            WAIT_OF[$name]=2 ;;          # every frame's answer is awaited: BitBot decides per frame
    wasm)   node "$GC_EVAL_DIR/survivor.js" --port "$port" > "$log" 2>&1 &
            WAIT_OF[$name]="" ;;         # its own default: it answers from keys it planned ahead
  esac
  PIDS="${PIDS:-} $!"
  PORT_OF[$name]=$port
  for i in $(seq 1 300); do grep -q listening "$log" && break; sleep 0.2; done
  grep -q listening "$log" || { cat "$log"; echo "fight: $kind ($name) did not start"; exit 1; }
  PA_SURVIVOR_PORT=$port PA_SURVIVOR_WAIT=${WAIT_OF[$name]} PA_PREFLIGHT_NAME="$kind ($name)" \
    PA_PREFLIGHT_LATE_OK=$([ "$kind" = wasm ] && echo 1) luajit bot/bitbot_preflight.lua 1800 2>&1 | tee "preflight-$name.log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
  sleep 0.5
  if grep -a "frame failed\|not relayed" "$log"; then
    echo "fight: $kind ($name) pre-flight FAILED (lines above are from $log)"; exit 1
  fi
}
trap 'kill $PIDS 2>/dev/null' EXIT
is_mind() { [ "$1" = bitbot ] || [ "$1" = wasm ]; }
is_mind "$BOT" && start_mind "$BOT" "$NAME" "$BASE_PORT"
[ -n "$OPP" ] && is_mind "$OPP" && start_mind "$OPP" "$OPP_NAME" $((BASE_PORT + 1))

# ---- one side: KIND NAME [CHALLENGE]
play() {
  local kind=$1 name=$2 challenge=${3:-}
  case "$kind" in
    bitbot|wasm) PA_CHALLENGE="$challenge" PA_SURVIVOR_PORT=${PORT_OF[$name]} PA_SURVIVOR_WAIT=${WAIT_OF[$name]} \
                   timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 survival ;;
    beverly)     PA_CHALLENGE="$challenge" PA_SEARCH_PROFILE=bot/profiles/beverly.json \
                   timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 weighted ;;
    plamp)       PA_CHALLENGE="$challenge" PA_SEARCH_PROFILE=bot/profiles/plamp.json \
                   timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 weighted ;;
    heuristic)   PA_CHALLENGE="$challenge" timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" ;;
  esac
}

echo "fight: $NAME ($BOT) in the lobby on $HOST:$PORT${OPP:+, challenged by $OPP_NAME ($OPP)}, for ${SECS}s"
if [ -z "$OPP" ]; then
  play "$BOT" "$NAME" 2>&1 | tee "fight-$NAME.log"
  rc=${PIPESTATUS[0]}
else
  play "$BOT" "$NAME" > "fight-$NAME.log" 2>&1 &
  A=$!
  sleep 5
  play "$OPP" "$OPP_NAME" "$NAME" 2>&1 | tee "fight-$OPP_NAME.log"
  rc=${PIPESTATUS[0]}
  wait $A; ra=$?
  [ $rc -eq 0 ] || [ $rc -eq 124 ] || { echo "fight: $OPP_NAME stopped (exit $rc)"; }
  [ $ra -eq 0 ] || [ $ra -eq 124 ] || { echo "fight: $NAME stopped (exit $ra)"; tail -5 "fight-$NAME.log"; rc=$ra; }
fi
# The bots run until killed, so the timeout IS the stop condition: 124 is this working.
[ $rc -eq 0 ] || [ $rc -eq 124 ]
