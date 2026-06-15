#!/bin/zsh
# Launch one bot that hosts an open 2p VS room for a human to join and play.
# Usage: zsh run_play.sh [ip] [port] [name] [difficulty] [modelDir]
source ~/.zshrc 2>/dev/null
eval "$(luarocks path --local --lua-version 5.1)"
cd "$(dirname "$0")"
luajit bot/playBot.lua "$@"
