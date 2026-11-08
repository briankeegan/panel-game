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
  if [ -s "$dir/../site-prune.txt" ]; then sort -u "$dir/../site-prune.txt" | while read -r f; do git -C "$dir" update-index --force-remove -- "$f"; done; fi
  git -C "$dir" add -A
  tree=$(git -C "$dir" write-tree)
  [ "$tree" != "$(git -C "$dir" rev-parse "$SITE_OLD^{tree}")" ] || { echo "nothing new for the page"; return 0; }
  commit=$(git -C "$dir" -c user.name="github-actions" -c user.email="actions@github.com" commit-tree "$tree" -m "$msg") || return 1
  git push -q --force-with-lease="gh-pages:$SITE_OLD" origin "$commit:refs/heads/gh-pages"
}
