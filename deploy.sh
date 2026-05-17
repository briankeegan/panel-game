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


 Yes to all three — here's the order it actually happens in.

  When you make a combo or top out, your client tells the server, and the server just forwards that to everyone else without checking. Those messages — garbage sent, player died — land on each client and apply instantly. That's the real game state, and it's the same for everyone within a network round-trip.

  The opponent boards you see on your screen are a separate thing — your client re-simulates them from the input packets they're streaming, so they can lag a little and look slightly different from one player's machine to the next. But that doesn't matter, because nothing on those boards feeds back into your game. So yes, someone might still look alive on your screen for another second after they've actually died; your game already knows and has stopped sending garbage their way. The animation just catches up after.

Yes to all three.

When you send garbage, top out client lets the server know - and the server forwards to everyone else. In the other direction... you recieve info about the incoming garbage, and if the game ended. 

The visual representation of the opponent's board is a separate thing that is re-simulated locally, so it can lag and look different across machines, but that doesn't affect the actual game state. Its WORSE then the original - kinda on purpose.  You may see a delay... that doesn't mean the other player is actual behind. (I'm thinking of adding time info about that visually)

Prioritizing the game play - to be as MUCH like offline as possible. Thats why netcode for match-start synchronization is so important - if its off - the game state will be off the whole game. 

TLDR; Get ALL the games to line up at start... if communcation fails... that when timeout/deaths can happen... in those scenarios.. players will send/recieve garbage later.  At END game... player send when they died... so fits close... ist just based on that timestamp.

Honestly... I've not focused on the edge case death scenarios yet... though have thought about them. I'm trying avoid server side evulation.


