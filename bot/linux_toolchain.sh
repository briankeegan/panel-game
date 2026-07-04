#!/bin/bash
# Linux (Claude Code web container) toolchain bootstrap — the container image loses
# /usr/bin/luajit and ~/.luarocks on restart; run this before any bot/server work.
# Usage: bash bot/linux_toolchain.sh && eval "$(luarocks path --local --lua-version 5.1)"
set -e
command -v luajit >/dev/null 2>&1 || apt-get install -y luajit lua5.1 liblua5.1-0-dev luarocks libsqlite3-dev >/dev/null
for m in luasocket luafilesystem luautf8 lsqlite3; do
  luajit -e "require('${m/luasocket/socket}')" 2>/dev/null && continue
  luarocks install --local "$m" --lua-version 5.1 >/dev/null
done
eval "$(luarocks path --local --lua-version 5.1)"
luajit -e "require('socket'); require('lfs'); print('lua toolchain OK')"
