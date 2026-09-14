#!/bin/bash
# Headless end-to-end test of the Linux launcher in a throwaway Ubuntu container.
# Downloads the published launcher, runs the updater headless (xvfb), and asserts
# it FETCHED versions, DOWNLOADED the game, and BOOTED into a game scene.
# Exits 0 on pass, 1 on fail. This is the regression guard for the class of bug
# that ate an entire night (lua-https not de-chunking GitHub's chunked responses).
#
# Requires colima + docker:  brew install colima docker && colima start
# Usage:
#   zsh test/docker/linux-launcher-test.sh [LAUNCHER_ZIP_URL]
# Env: IMAGE (default ubuntu:22.04 — glibc 2.35), RUNTIME_SECS (default 40)

set -euo pipefail

LAUNCHER_URL="${1:-https://github.com/briankeegan/panel-game/releases/download/launcher/unofficial-panel-attack-ffa-and-team-linux.zip}"
IMAGE="${IMAGE:-ubuntu:22.04}"
RUNTIME_SECS="${RUNTIME_SECS:-40}"

command -v docker >/dev/null 2>&1 || { echo "docker not found. Run: brew install colima docker && colima start"; exit 2; }
docker info >/dev/null 2>&1 || { echo "docker daemon unreachable. Run: colima start"; exit 2; }

# Container script. Heredoc is unquoted so $LAUNCHER_URL/$RUNTIME_SECS expand here
# on the host; everything else is plain container shell.
read -r -d '' CSCRIPT <<EOF || true
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl unzip ca-certificates xvfb \\
  libgl1-mesa-dri libgl1 libglx-mesa0 libegl1 \\
  libx11-6 libxext6 libxrandr2 libxcursor1 libxi6 libxinerama1 libxfixes3 \\
  libssl3 libopenal1 >/dev/null 2>&1
export SDL_AUDIODRIVER=dummy
cd /root
curl -fsSL "$LAUNCHER_URL" -o l.zip
# -o + </dev/null: the love-build AppDir has a .DirIcon name collision (unzip would
# prompt and CI/EOF stdin makes it fail); bin/ lib/ are stored mode 000 (no search
# bit) so chmod -R restores access before we can run the binary.
unzip -q -o l.zip -d app < /dev/null
cd app && chmod -R u+rwX .
timeout $RUNTIME_SECS xvfb-run -a ./AppRun > /root/run.log 2>&1 < /dev/null || true
echo "===UPDATER_LOG==="
cat "/root/.local/share/Unofficial Panel Attack FFA & Team/updater.log" 2>/dev/null || true
echo "===BOOT_EVIDENCE==="
grep -iE "fetched [0-9]+ versions|Launching version|TitleScreen|Pushing scene" /root/run.log | tail -8 || true
echo "===DOWNLOADED_GAME==="
find "/root/.local/share/Unofficial Panel Attack FFA & Team/updater" -name '*.love' 2>/dev/null || true
EOF

echo "Running Linux launcher test in $IMAGE (this pulls deps + the launcher, ~1-2 min)..."
OUT="$(docker run --rm -i "$IMAGE" bash -s <<<"$CSCRIPT" 2>&1)"
echo "$OUT"
echo
echo "================ VERDICT ================"
if   echo "$OUT" | grep -qiE "fetched [0-9]+ versions" \
  && echo "$OUT" | grep -qiE "TitleScreen|Pushing scene" \
  && echo "$OUT" | grep -q "game.love"; then
  echo "PASS — launcher fetched versions, downloaded the game, and booted into a scene."
  exit 0
else
  echo "FAIL — one of {fetch, download, boot} did not happen. See output above."
  exit 1
fi
