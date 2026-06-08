#!/bin/bash
# Trigger the build-shells GitHub Actions workflow (compiles the Windows/macOS/Linux
# launcher shells incl. the native lua-https libs, then publishes them to the
# `launcher` release).
#
# WHY A TAG instead of the "Run workflow" button: this is a FORK. workflow_dispatch
# (the button + the API) requires the workflow to live on the repo's DEFAULT branch
# (`beta`), which tracks upstream and we never touch. A `build-shells-*` tag push runs
# the workflow straight from THIS branch's commit, no default-branch access needed.
# Normal code pushes do NOT trigger it — only these tags do.
#
# Usage:  zsh trigger-shell-build.sh
# It pushes the current branch (so the tag's commit has the latest workflow + code),
# finds the next free build-shells-N number, and pushes that tag to fire the run.

set -euo pipefail
cd "$(dirname "$0")"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
PREFIX="build-shells-"

echo "==> Pushing branch '$BRANCH' (the tag will point at its latest commit)..."
git push origin "$BRANCH"

echo "==> Finding the next free ${PREFIX}N tag..."
git fetch --tags --quiet origin 2>/dev/null || true
# Highest existing N across local + remote tags; default 0 so the first run is N=1.
max=$(
  { git tag --list "${PREFIX}*"; git ls-remote --tags origin "${PREFIX}*" 2>/dev/null | sed 's#.*/##'; } \
    | sed -nE "s/^${PREFIX}([0-9]+)\$/\1/p" | sort -n | tail -1
)
next=$(( ${max:-0} + 1 ))
TAG="${PREFIX}${next}"

echo "==> Tagging '$TAG' and pushing to trigger the workflow..."
git tag "$TAG"
git push origin "$TAG"

echo ""
echo "==> Triggered. Watch the run here:"
echo "    https://github.com/briankeegan/panel-game/actions"
echo ""
echo "    When it's green, the three shells (with a real https.dll/.so baked in) are at:"
echo "    https://github.com/briankeegan/panel-game/releases/tag/launcher"
