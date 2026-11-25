#!/usr/bin/env bash
# Fetch the chaos build v3 and extract its LÖVE game archive.
# The build is pinned by upstream commit AND by sha256, so it can never change under us.
#
#   chaos-bot/game/fetch.sh [out_dir]      (default: chaos-bot/game/build)
#
# Result: <out_dir>/game/  holds main.lua, conf.lua, client/, common/ ... (runnable with `love <out_dir>/game`)
set -euo pipefail

UPSTREAM_REPO="chaos9520/panel-game"
UPSTREAM_COMMIT="4da6c5dd9249c58c53362c9e2204c5c0138ec203"   # branch chaos_build, "update test build"
ZIP_NAME="test-build_v3.zip"
ZIP_SHA256="ec5baf0025bd16c62a12dfde51770071e58008650311bab928c62463daa91336"

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
mkdir -p "$out"
zip="$out/$ZIP_NAME"

if [ ! -f "$zip" ] || ! echo "$ZIP_SHA256  $zip" | sha256sum -c --status; then
  url="https://github.com/$UPSTREAM_REPO/raw/$UPSTREAM_COMMIT/$ZIP_NAME"
  for attempt in 1 2 3 4; do
    if curl -fsSL --retry 2 -o "$zip.part" "$url"; then break; fi
    echo "download attempt $attempt failed" >&2
    sleep $((attempt * 5))
  done
  mv "$zip.part" "$zip"
fi
echo "$ZIP_SHA256  $zip" | sha256sum -c -

rm -rf "$out/zip" "$out/game"
mkdir -p "$out/zip" "$out/game"
unzip -q "$zip" -d "$out/zip"
# panel.exe is love.exe with the game's .love (a zip) appended; unzip skips the exe prefix.
unzip -q "$out/zip/test-build_v3/panel.exe" -d "$out/game" || [ -f "$out/game/main.lua" ]
test -f "$out/game/main.lua"
echo "chaos v3 game extracted to $out/game"
