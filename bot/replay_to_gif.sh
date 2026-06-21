#!/bin/zsh
# replay_to_gif.sh — turn a saved bot replay into a watchable colored GIF, one command:
#   zsh bot/replay_to_gif.sh <replay.json> [out.gif] [startFrame] [endFrame] [msPerFrame]
# Re-sims the replay faithfully (luajit, no brain) -> frames JSON -> GIF (python3 + PIL).
# Default out = <replay>.gif. Give a frame range to ZOOM into a window at full fidelity.
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks path --local --lua-version 5.1)" 2>/dev/null || true

REPLAY="${1:?usage: replay_to_gif.sh <replay.json> [out.gif] [start] [end] [ms]}"
OUT="${2:-${REPLAY%.json}.gif}"
TMP="$(mktemp -t replayframes.XXXX).json"

luajit bot/replayToGif.lua "$REPLAY" "$TMP"
python3 bot/replayToGif.py "$TMP" "$OUT" "$3" "$4" "$5"
rm -f "$TMP"
echo "GIF: $OUT"
