#!/bin/zsh
# replay_to_gif.sh — render a colored view, one command. Source is a replay or seed:N; OUTPUT format is by extension:
#   out.gif -> animated GIF      out.png -> contact sheet of stills (no animation needed)
#   zsh bot/replay_to_gif.sh <replay.json> [out.gif|out.png] [start] [end] [ms]   # re-sim a saved replay (no brain)
#   zsh bot/replay_to_gif.sh seed:<N>      [out.gif|out.png] [start] [end] [ms]   # RUN the bot live, annotate state
# Give a frame range to ZOOM into a window at full fidelity.
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks path --local --lua-version 5.1)" 2>/dev/null || true

SRC="${1:?usage: replay_to_gif.sh <replay.json|seed:N> [out.gif] [start] [end] [ms]}"
case "$SRC" in
  seed:*) OUT="${2:-bot_${SRC#seed:}.gif}" ;;
  *)      OUT="${2:-${SRC%.json}.gif}" ;;
esac
TMP="$(mktemp -t replayframes.XXXX).json"

luajit bot/replayToGif.lua "$SRC" "$TMP"
python3 bot/replayToGif.py "$TMP" "$OUT" "$3" "$4" "$5"
rm -f "$TMP"
echo "GIF: $OUT"
