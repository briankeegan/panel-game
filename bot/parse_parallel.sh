#!/bin/zsh
# Re-emit one corpus in parallel: N sharded parse.sh workers → SAME OUTDIR.
# Each worker handles files where (index-1) % N == (shard-1); gameId filenames don't
# collide, so they merge into one corpus. ~N× faster than a single parse.
#
# Usage:  zsh bot/parse_parallel.sh <publicId> <indir> <outdir> [nshard] [limit]
#   e.g.: zsh bot/parse_parallel.sh 935 tools/replay_corpus/data/935 bot/data/chaos_bot 4
cd "$(dirname "$0")/.."
# NOTE: each LÖVE worker is RAM-heavy — >2-3 instances exhaust memory and THRASH (load
# spikes, throughput → 0). Default 2; raise only if you have RAM headroom to spare.
ID="$1"; INDIR="$2"; OUTDIR="$3"; N="${4:-2}"; LIMIT="${5:-0}"
mkdir -p "$OUTDIR"
echo "parse_parallel: $ID -> $OUTDIR with $N shards"
pids=()
for i in $(seq 1 "$N"); do
  PA_PARSE_SHARD="$i" PA_PARSE_NSHARD="$N" zsh bot/parse.sh "$ID" "$INDIR" "$OUTDIR" "$LIMIT" \
    > "logs/parse_${ID}_shard${i}.log" 2>&1 &
  pids+=($!)
done
echo "launched $N workers (pids: ${pids[*]}); waiting..."
for p in "${pids[@]}"; do wait "$p"; done
echo "parse_parallel DONE: $(ls "$OUTDIR"/*.jsonl.gz 2>/dev/null | wc -l | tr -d ' ') games in $OUTDIR"
