#!/usr/bin/env bash
# Called while a bot run is still going: puts the games it has finished so far on the stats page, with their replays (only the games
# finished since the last call are made; the final "Update the Gambit stats page" step makes them all again). Never fails the run.
set -u
cd "$GITHUB_WORKSPACE" || { echo "no workspace"; exit 0; }
log=bot-prod-smoke.log
echo "publishing the games so far ($(grep -c "match over —" "$log" 2>/dev/null || echo 0) finished)"
[ -s "$log" ] || { echo "no log yet"; exit 0; }
grep -q "match over —" "$log" || { echo "no finished game yet"; exit 0; }
. dashboard/site_git.sh
d="$RUNNER_TEMP/live-stats"; w="$RUNNER_TEMP/live-work"
rm -rf "$d" "$w"; mkdir -p "$d" "$w"
cp "$log" "$d/"
for f in gambit-*.log; do [ -e "$f" ] && cp "$f" "$d/"; done      # the decision log and the commit it was built from, for each replay's decisions
eng=${BOT_DIR:-}; [ -f "$eng/replayFrames.lua" ] || [ -d "$eng/common" ] || eng=""      # the engine the bot plays on: replays are made here too
sha=$(cat gambit-commit.txt 2>/dev/null || true)
info=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq '[.display_title, .run_started_at] | @tsv' 2>/dev/null || true)
title=${info%%$'\t'*}; started=${info#*$'\t'}
[ -n "$title" ] && [ -n "$started" ] || { echo "could not read the run's title"; exit 0; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for attempt in 1 2 3; do
  site_open "$w/site" || { echo "no gh-pages branch"; exit 0; }
  python3 dashboard/update_data.py --run-id "$GITHUB_RUN_ID" --dir "$d" --data "$w/site/data" --title "$title" --started "$started" --partial --sha "$sha" --now "$now" ${eng:+--engine "$eng"} || { echo "update_data.py failed"; exit 0; }
  # (the page itself is NOT rebuilt here: this checkout is the one the bot started on, and may be older than the page on the site; the update step rebuilds it)
  site_push "$w/site" "Gambit stats: games so far from the run in progress" && { echo "published (attempt $attempt)"; exit 0; }
  echo "push failed (attempt $attempt)"
  sleep $((attempt * 7))
done
echo "could not publish after 3 attempts"; exit 0
