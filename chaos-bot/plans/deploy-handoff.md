# Handoff: the chaos bot, for the agent that will deploy it

Written 2026-11-26 by the agent building the bot, for a different agent that will put it on the real chaos server. This page lists
facts and where to find them. It is not permission: whoever deploys gets the go-ahead from the owner, and from the server's
operator if the owner does not run that server.

## 1. What the bot is

- A bot for the **chaos build** of Panel Attack: upstream `chaos9520/panel-game`, branch `chaos_build`, file `test-build_v3.zip`,
  pinned to commit `4da6c5dd9249c58c53362c9e2204c5c0138ec203` and zip sha256
  `ec5baf0025bd16c62a12dfde51770071e58008650311bab928c62463daa91336` (`chaos-bot/game/fetch.sh`). The upstream repo is read-only
  to us.
- The bot is a native C library, `libgambit.so`. It is a frozen copy of Gambit (from briankeegan/GameCreator) rebuilt on a chaos
  engine (`chaos-bot/engine/ca.c`). The chaos client loads it through LuaJIT FFI (`chaos-bot/gambit/lua/GambitNative.lua`). Every
  frame it answers with the stack's inputs.
- Hands run at vanilla speed (a swap every 12 frames, a cursor step every 4), with no DAS. Chaos itself has no input limit.
- **Status:** survival at Level 10 passes the gate (one bot, 8/8 on seeds 1-10) and gets 22/24 on new seeds 11-16; Level 9 is 36/40.
  Attack (garbage sent) is not done yet, and neither are 7/8 colours or Line Clear. The live log is `chaos-bot/plans/chaos-goal.md`.
  **Branch to deploy from: `bramp/multi-player`.** `briankeegan/panel-game` has no `main`. The bot is not on `bramp/multi-player`
  yet. It lives only on `ccr-9ee25bfb-744765`, so it has to be merged into `bramp/multi-player` with a pull request first. The
  bot-building agent may not push to that branch.

## 2. Where the files are

- Repo `briankeegan/panel-game`, branch **`ccr-9ee25bfb-744765`**, folder **`chaos-bot/`**:
  - `gambit/`: the bot's C source. The build line is in `bench/play.sh`:
    `clang -O3 -march=native -pthread -fPIC -shared -Wl,-z,nodelete -DPA_HEAP -w native.c host.c -lm -o libgambit.so`.
    For a machine other than the one it was built on, drop `-march=native`. Windows needs a DLL build, which has not been tried.
  - `gambit/lua/GambitNative.lua`, `gambit/lua/board.lua`: the Lua side, the FFI binding.
  - `profiles/chaos.words`: the bot's settings file (`GC_GAMBIT_WORDS`).
  - `client/chaosbot/`: the launcher laid into the game (`boot.lua` starts a Training/Challenge match with no menus and reads its
    settings from `CHAOSBOT_*` environment variables; `InputBudget.lua`, `ThinkBudget.lua`). It plays offline only. It has no
    online or lobby code.
  - `bench/play.sh`: shows exactly how one game is put together: build the .so, fetch the build, copy `client/chaosbot` into the
    extracted game, append `require("chaosbot.boot")` to `main.lua`, then run LÖVE 12 under xvfb.
  - `docs/CHAOS_RULES.md`, `docs/LEVELS.md`, `docs/NUMBERS.md`: chaos rules and numbers read from the v3 Lua.
  - `reference/chaos-v3/`: a copy of the v3 build's `common/` Lua.
- Workflows (the only files outside `chaos-bot/`): `.github/workflows/chaos-bot-games.yml` (starts on a push to the branch that
  changes `chaos-bot/bench/request.txt`) and `.github/workflows/chaos-bot-checks.yml`.

## 3. The servers (as the v3 client names them)

From the extracted v3 Lua (`client/src/scenes/MainMenu.lua`, `common/engine/consts.lua`):

- (Answers to the deploy agent's questions are in section 6.)
- **`alt-server.chaos952.org`**: the server the chaos build's "VS online" menu opens (`Lobby({serverIp = "alt-server.chaos952.org"})`).
  It gives no port, so the client's default is used (49569 is the default elsewhere in the client). This is the chaos server. It
  appears to belong to the chaos build's author (chaos9520), not to the owner. Confirm who runs it before connecting a bot.
- `panelattack.com` (consts.SERVER_LOCATION, port 49569): vanilla Panel Attack's main server. `betaserver.panelattack.com:59569` is
  in the debug menu.
- `104.156.250.136:49569`: the **panel-game fork's** self-hosted production server (`.github/workflows/bot-prod-smoke-test.yml`).
  It is not the chaos server. The bot-building agent was told never to touch it.
- The chaos server's source has no action limit. The 76-actions-per-600-frames limit belongs to the panel-game fork, not to chaos.

To play online the bot needs a part that does not exist yet: logging in through the Lobby, joining or creating a room, and having
`GambitNative` answer for the local stack in a networked match instead of `boot.lua`'s offline Training match. The bot must answer
within each frame (the logs record late moves; it has 0 now).

## 4. GitHub, for an agent looking things up

- Our repo: `briankeegan/panel-game`. The bot-building agent pushes only to `ccr-9ee25bfb-744765` and never to `bramp/multi-player`,
  `beta`, `claude/newsey-game-ask-qa8u5e`, or GameCreator's `main`.
- Upstream chaos build (read-only): `chaos9520/panel-game`, branch `chaos_build`. The raw zip URL is in `chaos-bot/game/fetch.sh`.
- LÖVE 12 for Linux is downloaded from `panel-attack/panel-game` release `love2d-12.0` (see `chaos-bot-games.yml`).
- Game results are Actions artifacts of the "chaos-bot games" workflow (one per game: `result.txt`, `gambit.log`, `client.log`).

## 5. Rules the bot-building agent works under (so the two don't collide)

- Never touch the infrastructure: the Cloudflare Worker, KV, Clubhouse PRs, repository secrets (PANEL_GAME_TOKEN, ADMIN_TOKEN,
  GITHUB_TOKEN as a secret), the live servers (104.156.250.136), or ranmaru-stats. Never store tokens in any repo.
- Nothing outside `chaos-bot/` except the two workflow files. No shared names, concurrency groups or artifacts with Gambit's
  workflows. The games workflow uses the concurrency group `chaos-bot-games`. Leave it to the bot-building agent.
- Don't edit `chaos-bot/` on `ccr-9ee25bfb-744765` while the bot-building agent is working there. Take a commit and copy from it.

## 6. Answers to the deploy agent's questions (2026-11-26)

1. **Is the field renaming all the adapting GambitNative needs?** For the stack, yes: before every frame `boot.lua` sets
   `stopWatch = game_stopwatch or clock`, `stopWatchIsRunning = game_stopwatch_running and not do_countdown`,
   `isToppedOut = hasPanelsInTopRow`, and copies `stopWatch` onto each garbage source. Per match it also does the following
   (`boot.lua` `attach`):
   - finds the local player's stack (`cs.player == GAME.localPlayer`);
   - collects the garbage sources aimed at it (`match.engine.garbageSources[engine]`);
   - calls `Gambit.new({})` and `bot:startMatch(engine, match.engine)`;
   - replaces `client.send_controls` with: refresh the names, `key = bot:input(engine, sources, nil)`,
     `engine:receiveConfirmedInput(key)`. Online, the input has to go through the client's normal networked input path instead.
   - `countSends` only counts garbage sent for the report.
   - Everything before `attach` (Training/Challenge settings, seeds, claiming a controller) is the offline launcher's alone.
   - `bot:input`'s third argument (`view`, the opponent's board) is nil offline. GambitNative also supports a wired opponent copy,
     inherited from the fork's bot, but that path is untested on chaos.
   - GambitNative `require`s `ThinkBudget` and `InputBudget` (from `common.engine.computerPlayers.*`, else `bot.*`). `play.sh`
     copies the chaos versions to `game/bot/`. Use the chaos `InputBudget.lua` (no action limit), not the fork's.
2. **Which branch:** `bramp/multi-player`, after the bot is merged into it (see section 1).
3. **Does it need chaos.words or the CHAOSBOT_* variables?**
   - `CHAOSBOT_*`: no. They are read only by `boot.lua` to set up the offline match.
   - `profiles/chaos.words`: yes, it is required. GambitNative reads it at load (`GC_GAMBIT_WORDS`, else
     `GC_GAMBIT_DIR/gambit.words`), and fails without it. Its `setup 12 12 4 ...` line holds the vanilla hand speed.
   - Also set `GC_GAMBIT_DIR` (the directory holding `libgambit.so` and `lua/board.lua`). Optionally set `GC_GAMBIT_LOG` (the log;
     empty means none).
   - Optional tuning: `GC_GAMBIT_WORKERS`, `GC_GAMBIT_CPUS`, `GC_GAMBIT_WORKER_CPUS`, `GC_GAMBIT_HEAP_MB` (`host.c`).
   - The bot reads its level, colours and other chaos settings from the stack itself, so the match's own settings apply.
