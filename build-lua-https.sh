#!/bin/bash
# Builds the lua-https native module for the updater shell on the CURRENT host.
# LÖVE 11.5 doesn't bundle `https`, so the updater needs this to make secure
# GitHub requests. The result is committed-by-CI / fetched at package time, but
# this lets you build the local-host one (macOS) so build-shells.sh can run.
#
# VALIDATED on macOS (Intel): produces updater-shell/https/macos/https.so, which
# `require("https")` loads under LÖVE 11.5 to hit api.github.com (HTTP 200).
#
# Windows/Linux: build these in CI (.github/workflows/build-shells.yml lua-https
# matrix) — schannel/openssl backends + a LuaJIT import lib that aren't trivial
# to produce off-host. This script only does the host platform.

set -euo pipefail
cd "$(dirname "$0")"

command -v cmake  >/dev/null || { echo "!! cmake not found  (brew install cmake)";  exit 1; }
command -v luajit >/dev/null || { echo "!! luajit not found (brew install luajit)"; exit 1; }

SRC="../.lua-https-src"
[ -d "$SRC" ] || git clone --depth 1 https://github.com/love2d/lua-https.git "$SRC"
rm -rf "$SRC/build"

host="$(uname -s)"
case "$host" in
  Darwin)
    LUAJIT_PREFIX="$(brew --prefix luajit)"
    LUAJIT_LIB="$(ls "$LUAJIT_PREFIX"/lib/libluajit-5.1.*.dylib | head -1)"
    # NSURL backend (no external TLS deps). Universal so it covers Intel+Apple Silicon;
    # drop -DCMAKE_OSX_ARCHITECTURES if your toolchain can't cross-compile.
    cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
      -DLUAJIT_INCLUDE_DIR="$LUAJIT_PREFIX/include/luajit-2.1" \
      -DLUAJIT_LIBRARY="$LUAJIT_LIB"
    cmake --build "$SRC/build" --config Release
    dest="updater-shell/https/macos/https.so" ;;
  Linux)
    cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
      -DUSE_CURL_BACKEND=OFF -DUSE_OPENSSL_BACKEND=ON
    cmake --build "$SRC/build" --config Release
    dest="updater-shell/https/linux/https.so" ;;
  *) echo "!! unsupported host $host — build Windows https.dll in CI"; exit 1 ;;
esac

lib="$(find "$SRC/build" -name 'https.so' -type f | head -1)"
[ -n "$lib" ] || { echo "!! build produced no https.so"; exit 1; }
mkdir -p "$(dirname "$dest")"
cp "$lib" "$dest"
echo "==> built $dest"
file "$dest"
