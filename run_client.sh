#!/bin/zsh
source ~/.zshrc 2>/dev/null
cd "$(dirname "$0")"
project_root=$(pwd)
mkdir -p logs

# Running this script implies local development, so surface the Localhost server
# (and other debug servers) in the main menu automatically. Override by exporting
# PA_SHOW_LOCAL=false before invoking the script.
: ${PA_SHOW_LOCAL:=true}

# Accept zero or more player names. With no args, launch a single default client.
# With one or more, launch one client per name in parallel — useful for local
# multiplayer testing. When more than one client is launched they are tiled into
# a 2-column grid across the desktop (one window per cell) by patching each
# client's saved conf.json with the right windowX/windowY/windowWidth/windowHeight
# *before* launching it. Export PA_NO_TILE=1 to skip the tiling.
if [[ $# -eq 0 ]]; then
  set -- "Player1"
fi

client_count=$#
do_tile=false
if [[ $client_count -gt 1 && -z "$PA_NO_TILE" ]]; then
  do_tile=true
fi

# Desktop size (in points) for tiling.
screen_left=0; screen_top=0; screen_w=1920; screen_h=1080
if $do_tile; then
  bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null)
  if [[ -n "$bounds" ]]; then
    # bounds => "left, top, right, bottom"
    IFS=', ' read -rA b <<< "$bounds"
    screen_left=${b[1]:-0}
    screen_top=${b[2]:-0}
    screen_w=$(( ${b[3]:-1920} - screen_left ))
    screen_h=$(( ${b[4]:-1080} - screen_top ))
  fi
fi

# Grid geometry: 2 columns, enough rows for every client, leaving room for the
# macOS menu bar at the top so each window's title bar stays grabbable.
cols=2
rows=$(( (client_count + cols - 1) / cols ))
top_margin=28
cell_w=$(( screen_w / cols ))
cell_h=$(( (screen_h - top_margin) / rows ))

# Where LÖVE stores per-identity save data on macOS.
love_save_root="$HOME/Library/Application Support/LOVE"

# Patch a client's saved conf.json so its window opens at (x,y) with size (w,h),
# windowed and non-maximized. Preserves any other settings already in the file.
patch_client_window() {
  local conf_file="$1" wx="$2" wy="$3" ww="$4" wh="$5"
  ( cd "$project_root" && luajit - "$conf_file" "$wx" "$wy" "$ww" "$wh" <<'LUA'
package.path = package.path .. ";./?.lua"
local json = require("common.lib.dkjson")
local path = arg[1]
local wx, wy, ww, wh = tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5])
local cfg = {}
local f = io.open(path, "r")
if f then
  local data = f:read("*a"); f:close()
  local decoded = json.decode(data)
  if type(decoded) == "table" then cfg = decoded end
end
cfg.windowX, cfg.windowY = wx, wy
cfg.windowWidth, cfg.windowHeight = ww, wh
cfg.maximizeOnStartup = false
cfg.fullscreen = false
cfg.borderless = false
local out = assert(io.open(path, "w"))
out:write(json.encode(cfg))
out:close()
LUA
  ) || echo "run_client.sh: warning — couldn't position window for $conf_file" >&2
}

pidfiles=()
love_pids=()

idx=0
for player_name in "$@"; do
  identity="Panel Attack $player_name"
  pidfile="/tmp/panel-attack-client-${player_name}.pid"

  # Kill only the previous love instance launched with THIS identity, so multiple
  # clients (one per player name) can still run side-by-side for local testing.
  if [[ -f "$pidfile" ]]; then
    prev_pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
      kill "$prev_pid" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "$pidfile"
  fi

  if $do_tile; then
    col=$(( idx % cols ))
    row=$(( idx / cols ))
    win_x=$(( screen_left + col * cell_w ))
    win_y=$(( screen_top + top_margin + row * cell_h ))
    save_dir="$love_save_root/$identity"
    mkdir -p "$save_dir"
    patch_client_window "$save_dir/conf.json" "$win_x" "$win_y" "$cell_w" "$cell_h"
  fi

  LOVE_IDENTITY="$identity" PLAYER_NAME="$player_name" PA_SHOW_LOCAL="$PA_SHOW_LOCAL" love "$project_root" &
  love_pid=$!
  echo "$love_pid" > "$pidfile"
  pidfiles+=("$pidfile")
  love_pids+=("$love_pid")
  idx=$(( idx + 1 ))
done

cleanup() {
  trap - EXIT INT TERM HUP
  # Only fires when the script itself is terminating (Ctrl+C, SIGTERM, or after
  # `wait` returns because every client has already exited). Tear down only the
  # love instances we tracked — closing one window naturally won't reach here,
  # because `wait pid1 pid2 ...` keeps blocking until ALL listed pids exit.
  for p in "${love_pids[@]}"; do
    # `love` on macOS is typically a wrapper script around Love.app's binary,
    # so kill its child too in case our tracked pid is the wrapper.
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  for f in "${pidfiles[@]}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT INT TERM HUP
wait "${love_pids[@]}"
