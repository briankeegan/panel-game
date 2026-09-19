#!/usr/bin/env bash
# PLAMP — our trained bot, on the server.
#
#   bot/plamp.sh                      play briankeegan's server
#   bot/plamp.sh <ip> [port] [name]   somewhere else
#
# The weights are bot/profiles/plamp.json, found by the population-based
# search in the GameCreator repo (games/the-game/ai/eval/train_pbt.js) and
# scored by bot/PanelEval.lua, which is the same evaluator ported to Lua and
# checked feature-by-feature against the JavaScript on 393 real boards
# (bot/tests/panelEvalVerify.lua). No shapes, no chain logic: it scores the
# board a move LEAVES, on weighted features.
#
# IT RUNS UNTIL KILLED. Run it where it can stay up -- the server box, tmux,
# a systemd unit -- not in a shell you are about to close.
set -eu
cd "$(dirname "$0")/.."

IP="${1:-104.156.250.136}"
PORT="${2:-49569}"
NAME="${3:-Plamp}"

# Human cadence, from the corpus: chaos952's median swap interval is 15
# frames and his median cursor move 11, over 776 games. Full speed is both
# inhuman and pointless -- the bot is not short of thinking time.
CURSOR_INTERVAL="${PLAMP_CURSOR_INTERVAL:-11}"
REACTION="${PLAMP_REACTION:-4}"

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
