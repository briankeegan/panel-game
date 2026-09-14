#!/bin/zsh
# Re-simulate legacy input-replays under LÖVE 11.5 and emit per-frame training
# rows (bot/parseReplays.lua) per bot/DATA_CONTRACT.md.
#
# Usage:  zsh bot/parse.sh <publicId> <indir> <outdir> [limit]
#   one-off single file (testing):
#         PA_PARSE_FILE=path/to/one.json zsh bot/parse.sh <publicId> "" <outdir>
#
# Runs through main.lua's PA_PARSE_MODE dispatch (same mechanism as run_tests.sh),
# so it shares conf.lua. Distinct LOVE_IDENTITY so it can't stomp the dev client.
source ~/.zshrc 2>/dev/null
eval "$(luarocks path --local --lua-version 5.1)"
cd "$(dirname "$0")/.."

# Distinct save-dir per shard so concurrent parse workers don't race love's identity dir.
export LOVE_IDENTITY="Unofficial Panel Attack FFA & Team Parse${PA_PARSE_SHARD:-}"
export PA_PARSE_MODE=1
export PA_PARSE_ID="$1"
export PA_PARSE_INDIR="$2"
export PA_PARSE_OUTDIR="$3"
export PA_PARSE_LIMIT="${4:-0}"

mkdir -p "$PA_PARSE_OUTDIR"
love .
