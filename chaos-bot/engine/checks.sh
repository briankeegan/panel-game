#!/usr/bin/env bash
# THE CHECKS (Step 1's gate): the C engine against recordings of the chaos v3 Lua, frame by frame.
#   chaos-bot/engine/checks.sh [N]     N recordings (default 300): every level, queue type, margin, game mode, and the
#                                      hand-built boards (chain staircases to the 12-row cap, all-clears, shock, tall combos)
# Fails on the first recording that differs (printing how to reproduce it), or if any event happened fewer than MIN times.
# Prints, as data: one "event NAME COUNT" line per event, then "checks recordings R frames F min M result pass|fail".
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
n="${1:-300}"
MIN="${MIN:-20}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc -O2 -Wall -Wno-unused-function -o "$tmp/check" "$here/check.c" "$here/ca.c" -lm
scenarios=(none chain chain allclear shock tall)
declare -A ev
names=()
total=0
ran=0
for ((i = 1; i <= n; i++)); do
  level=$(( (i * 7) % 11 + 1 ))
  queue=$(( i % 3 + 1 ))
  chaos=$(( (i / 3) % 2 ))
  margin=$(( (i / 2) % 4 + 1 ))
  gm=$(( (i / 5) % 4 + 1 ))
  every=$(( 40 + (i * 37) % 300 ))
  sc=${scenarios[$(( i % ${#scenarios[@]} ))]}
  args="$((1000 + i)) 20000 $level $queue $chaos $margin $gm $every $sc"
  luajit "$here/../lua/record.lua" $args > "$tmp/rec.txt"
  if ! "$tmp/check" < "$tmp/rec.txt" > "$tmp/out.txt" 2>&1; then
    tail -25 "$tmp/out.txt"
    echo "FAILED: luajit chaos-bot/lua/record.lua $args | check"
    echo "checks recordings $ran frames $total min $MIN result fail"
    exit 1
  fi
  read -r -a e < <(grep '^events ' "$tmp/out.txt")
  for ((k = 1; k < ${#e[@]}; k += 2)); do
    name=${e[$k]}
    [[ -v ev[$name] ]] || { ev[$name]=0; names+=("$name"); }
    ev[$name]=$(( ev[$name] + e[$k + 1] ))
  done
  frames=$(awk '/frames identical/ { print $1 }' "$tmp/out.txt")
  [[ -n "$frames" ]] || { echo "no frame count from check"; exit 1; }
  total=$((total + frames))
  ran=$((ran + 1))
done
result=pass
for name in "${names[@]}"; do
  echo "event $name ${ev[$name]}"
  if (( ev[$name] < MIN )); then result=fail; fi
done
[[ ${#names[@]} -gt 0 ]] || result=fail
echo "checks recordings $ran frames $total min $MIN result $result"
[[ $result == pass ]]
