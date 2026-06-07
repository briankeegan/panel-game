#!/bin/bash
# Builds the auto-updating desktop shells for "Unofficial Panel Attack FFA & Team" using
# love-build against updater-shell/. VALIDATED recipe (macOS shell confirmed:
# bundles LÖVE 11.5 + https.so + the embedded base game).
#
# Key facts learned the hard way:
#  - love-build's main branch needs LÖVE 12 to RUN (uses mountFullPath etc.), so
#    we use its STANDALONE prebuilt release, which bundles its own LÖVE. This does
#    NOT change what the shells ship — build.lua's love='11.5' controls that.
#  - love-build writes artifacts to its own save dir:
#      macOS:  ~/Library/Application Support/love-build/output/<folder>/
#      Linux:  ~/.local/share/love-build/output/<folder>/
#    where <folder> = lower(name)_version with spaces->_ (here: panel_attack_ffa_&_team_2.0)
#  - Windows/Linux shells need their https.dll/.so under updater-shell/https/<plat>/.
#    Only macOS can be fully built locally on a Mac; use build-shells.yml (CI) for all 3.
#
# Output: copies the per-platform .zip artifacts into ../dev-build-shells/

set -euo pipefail
cd "$(dirname "$0")"

LB_VERSION="${LB_VERSION:-0.9}"
OUT_DIR="../dev-build-shells"
CACHE="../.love-build-tool"

# 1) Refresh the embedded offline base game .love
echo "==> Building embedded base game .love"
./build.sh just-love
mkdir -p updater-shell/team/0
cp ../dev-build/panel-attack.love updater-shell/team/0/game.love

# 2) Fetch the standalone love-build tool for this host OS (bundles its own LÖVE)
host="$(uname -s)"
case "$host" in
  Darwin) lb_os=macos;  lb_run() { "$CACHE/love-build.app/Contents/MacOS/love" "$@"; }
          save_out="$HOME/Library/Application Support/love-build/output" ;;
  Linux)  lb_os=linux;  lb_run() { "$CACHE/love-build" "$@"; }
          save_out="$HOME/.local/share/love-build/output" ;;
  *) echo "!! unsupported host $host (use the CI workflow)"; exit 1 ;;
esac
if [ ! -e "$CACHE/love-build.app" ] && [ ! -e "$CACHE/love-build" ]; then
  echo "==> Downloading standalone love-build $LB_VERSION ($lb_os)"
  mkdir -p "$CACHE"
  curl -fsSL "https://github.com/ellraiser/love-build/releases/download/v${LB_VERSION}/love-build-${LB_VERSION}-${lb_os}.zip" -o "$CACHE/lb.zip"
  unzip -q -o "$CACHE/lb.zip" -d "$CACHE"
  [ "$lb_os" = macos ] && xattr -dr com.apple.quarantine "$CACHE/love-build.app" 2>/dev/null || true
fi

# 3) Warn about missing per-platform https libs (built by build-shells.yml in CI)
for f in win64/https.dll macos/https.so linux/https.so; do
  [ -f "updater-shell/https/$f" ] || echo "    note: missing updater-shell/https/$f (that platform's shell won't have https)"
done

# 4) Run love-build (targets come from build.lua's `platforms`)
# Wipe stale output folders first so collection can't grab an old build.
rm -rf "$save_out"/* 2>/dev/null || true
echo "==> Running love-build"
lb_run "$(pwd)/updater-shell/main.lua" "macos,windows,linux" >/tmp/love-build.log 2>&1 || true
grep -E "built .* successfully|build finished|error" /tmp/love-build.log | tail -10 || true

# 5) Collect the artifacts from love-build's save dir
echo "==> Collecting artifacts"
mkdir -p "$OUT_DIR"
folder=$(ls -t "$save_out" 2>/dev/null | head -1)
if [ -n "$folder" ] && [ -d "$save_out/$folder" ]; then
  for plat in macos windows linux; do
    f=$(find "$save_out/$folder" -iname "*-$plat.zip" | head -1)
    [ -n "$f" ] && cp "$f" "$OUT_DIR/unofficial-panel-attack-ffa-and-team-$plat.zip" && echo "    collected $plat"
  done
  # love-build's macOS .app is unsigned, which macOS reports as "damaged or
  # incomplete". Ad-hoc re-sign it (only possible on a Mac) so it launches.
  macz_abs="$(cd "$OUT_DIR" && pwd)/unofficial-panel-attack-ffa-and-team-macos.zip"
  if [ "$host" = Darwin ] && command -v codesign >/dev/null && [ -f "$macz_abs" ]; then
    echo "==> Fixing + ad-hoc signing the macOS app"
    tmp=$(mktemp -d)
    unzip -q "$macz_abs" -d "$tmp"
    chmod -R u+rwx "$tmp"   # love-build's .app dirs are 700 and block find/edit
    app=$(find "$tmp" -iname "*.app" -maxdepth 2 -print 2>/dev/null | head -1)
    if [ -n "$app" ]; then
      # love-build writes the app name into Info.plist unescaped, so a '&' in the
      # name corrupts the XML ("damaged or incomplete"). Fix BEFORE signing.
      if ! plutil -lint "$app/Contents/Info.plist" >/dev/null 2>&1; then
        sed -i '' 's/ & / \&amp; /g' "$app/Contents/Info.plist"; echo "    fixed Info.plist (& -> &amp;)"
      fi
      xattr -cr "$app"; codesign --force --deep --sign - "$app" >/dev/null 2>&1 && echo "    signed: $(basename "$app")"
      ( cd "$tmp" && rm -f "$macz_abs" && zip -q -r -y "$macz_abs" "$(basename "$app")" )
    else
      echo "    !! could not locate .app to sign"
    fi
    rm -rf "$tmp"
  fi
  echo "==> Shells in $OUT_DIR:" && ls -lh "$OUT_DIR"/*.zip 2>/dev/null
else
  echo "!! no love-build output found under $save_out — check /tmp/love-build.log"
  exit 1
fi
