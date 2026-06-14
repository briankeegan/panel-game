#!/bin/zsh
# Run the headless bot client (Phase 0 spike).
#
# Mirrors run_server_tests.sh: sets the luarocks paths so luajit finds
# luasocket/lfs, then runs the bot under plain luajit (no LÖVE).
#
# Usage: zsh run_bot.sh [ip] [port] [name]
#   defaults: 127.0.0.1 49569 BotBella
source ~/.zshrc 2>/dev/null
eval "$(luarocks path --local --lua-version 5.1)"
set -o pipefail
cd "$(dirname "$0")"

luajit bot/spikeLogin.lua "$@"
