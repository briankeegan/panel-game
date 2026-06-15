#!/bin/zsh
# Reusable corpus re-emit: re-sim a player's replays into training rows (bot/data/<name>_bot)
# via the SAME BoardState.extract the bot uses, sharded N-ways for speed (bot/parse_parallel.sh).
#
# Usage:
#   zsh bot/reemit.sh <name> [nshard]     # one registered player (e.g. kekeke)
#   zsh bot/reemit.sh all [nshard]        # every registered player, sequentially (each sharded)
#   zsh bot/reemit.sh <name> <publicId> [nshard]   # ad-hoc player not in the registry
#
# Players run SEQUENTIALLY (each internally sharded) so concurrent love workers stay ~nshard,
# not nshard×players — keeps cores/save-dirs sane. Default 4 shards (~Nx faster than 1 process).
cd "$(dirname "$0")/.."

# registry: name -> publicId  (raw replays live in tools/replay_corpus/data/<publicId>)
typeset -A PLAYERS=( chaos952 935  mscl 3084  kekeke 4861 )

reemit_one() {  # <name> <publicId> <nshard>
  local name="$1" id="$2" n="$3"
  local indir="tools/replay_corpus/data/$id" outdir="bot/data/${name}_bot"
  if [[ ! -d "$indir" ]]; then echo "SKIP $name: no raw replays at $indir"; return 1; fi
  echo "=== re-emit $name (id $id) -> $outdir, $n shards ==="
  rm -f "$outdir"/*.jsonl.gz 2>/dev/null     # clean: new schema, not a resume
  zsh bot/parse_parallel.sh "$id" "$indir" "$outdir" "$n"
}

arg1="${1:?usage: reemit.sh <name|all> [publicId] [nshard]}"
if [[ "$arg1" == "all" ]]; then
  n="${2:-4}"
  for name in ${(k)PLAYERS}; do reemit_one "$name" "${PLAYERS[$name]}" "$n"; done
elif [[ -n "$2" && "$2" == <-> && -z "${PLAYERS[$arg1]}" ]]; then
  reemit_one "$arg1" "$2" "${3:-4}"          # ad-hoc: name + explicit publicId
else
  id="${PLAYERS[$arg1]:?unknown player '$arg1' — pass an explicit publicId}"
  reemit_one "$arg1" "$id" "${2:-4}"
fi
echo "reemit DONE"
