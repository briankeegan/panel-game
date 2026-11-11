# Helpers for the stats page's gh-pages branch, which keeps ONE commit: replays that were dropped really leave the repository.
# site_open DIR  : DIR is a checkout of only the small files (index.html, data/*.json); the replays are never downloaded.
#                  It writes DIR/../site-sizes.txt, 'bytes name' for every replay on the page.
# site_push DIR MESSAGE : publishes DIR's tree as a single commit, only if nobody pushed in the meantime (else returns 1: start over).
site_open() {
  local dir="$1"
  rm -rf "$dir"; git worktree prune
  git fetch -q --depth=1 --filter=blob:none origin gh-pages 2>/dev/null || git fetch -q --depth=1 origin gh-pages || return 1
  SITE_OLD=$(git rev-parse FETCH_HEAD)
  git worktree add -q --detach --no-checkout "$dir" "$SITE_OLD" || return 1
  git -C "$dir" sparse-checkout init --no-cone >/dev/null 2>&1
  git -C "$dir" sparse-checkout set '/index.html' '/data/*.json' '/.nojekyll' >/dev/null 2>&1
  git -C "$dir" checkout -q --detach "$SITE_OLD"
  git -C "$dir" ls-tree -r -l "$SITE_OLD" -- data/ | awk '{n=split($5,a,"/"); print $4, a[n]}' > "$dir/../site-sizes.txt"
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
  git push -q --force-with-lease="gh-pages:$SITE_OLD" origin "$commit:refs/heads/gh-pages" || return 1
  site_copy
}
# site_copy: when CF_PAGES_PROJECT is set, ask for the Cloudflare Pages copy (the `ranmaru-site` mode runs on its own runner; this is one API call).
site_copy() {
  [ -n "${CF_PAGES_PROJECT:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  gh workflow run bot-prod-smoke-test.yml --repo "${GITHUB_REPOSITORY:-}" --ref "${GITHUB_REF_NAME:-bramp/multi-player}" -f mode=ranmaru-site >/dev/null 2>&1 \
    && echo "asked for the Cloudflare Pages copy" || echo "could not ask for the Cloudflare Pages copy (the next publish will)"
  return 0
}
