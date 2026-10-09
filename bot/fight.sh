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
#   bitbot     GameCreator's BitBot (C, games/the-game/ai/eval/native, as the
#              checkout at $GC_EVAL_DIR has it), built to libbit.so and played
#              in the client's own process by bot/BitBotNative.lua
#   wasm       GameCreator's WasmSurvivor (games/the-game/ai/eval/survivor.js,
#              same checkout), the survival bot, a Node process per side
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
# need GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval (bitbot: clang; wasm:
# node); each plays a
# 30-second pre-flight offline first, and nothing joins the lobby if its
# hookup is broken.
#
# Accounts: a new name gets its account from the server; its id is saved in
# bot/identities/<name>_<HOST>.txt and reused every run after (the workflow
# commits it). This is the fork's server only.
#
# Logs: fight-<NAME>.log per side; preflight-<NAME>.log for bitbot/wasm,
# mind-<NAME>.log for wasm, bitbot-build.log. In the workflow: mode `fight` (bot-prod-smoke-test.yml).
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

# ---- same name, same account. A name the server has given an account has its
# id in bot/identities/<name>_<HOST>.txt (committed); the bot logs in with it.
# A new name logs in without one: the server makes the account, the bot writes
# its id there, and the workflow commits it ("Save new account ids") so every
# later run logs back in as the same account.
mkdir -p bot/identities
for n in "$NAME" ${OPP:+"$OPP_NAME"}; do
  if [ -s "bot/identities/${n}_${HOST}.txt" ]; then echo "fight: $n logs in to its saved account"
  else echo "fight: $n is new here -- the server makes its account, and its id is saved"; fi
done

# ---- BitBot: native, in the client's own process (bot/BitBotNative.lua, as
# GameCreator's lua/train.lua hooks it). libbit.so is built here by the line
# of GameCreator's native/build.sh that builds it, so it is always the
# checkout's own BitBot. It plays a 30-second pre-flight offline first.
build_bitbot() {
  [ -n "${GC_EVAL_DIR:-}" ] || { echo "fight: bitbot needs GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval"; exit 2; }
  local line
  line=$(grep -E '^clang .*-o libbit\.so$' "$GC_EVAL_DIR/native/build.sh") \
    || { echo "fight: GameCreator's native/build.sh no longer builds libbit.so -- BitBot's hookup needs a look"; exit 1; }
  (cd "$GC_EVAL_DIR/native" && eval "$line" 2> "$OLDPWD/bitbot-build.log") \
    || { cat bitbot-build.log; echo "fight: libbit.so did not build"; exit 1; }
}
preflight() {   # KIND NAME [PORT WAIT]
  local kind=$1 name=$2
  PA_PREFLIGHT_BRAIN=$([ "$kind" = bitbot ] && echo bitbot) PA_SURVIVOR_PORT=${3:-} PA_SURVIVOR_WAIT=${4:-} \
    PA_PREFLIGHT_NAME="$kind ($name)" PA_PREFLIGHT_LATE_OK=$([ "$kind" = wasm ] && echo 1) \
    luajit bot/bitbot_preflight.lua 1800 2>&1 | tee "preflight-$name.log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
}

# ---- WasmSurvivor: a Node process the client asks every frame
# (bot/SurvivalLink.lua), one per side, on its own port.
BASE_PORT=${MIND_PORT:-47777}
declare -A PORT_OF
start_wasm() {   # NAME PORT
  local name=$1 port=$2 log="mind-$1.log"
  [ -n "${GC_EVAL_DIR:-}" ] || { echo "fight: wasm needs GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval"; exit 2; }
  # WASM_PROFILE=bot/profiles/<x>.wasm.json plays trained weights (its
  # "weights" file sits beside it; survivor.js reads it from its own folder)
  local prof=""
  case "${WASM_PROFILE:-}" in
    *.wasm.json)
      [ -f "$WASM_PROFILE" ] || { echo "fight: no WasmSurvivor profile $WASM_PROFILE"; exit 2; }
      local w; w=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["weights"])' "$WASM_PROFILE")
      cp "$(dirname "$WASM_PROFILE")/$w" "$GC_EVAL_DIR/$w" || { echo "fight: no weights $w beside $WASM_PROFILE"; exit 2; }
      prof="$PWD/$WASM_PROFILE"; echo "fight: wasm ($name) plays $WASM_PROFILE" ;;
  esac
  GC_SURVIVOR_PROFILE=$prof node "$GC_EVAL_DIR/survivor.js" --port "$port" > "$log" 2>&1 &
  PIDS="${PIDS:-} $!"
  PORT_OF[$name]=$port
  for i in $(seq 1 300); do grep -q listening "$log" && break; sleep 0.2; done
  grep -q listening "$log" || { cat "$log"; echo "fight: wasm ($name) did not start"; exit 1; }
  preflight wasm "$name" "$port" ""
}
trap 'kill ${PIDS:-} 2>/dev/null' EXIT
if [ "$BOT" = bitbot ] || [ "$OPP" = bitbot ]; then build_bitbot; fi
case "$BOT" in bitbot) preflight bitbot "$NAME" ;; wasm) start_wasm "$NAME" "$BASE_PORT" ;; esac
case "$OPP" in bitbot) preflight bitbot "$OPP_NAME" ;; wasm) start_wasm "$OPP_NAME" $((BASE_PORT + 1)) ;; esac

# ---- one side: KIND NAME [CHALLENGE]
play() {
  local kind=$1 name=$2 challenge=${3:-}
  case "$kind" in
    bitbot)      PA_CHALLENGE="$challenge" timeout "$SECS" luajit bot/playBot.lua "$HOST" "$PORT" "$name" 4 12 bitbot ;;
    wasm)        PA_CHALLENGE="$challenge" PA_SURVIVOR_PORT=${PORT_OF[$name]} \
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
