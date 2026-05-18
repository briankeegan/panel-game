#!/bin/bash
set -e

SERVER="root@104.156.250.136"
INSTALL_DIR="/opt/panel-attack"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
PATCH_NAME=""

# --patch-name labels this deploy. When set, BUILD_VERSION becomes
# "<engine>.<NNNN>-<name>" and the GitHub Action ships
# unofficial-panel-attack-patch-<name>.love. When omitted, BUILD_VERSION
# is just "<engine>.<NNNN>" and the action ships the default
# unofficial-panel-attack-team-vs.love. The patch number always bumps.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch-name)
      PATCH_NAME="$2"
      shift 2
      ;;
    --patch-name=*)
      PATCH_NAME="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: zsh deploy.sh [--patch-name <kebab-case-name>]"
      echo ""
      echo "Env vars:"
      echo "  PANEL_ALLOW_DIRTY=1        — allow deploy with uncommitted changes"
      echo "  PANEL_SKIP_GATHER=1        — skip pre-deploy log gather"
      echo "  PANEL_SKIP_VERSION_BUMP=1  — redeploy without bumping the patch number"
      exit 0
      ;;
    *)
      echo "==> ERROR: unknown argument: $1" >&2
      echo "    Usage: zsh deploy.sh [--patch-name <kebab-case-name>]" >&2
      exit 1
      ;;
  esac
done

if [[ -n "$PATCH_NAME" ]]; then
  # Kebab-case only — anything else breaks the .love filename or the
  # version-string parser on the client side.
  if ! [[ "$PATCH_NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "==> ERROR: --patch-name must be kebab-case (a-z, 0-9, single hyphens). Got: $PATCH_NAME" >&2
    exit 1
  fi
fi

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
  WORKFLOW_FILE=".github/workflows/unofficial-team-release.yml"
  CURRENT_VERSION=$(grep -E 'consts\.BUILD_VERSION\s*=' "$CONSTS_FILE" | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "==> ERROR: couldn't find consts.BUILD_VERSION in $CONSTS_FILE; aborting." >&2
    exit 1
  fi
  # Strip any trailing -patchname so we recover just "<engine>.<patch>"
  # to bump. Bare versions (no suffix) are unchanged by this.
  CORE_VERSION="${CURRENT_VERSION%%-*}"
  ENGINE_PART="${CORE_VERSION%.*}"
  PATCH_PART="${CORE_VERSION##*.}"
  # 10# prefix forces base-10 so leading-zero patch numbers don't get
  # interpreted as octal by $(( )).
  PATCH_INT=$((10#$PATCH_PART))
  NEW_PATCH=$(printf "%04d" $((PATCH_INT + 1)))
  if [[ -n "$PATCH_NAME" ]]; then
    NEW_VERSION="${ENGINE_PART}.${NEW_PATCH}-${PATCH_NAME}"
    LOVE_FILENAME="unofficial-panel-attack-patch-${PATCH_NAME}.love"
  else
    NEW_VERSION="${ENGINE_PART}.${NEW_PATCH}"
    LOVE_FILENAME="unofficial-panel-attack-team-vs.love"
  fi
  echo "==> Bumping BUILD_VERSION: $CURRENT_VERSION → $NEW_VERSION"
  echo "==> .love artifact filename: $LOVE_FILENAME"
  # macOS sed needs -i '' or -i.bak; use the latter for portability with Linux.
  sed -i.bak -E "s/(consts\.BUILD_VERSION[[:space:]]*=[[:space:]]*)\"[^\"]+\"/\\1\"$NEW_VERSION\"/" "$CONSTS_FILE"
  rm "${CONSTS_FILE}.bak"
  # Rewrite all unofficial-panel-attack-*.love references in the workflow
  # so the GitHub Action publishes the artifact under the new name.
  # Matches the current default (-team-vs) AND any prior -patch-<name>.
  sed -i.bak -E "s|unofficial-panel-attack[a-z0-9-]*\.love|${LOVE_FILENAME}|g" "$WORKFLOW_FILE"
  rm "${WORKFLOW_FILE}.bak"
  git add "$CONSTS_FILE" "$WORKFLOW_FILE"
  # --allow-empty: if sed didn't actually change anything (e.g. file was
  # already at $NEW_VERSION from a manual edit), still create the commit
  # so the deploy point lands as a marker in git log.
  git commit --allow-empty -m "deploy: build $NEW_VERSION"
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

