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
#   beverly    the fork's weighted bot, bot/profiles/beverly.json
#   plamp      the fork's weighted bot, bot/profiles/plamp.json
#   heuristic  the fork's original shape-catalog bot
#
# Every bot plays at the same cadence (cursor every 4 frames, 12-frame
# reaction) except heuristic, which keeps its own. Matches are unranked:
# BotClient never asks for ranked.
#
# Run from the repo root with the Lua toolchain on the path
# (eval "$(luarocks path --local --lua-version 5.1)"). Anything with bitbot
# also needs node and GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval; BitBot
# then plays a 30-second pre-flight offline first, and nothing joins the
# lobby if BitBot's hookup is broken.
#
# Accounts: each name logs in with an id derived from the name and HOST, so a
# name is the same account every run (the fork's server accepts a
# client-chosen id for a free name). This is the fork's server only.
#
# Logs: fight-<NAME>.log per side, bitbot-mind.log and bitbot-preflight.log
# when BitBot plays. In the workflow: mode `fight` (bot-prod-smoke-test.yml).
set -u
cd "$(dirname "$0")/.."

usage() { sed -n '2,13p' "$0"; exit 2; }
[ $# -ge 5 ] || usage
HOST=$1; PORT=$2; SECS=$3; BOT=$4; NAME=$5
OPP=${6:-you}; OPP_NAME=${7:-${NAME}2}
[ "$OPP" = you ] && OPP=""

kinds="bitbot beverly plamp heuristic"
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

# ---- BitBot's link and pre-flight, once, if either side is BitBot
LINK_PORT=${BITBOT_LINK_PORT:-47777}
if [ "$BOT" = bitbot ] || [ "$OPP" = bitbot ]; then
  [ -n "${GC_EVAL_DIR:-}" ] || { echo "fight: bitbot needs GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval"; exit 2; }
  node bot/bitbot_link.js --dir "$GC_EVAL_DIR" --port "$LINK_PORT" > bitbot-mind.log 2>&1 &
  LINK_PID=$!
  trap 'kill $LINK_PID 2>/dev/null' EXIT
  for i in $(seq 1 300); do grep -q listening bitbot-mind.log && break; sleep 0.2; done
  grep -q listening bitbot-mind.log || { cat bitbot-mind.log; echo "fight: BitBot did not start"; exit 1; }
  PA_SURVIVOR_PORT=$LINK_PORT PA_SURVIVOR_WAIT=2 luajit bot/bitbot_preflight.lua 1800 2>&1 | tee bitbot-preflight.log
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
  sleep 0.5
  if grep -a "frame failed\|not relayed" bitbot-mind.log; then
    echo "fight: BitBot pre-flight FAILED (lines above are from bitbot-mind.log)"; exit 1
  fi
fi

# ---- one side: KIND NAME [CHALLENGE]
play() {
  local kind=$1 name=$2 challenge=${3:-}
  case "$kind" in
    bitbot)    PA_CHALLENGE="$challenge" PA_SURVIVOR_PORT=$LINK_PORT PA_SURVIVOR_WAIT=2 \
                 timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 survival ;;
    beverly)   PA_CHALLENGE="$challenge" PA_SEARCH_PROFILE=bot/profiles/beverly.json \
                 timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 weighted ;;
    plamp)     PA_CHALLENGE="$challenge" PA_SEARCH_PROFILE=bot/profiles/plamp.json \
                 timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 weighted ;;
    heuristic) PA_CHALLENGE="$challenge" timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" ;;
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
