#!/usr/bin/env bash
# THE CHECKS: the C engine against recordings of the chaos v3 Lua, frame by frame.
#   chaos-bot/engine/checks.sh [N]     N recordings (default 120), every level, queue type, margin, game mode
# Fails on the first recording that differs, printing how to reproduce it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
n="${1:-120}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc -O2 -Wall -Wno-unused-function -o "$tmp/check" "$here/check.c" "$here/ca.c" -lm
total=0
for ((i = 1; i <= n; i++)); do
  level=$(( (i * 7) % 11 + 1 ))
  queue=$(( i % 3 + 1 ))
  chaos=$(( (i / 3) % 2 ))
  margin=$(( (i / 2) % 4 + 1 ))
  gm=$(( (i / 5) % 4 + 1 ))
  every=$(( 40 + (i * 37) % 300 ))
  args="$((1000 + i)) 20000 $level $queue $chaos $margin $gm $every"
  luajit "$here/../lua/record.lua" $args > "$tmp/rec.txt"
  if ! out=$("$tmp/check" < "$tmp/rec.txt" 2>&1); then
    echo "$out" | tail -25
    echo "FAILED: luajit chaos-bot/lua/record.lua $args | check"
    exit 1
  fi
  frames=${out%% *}
  total=$((total + frames))
done
echo "checks: $n recordings, $total frames, all identical"
