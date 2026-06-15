#!/bin/sh
# Usage: list_players.sh <YYYY> <MM>
# Crawl the v049 replay archive for ONE month and print the unique set of player
# names (parsed from "<P1>-vs-<P2>" matchup folders). Read-only / public data.
#
# Crawl one month at a time — rapid multi-month loops get throttled (empty
# responses). Verified working 2026-06 (602 matchups, 169 unique players).
set -eu
YEAR="${1:?usage: list_players.sh <YYYY> <MM>}"
MONTH="${2:?usage: list_players.sh <YYYY> <MM>}"
BASE="https://panelattack.com/replays/v049/$YEAR/$MONTH"

days=$(curl -s --max-time 25 "$BASE/" | grep -oE 'href="[0-9]{2}/"' | sed -E 's/href="//; s#/"##')
for d in $days; do
  curl -s --max-time 25 "$BASE/$d/" \
    | grep -oE 'href="[^"]+-vs-[^"]+/"' \
    | sed -E 's/href="//; s#/"##'
done | sed -E 's/-vs-/\
/' | sort -u
