# Panel Attack — Claude Code Guide

## What This Is

Panel Attack is a Tetris-like multiplayer puzzle game. The codebase has two main parts:
- **Client** — LÖVE2D (Lua) game engine, lives in `client/`
- **Server** — Pure LuaJIT TCP server, entry point is `serverLauncher.lua`

Shared game logic lives in `common/`. Tests live alongside their modules in `*/tests/`.

## This Branch: `bramp/multi-player`

Active development branch for team multiplayer. **This branch never connects to production.**
- `client/src/scenes/MainMenu.lua:85` — defaults to `localhost` (not `panelattack.com`)
- `main.lua:298` — crash reporter disabled
- See `docs/MULTIPLAYER_DESIGN.md` for the multiplayer design spec

## Running Locally (macOS)

### Dependencies
Install once:
```sh
brew install luajit lua5.1 luarocks sqlite3
luarocks install --local luasocket --lua-version 5.1
luarocks install --local luafilesystem --lua-version 5.1
luarocks install --local luautf8 --lua-version 5.1
luarocks install --local lsqlite3 --lua-version 5.1
luarocks install --local lsqlite3complete --lua-version 5.1  # macOS fallback for lsqlite3
```

Also needs **love** (11.5 or newer) for the client. Add it to PATH in `~/.zshrc`. CI uses a panel-attack-hosted bundle tagged `love2d-12.0` (a pre-release of love's `12.x` dev branch — not an official love2d release); the code's `conf.lua` adapts to either via a `usingModernLove` wrapper.

### Scripts
```sh
zsh run_server.sh        # start local server (localhost:49569)
zsh run_client.sh        # start game client
zsh run_server_tests.sh  # run server-side test suite, headless and isolated
zsh run_tests.sh         # run client/common test suite (requires love)
```

Run server first, then client. Client connects to localhost automatically on this branch.

### How tests work

**Server tests** (`LoginTests`, `LeaderboardTests`, `RoomTests`, `TeamRoomTests`, `ServerTests`, `LooseSyncServerTests`):
- Run via `zsh run_server_tests.sh` — invokes `serverTestRunner.lua` in its own luajit process
- Fully isolated: uses `MockPersistence` + `MockConnection`, does NOT bind a port, does NOT touch the real sqlite DB, does NOT kill your running dev server. Safe to run while `zsh run_server.sh` is live.
- Do NOT run these through love — `lfs` and `lsqlite3` are not available in the love environment
- Do NOT run individual test files directly with `luajit server/tests/Foo.lua` — they depend on globals set up by `server.server_globals`

**Client/common tests** (`PuzzleTests`, `NetworkProtocolTests`, etc.):
- Run via `zsh run_tests.sh` — uses love to run `testLauncher.lua`
- These cannot run via luajit — they depend on love APIs

**First time:** Set a player name in-game (Main Menu → Set Name) before connecting.

**Bot tests, headless, on Linux (a sandbox or a runner):** `run_server_tests.sh`
is zsh-and-macOS. The bot verifiers run straight from `luajit` once the paths
are set, and every one of them needs `bot/headlessBoot`, which pulls in
`socket`, `lua-utf8` and `lfs`:

```sh
apt-get install -y luajit luarocks
luarocks --lua-version 5.1 install luautf8
luarocks --lua-version 5.1 install luafilesystem
LUA_PATH="./?.lua;./common/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;" \
LUA_CPATH="./common/lib/?.so;./common/lib/?/?.so;/usr/local/lib/lua/5.1/?.so;;" \
  luajit bot/tests/decisionVerify.lua
```

The bundled `common/lib/socket` is Linux-compiled, so it loads here and is
the one that needs the `?/?.so` entry. `common/lib` is not on the default
path — without it `require("socket")` fails while the file is sitting right
there.

### Common Issues
- `love: command not found` — love not in PATH, add to `~/.zshrc`
- `slice is not valid mach-o file` — bundled `.so` files are Linux-compiled; install the luarocks equivalents above
- `symbol not found: _sqlite3_enable_load_extension` — macOS sqlite3 is stripped; `lsqlite3complete` handles this (already wired into `server/PADatabase.lua`)
- `luarocks path` issues — scripts use `eval "$(luarocks path --local --lua-version 5.1)"` to set correct paths

## Architecture

```
serverLauncher.lua          # server entry point
client/src/
  scenes/MainMenu.lua       # server list (add custom servers to debugMenuItems)
  network/NetClient.lua     # client networking
  network/LoginRoutine.lua  # login handshake
server/
  server.lua                # main server loop, connection handling
  server_globals.lua        # config (port, engine version)
  PADatabase.lua            # SQLite wrapper
  Room.lua                  # match rooms
  Leaderboard.lua           # ELO rankings
common/
  engine/consts.lua         # shared constants (SERVER_LOCATION etc.)
  network/NetworkProtocol.lua # message format (TCP, JSON, version "006")
  lib/                      # bundled Lua libs (socket, utf8, etc.)
```

## Network Protocol
- Raw TCP on port `49569`
- Messages: single-char prefix + JSON body + `←J←` terminator
- Handshake version: `006` (`common/network/NetworkProtocol.lua`)
- Per-server player accounts stored client-side in `servers/{SERVER_IP}/user_id.txt`

## Logs

**Client:** terminal + saved to `logs/client.log`
- Read: `tail -f logs/client.log` or `cat logs/client.log`
- Always use `zsh run_client.sh` — never run love directly or hardcode the love path

**Local server:** terminal + saved to `logs/server.log`
- Read: `tail -f logs/server.log` or `cat logs/server.log`
- If port 49569 is already in use, `run_server.sh` kills the previous instance automatically before starting

**Remote server (Vultr — 104.156.250.136):**
```sh
ssh root@104.156.250.136
journalctl -u panel-attack -f      # live tail
journalctl -u panel-attack         # full history
```

`logs/` is gitignored.

## Key Conventions
- Lua 5.1 / LuaJIT throughout (no Lua 5.4 features)
- Server runs headless via `luajit`; client runs via `love`
- Tests are wired into `testLauncher.lua` and also run on server startup
- No environment variables for config — everything in `server/server_globals.lua`
- Data files (`PADatabase.sqlite3`, `players.txt`, etc.) are gitignored — auto-created on first run

## Putting a bot on the live server

**This sandbox cannot reach `104.156.250.136:49569`. A GitHub runner can.**
Every route to the live server goes through Actions, so "unreachable from
here" is never the answer — check the workflows first.

- **`workflow_dispatch` only registers workflows that exist on the default
  branch, which is `beta`.** A new workflow file on a feature branch cannot
  be triggered at all: the dispatch API returns 404 and the file looks fine.
  A registered workflow, though, runs whatever content is on the ref you
  dispatch — so a new mode goes INTO an existing registered workflow rather
  than into a new file. `bot-prod-smoke-test.yml` is the registered one.
- `mode: live` puts ONE bot in the lobby under a real name and keeps it
  there, so a human can find it and play it. `mode: prod-vs` is a different
  thing: two throwaway accounts in a PRIVATE room against each other, which
  no player can join. Dispatch `live` with `ref: bramp/multi-player`.
- **A job is capped at 6 hours, so `live` is a session, not a service.**
  Re-dispatch to bring the bot back. For something permanent, run
  `bot/beverly.sh` on the server box under systemd or tmux — it runs until
  killed. `deploy-server.yml` is the SSH route to that box and needs the
  `VULTR_SSH_KEY` secret; it also lives only on this branch, so it is not
  dispatchable either until it reaches `beta`.
- **`bot/winRateTest.lua` is not a way to run a named bot.** It hardcodes
  the account names `wH…`/`wJ…` and runs `brain = "search"`, so handing it a
  PanelEval weight set runs the wrong brain under the wrong name. The live
  path is `bot/playBot.lua … weighted`, which `bot/plamp.sh` wraps.
- A weight set is only a bot when paired with the switches it was found
  under, so `bot/profiles/*.json` carries `depth`, `beam`, `rise`,
  `reaction` and `density` alongside the weights, and `WeightedBrain` reads
  them from there. `bot/beverly.sh` and `bot/plamp.sh` differ only in the
  profile and the name; both hand off to one launcher.
- Check the name length (16 chars, server limit) and that the profile file
  exists BEFORE connecting. A rejected name and a missing weight set both
  look identical to "the bot never showed up" three hours later.

## Self-Hosting
See `docs/SelfHosting.md` for full Hetzner VPS setup guide.
