# Helpers for the stats page. DATA AND PAGE ARE SEPARATE, so new games never republish the page:
#   - the games (data/: games.json, versions.json, runs.json, the replays) live on the `stats-data` branch, which keeps ONE commit (replays
#     that were dropped really leave the repository); each publish copies only the data to its own Cloudflare Pages project
#     (<project>-data.pages.dev), which the page reads when it is opened;
#   - the page (index.html, from dashboard/page.html + loader.js) lives on `gh-pages` and goes up only when it changes (page_publish).
# site_open DIR  : DIR is a checkout of the data branch's small files (data/*.json); the replays are never downloaded.
#                  It writes DIR/../site-sizes.txt, 'bytes name' for every replay on the page, the name relative to data/ (replay_r9.json.gz
#                  for Ranmaru's, chaos/replay_r9.json.gz for another set's -- each set numbers its own games, so a bare name is not enough).
#                  A set is a folder in data/ with its own games.json (data/chaos/: the chaos bot); Ranmaru's are data/ itself.
# site_push DIR MESSAGE : publishes DIR's tree as a single commit, only if nobody pushed in the meantime (else returns 1: start over).
SITE_BRANCH=${SITE_BRANCH:-stats-data}
site_open() {
  local dir="$1"
  rm -rf "$dir"; git worktree prune
  git fetch -q --depth=1 --filter=blob:none origin "$SITE_BRANCH" 2>/dev/null || git fetch -q --depth=1 origin "$SITE_BRANCH" || return 1
  SITE_OLD=$(git rev-parse FETCH_HEAD)
  git worktree add -q --detach --no-checkout "$dir" "$SITE_OLD" || return 1
  git -C "$dir" sparse-checkout init --no-cone >/dev/null 2>&1
  git -C "$dir" sparse-checkout set '/data/*.json' '/data/*/*.json' >/dev/null 2>&1
  git -C "$dir" checkout -q --detach "$SITE_OLD"
  # THE SIZES FROM ONE API CALL. The checkout has no file contents (--filter=blob:none), and `ls-tree -l` needs each file's size, so git
  # fetched every replay one at a time to read it -- some 2000 round trips, 14.5 minutes on every run's first publish (r75, r76: 868 s,
  # 865 s; the later ones, with the blobs then on disk, 10-30 s). GitHub's tree listing has every size at once; ls-tree is the fallback.
  local sz="$dir/../site-sizes.txt"
  if ! { command -v gh >/dev/null 2>&1 && [ -n "${GITHUB_REPOSITORY:-}" ] \
         && gh api "repos/$GITHUB_REPOSITORY/git/trees/$SITE_OLD?recursive=1" \
              --jq 'if .truncated then error("truncated") else (.tree[] | select(.type == "blob" and (.path | startswith("data/"))) | "\(.size) \(.path | sub("^data/"; ""))") end' \
              > "$sz" 2>/dev/null; }; then
    git -C "$dir" ls-tree -r -l "$SITE_OLD" -- data/ | awk '{p=$5; sub(/^data\//, "", p); print $4, p}' > "$sz"
  fi
  mkdir -p "$dir/data"
}
site_push() {
  local dir="$1" msg="$2" tree commit
  # players who do not share their games publicly stay off the page (dashboard/privacy.py); if the check cannot be made, nothing is published
  python3 "$(dirname "${BASH_SOURCE[0]}")/privacy.py" "$dir" || return 1
  if [ -s "$dir/../site-prune.txt" ]; then sort -u "$dir/../site-prune.txt" | while read -r f; do git -C "$dir" update-index --force-remove -- "$f"; done; fi
  git -C "$dir" add --sparse -A      # --sparse: the replays are outside the sparse checkout, and without it a new one is silently left out
  python3 "$(dirname "${BASH_SOURCE[0]}")/site_check.py" "$dir" && git -C "$dir" add --sparse -A
  tree=$(git -C "$dir" write-tree)
  [ "$tree" != "$(git -C "$dir" rev-parse "$SITE_OLD^{tree}")" ] || { echo "nothing new for the page"; return 0; }
  commit=$(git -C "$dir" -c user.name="github-actions" -c user.email="actions@github.com" commit-tree "$tree" -m "$msg") || return 1
  git push -q --force-with-lease="$SITE_BRANCH:$SITE_OLD" origin "$commit:refs/heads/$SITE_BRANCH" || return 1
  site_copy data
}
# page_publish: builds index.html from dashboard/page.html + loader.js and puts it on gh-pages (index.html alone) ONLY if it differs from the
# one there, then asks for the page's Cloudflare copy. New games never come through here.
page_publish() {
  local here w src; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; w="$(mktemp -d)"
  # the page is built from the branch's NEWEST dashboard/, never from this job's checkout: a job started on older code (a bot run that
  # finishes hours later) would otherwise put an older page back over a newer one
  src="$w/src"; mkdir -p "$src"
  if git fetch -q --depth=1 origin "${PAGE_BRANCH:-bramp/multi-player}" 2>/dev/null \
     && ( for f in make_site.py page.html loader.js; do git show "FETCH_HEAD:dashboard/$f" > "$src/$f" || exit 1; done ); then here="$src"
  else echo "page: could not read the newest dashboard/ from ${PAGE_BRANCH:-bramp/multi-player}; not republishing"; return 1; fi
  git fetch -q --depth=1 --filter=blob:none origin gh-pages 2>/dev/null || git fetch -q --depth=1 origin gh-pages || { echo "page: no gh-pages branch"; return 1; }
  git worktree add -q --detach --no-checkout "$w/page" FETCH_HEAD || return 1
  git -C "$w/page" sparse-checkout init --no-cone >/dev/null 2>&1; git -C "$w/page" sparse-checkout set '/index.html' '/chaos/index.html' '/.nojekyll' >/dev/null 2>&1
  git -C "$w/page" checkout -q --detach FETCH_HEAD 2>/dev/null || git -C "$w/page" checkout -q --detach "$(git rev-parse FETCH_HEAD)" || return 1
  python3 "$here/make_site.py" "$w/page" >/dev/null || return 1
  # the page branch holds the page alone: data that used to live beside it goes (it is on stats-data now)
  git -C "$w/page" rm -r -q --cached --sparse --ignore-unmatch data >/dev/null 2>&1; rm -rf "$w/page/data"
  touch "$w/page/.nojekyll"; git -C "$w/page" add --sparse -A
  if git -C "$w/page" diff --cached --quiet; then echo "page: unchanged, not republished"; git worktree remove --force "$w/page"; return 0; fi
  git -C "$w/page" -c user.name="github-actions" -c user.email="actions@github.com" commit -q -m "Stats page: rebuilt from dashboard/page.html" \
    && git -C "$w/page" push -q origin HEAD:gh-pages && echo "page: changed, published" && site_copy page
  git worktree remove --force "$w/page"
}
# site_copy: when CF_PAGES_PROJECT is set, ask for the Cloudflare Pages copy (the `ranmaru-site` mode runs on its own runner; this is one API call).
# site_copy data|page: which of the two Cloudflare projects to refresh.
site_copy() {
  [ -n "${CF_PAGES_PROJECT:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  gh workflow run bot-prod-smoke-test.yml --repo "${GITHUB_REPOSITORY:-}" --ref "${GITHUB_REF_NAME:-bramp/multi-player}" -f mode=ranmaru-site -f advanced="${1:-data}" >/dev/null 2>&1 \
    && echo "asked for the Cloudflare Pages copy" || echo "could not ask for the Cloudflare Pages copy (the next publish will)"
  return 0
}
