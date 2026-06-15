#!/bin/sh
# Usage: player_id.sh <playerName> [YYYY] [MM]
# Find the first replay in the given month (default 2026/06) whose matchup folder
# contains <playerName>, then print every stack's "name -> publicId" from that
# replay JSON. publicId is the STABLE per-account server user id (names change).
# Read-only / public data. Verified working 2026-06-14.
set -eu
NAME="${1:?usage: player_id.sh <playerName> [YYYY] [MM]}"
YEAR="${2:-2026}"
MONTH="${3:-06}"
BASE="https://panelattack.com/replays/v049/$YEAR/$MONTH"

days=$(curl -s --max-time 25 "$BASE/" | grep -oE 'href="[0-9]{2}/"' | sed -E 's/href="//; s#/"##')
for d in $days; do
  folder=$(curl -s --max-time 25 "$BASE/$d/" \
    | grep -oE "href=\"[^\"]*${NAME}[^\"]*/\"" | head -1 \
    | sed -E 's/href="//; s#/"##')
  [ -z "$folder" ] && continue
  file=$(curl -s --max-time 25 "$BASE/$d/$folder/" \
    | grep -oE 'href="[^"]+\.json"' | head -1 | sed -E 's/href="//; s/"//')
  url="$BASE/$d/$folder/$file"
  echo "replay: $url"
  curl -s --max-time 25 "$url" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(s.get('name'),'->',s.get('publicId')) for s in d['metadata']['stacks']]"
  exit 0
done
echo "no replay found for '$NAME' in $YEAR/$MONTH" >&2
exit 1
