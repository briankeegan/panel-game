#!/usr/bin/env bash
# Called every so often while a bot run is still going: puts the games it has finished so far on the stats page (no replays: those
# are made once the run is over, by the "Update the Gambit stats page" step). Never fails the run: the caller ignores the exit code.
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
sha=$(cat gambit-commit.txt 2>/dev/null || true)
info=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq '[.display_title, .run_started_at] | @tsv' 2>/dev/null || true)
title=${info%%$'\t'*}; started=${info#*$'\t'}
[ -n "$title" ] && [ -n "$started" ] || { echo "could not read the run's title"; exit 0; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for attempt in 1 2 3; do
  site_open "$w/site" || { echo "no gh-pages branch"; exit 0; }
  python3 dashboard/update_data.py --run-id "$GITHUB_RUN_ID" --dir "$d" --data "$w/site/data" --title "$title" --started "$started" --partial --sha "$sha" --now "$now" || { echo "update_data.py failed"; exit 0; }
  python3 dashboard/make_site.py "$w/site" >/dev/null || { echo "make_site.py failed"; exit 0; }
  site_push "$w/site" "Gambit stats: games so far from the run in progress" && { echo "published (attempt $attempt)"; exit 0; }
  echo "push failed (attempt $attempt)"
  sleep $((attempt * 7))
done
echo "could not publish after 3 attempts"; exit 0
