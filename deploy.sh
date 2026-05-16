#!/bin/bash
set -e

SERVER="root@104.156.250.136"
INSTALL_DIR="/opt/panel-attack"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

cd "$(dirname "$0")"

# Refuse to deploy with a dirty working tree. The version-bump step
# below adds a commit; if there are unstaged or untracked-but-staged
# changes already, they'd get mixed in (or `git commit` would error
# halfway through). Either commit/stash first, or set
# PANEL_ALLOW_DIRTY=1 to override (use sparingly — typically only when
# you've intentionally pre-committed and just have untracked artifacts).
if [[ "${PANEL_ALLOW_DIRTY:-0}" != "1" ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "==> ERROR: working tree is dirty. Commit or stash your changes first." >&2
    echo "    (set PANEL_ALLOW_DIRTY=1 to override; untracked files are ignored.)" >&2
    git status --short >&2
    exit 1
  fi
fi

# Snapshot pre-deploy state first. Restarting the service rotates the
# journal cursor and may also clear in-memory state we'd want for
# post-mortems — grab journal + on-disk logs + any crash_reports before
# we touch the running process. Outputs to gathered_logs/<ts>_<commit>/.
# Set PANEL_SKIP_GATHER=1 to skip (e.g. emergency hotfix where you're
# already on the box doing surgery).
if [[ "${PANEL_SKIP_GATHER:-0}" != "1" ]]; then
  echo "==> Gathering pre-deploy state..."
  PANEL_SERVER="$SERVER" INSTALL_DIR="$INSTALL_DIR" zsh ./gather_logs.sh
else
  echo "==> Skipping gather (PANEL_SKIP_GATHER=1)"
fi

# Bump the build patch number so every deploy stamps a new version that
# both the running server and any freshly-launched client print on
# startup. Mismatch between them = somebody is on a stale build.
# Set PANEL_SKIP_VERSION_BUMP=1 to redeploy without bumping (e.g. server
# config change with no code delta).
if [[ "${PANEL_SKIP_VERSION_BUMP:-0}" != "1" ]]; then
  CONSTS_FILE="common/engine/consts.lua"
  CURRENT_VERSION=$(grep -E 'consts\.BUILD_VERSION\s*=' "$CONSTS_FILE" | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "==> ERROR: couldn't find consts.BUILD_VERSION in $CONSTS_FILE; aborting." >&2
    exit 1
  fi
  ENGINE_PART="${CURRENT_VERSION%.*}"
  PATCH_PART="${CURRENT_VERSION##*.}"
  # 10# prefix forces base-10 so leading-zero patch numbers don't get
  # interpreted as octal by $(( )).
  PATCH_INT=$((10#$PATCH_PART))
  NEW_PATCH=$(printf "%04d" $((PATCH_INT + 1)))
  NEW_VERSION="${ENGINE_PART}.${NEW_PATCH}"
  echo "==> Bumping BUILD_VERSION: $CURRENT_VERSION → $NEW_VERSION"
  # macOS sed needs -i '' or -i.bak; use the latter for portability with Linux.
  sed -i.bak -E "s/(consts\.BUILD_VERSION[[:space:]]*=[[:space:]]*)\"[^\"]+\"/\\1\"$NEW_VERSION\"/" "$CONSTS_FILE"
  rm "${CONSTS_FILE}.bak"
  git add "$CONSTS_FILE"
  git commit -m "deploy: build $NEW_VERSION"
else
  echo "==> Skipping version bump (PANEL_SKIP_VERSION_BUMP=1)"
fi

echo "==> Pushing branch '$BRANCH' to origin..."
git push origin "$BRANCH"

echo "==> Deploying to $SERVER..."
ssh "$SERVER" "git config --global --add safe.directory $INSTALL_DIR; cd $INSTALL_DIR && git pull && systemctl restart panel-attack"

# Loud reminder so you don't keep playing on a stale client. Both sides
# read consts.BUILD_VERSION from the same file; if the running client
# was launched before this deploy, it's still on the old version.
if [[ "${PANEL_SKIP_VERSION_BUMP:-0}" != "1" ]]; then
  echo ""
  echo "==> Build is now $NEW_VERSION on both sides of the wire."
  echo "    Restart any running client (zsh run_client.sh) to load the new version."
  echo ""
fi

echo "==> Tailing logs (Ctrl+C to exit)..."
ssh "$SERVER" "journalctl -u panel-attack -f --no-pager"
