#!/usr/bin/env bash
# PLAMP — our trained bot, on the server.
#
#   bot/plamp.sh                      play briankeegan's server
#   bot/plamp.sh <ip> [port] [name]   somewhere else
#
# The weights are bot/profiles/plamp.json, found by the population-based
# search in the GameCreator repo (games/the-game/ai/eval/train_pbt.js) and
# scored by bot/PanelEval.lua, which is the same evaluator ported to Lua and
# checked against the JavaScript twice over: feature by feature on 393 real
# boards (bot/tests/panelEvalVerify.lua) and MOVE by move on 400 more
# (bot/tests/decisionVerify.lua). No shapes, no chain logic: it scores the
# board a move LEAVES, on weighted features, two moves deep.
#
# IT RUNS UNTIL KILLED. Run it where it can stay up -- the server box, tmux,
# a systemd unit -- not in a shell you are about to close.
set -eu
cd "$(dirname "$0")/.."

IP="${1:-104.156.250.136}"
PORT="${2:-49569}"
NAME="${3:-Plamp}"

# THE CADENCE THE WEIGHTS WERE FOUND UNDER, because the evaluator models it:
# it prices a candidate's travel at one tap every 4 frames and charges every
# candidate for the rows that land during travel plus `reaction`. Walk slower
# than the model thinks and the bot is judging boards the stack has not
# reached; the numbers stop describing the game it is playing.
#
# 4 and 12 are those numbers (bot/profiles/plamp.json carries `reaction`). For
# reference, chaos952's median cursor move is 11 frames and his median swap
# interval 15, over 776 games -- slower than this, and overridable below.
CURSOR_INTERVAL="${PLAMP_CURSOR_INTERVAL:-4}"
REACTION="${PLAMP_REACTION:-12}"

export PA_SEARCH_PROFILE="${PA_SEARCH_PROFILE:-bot/profiles/plamp.json}"

if ! command -v luajit >/dev/null 2>&1; then
  echo "luajit is not on PATH. The bot needs it; see docs/SelfHosting.md." >&2
  exit 1
fi
if [ ! -f "$PA_SEARCH_PROFILE" ]; then
  echo "no weight set at $PA_SEARCH_PROFILE" >&2
  exit 1
fi

echo "Plamp -> $IP:$PORT as '$NAME'"
echo "  weights: $PA_SEARCH_PROFILE"
echo "  cadence: cursor every ${CURSOR_INTERVAL}f, reaction ${REACTION}f"
exec luajit bot/playBot.lua "$IP" "$PORT" "$NAME" "$CURSOR_INTERVAL" "$REACTION" weighted
