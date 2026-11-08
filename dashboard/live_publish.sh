#!/usr/bin/env bash
# Called every so often while a bot run is still going: puts the games it has finished so far on the stats page (no replays: those
# are made once the run is over, by the "Update the Gambit stats page" step). Never fails the run: the caller ignores the exit code.
set -u
cd "$GITHUB_WORKSPACE" || exit 0
log=bot-prod-smoke.log
[ -s "$log" ] || exit 0
grep -q "match over —" "$log" || { echo "no finished game yet"; exit 0; }
d="$RUNNER_TEMP/live-stats"; site="$RUNNER_TEMP/live-site"
rm -rf "$d" "$site"; mkdir -p "$d"
cp "$log" "$d/"
sha=$(cat gambit-commit.txt 2>/dev/null || true)
info=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq '[.display_title, .run_started_at] | @tsv' 2>/dev/null || true)
title=${info%%$'\t'*}; started=${info#*$'\t'}
[ -n "$title" ] && [ -n "$started" ] || { echo "could not read the run's title"; exit 0; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for attempt in 1 2 3; do
  rm -rf "$site"; git worktree prune
  git fetch -q --depth=1 origin gh-pages || { echo "no gh-pages branch"; exit 0; }
  git worktree add -q --detach "$site" FETCH_HEAD || exit 0
  mkdir -p "$site/data"
  python3 dashboard/update_data.py --run-id "$GITHUB_RUN_ID" --dir "$d" --data "$site/data" --title "$title" --started "$started" --partial --sha "$sha" --now "$now" || exit 0
  python3 dashboard/make_site.py "$site" >/dev/null || exit 0
  (cd "$site" && git add -A && { git diff --cached --quiet && exit 0; } ; cd "$site" && git -c user.name="github-actions" -c user.email="actions@github.com" commit -q -m "Gambit stats: games so far from the run in progress" && git push -q origin HEAD:gh-pages) && { echo "published (attempt $attempt)"; exit 0; }
  sleep $((attempt * 7))
done
echo "could not publish"; exit 0
