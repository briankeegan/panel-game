-- THE CHAOS BOT'S LAUNCHER, inside the real chaos v3 client. Appended to the extracted game's main.lua on the runner
-- (chaos-bot/bench/play.sh): once the client has booted, it starts one Training match with no menus -- chaos Level LEVEL, the
-- pattern PATTERN made from SEED -- and has Gambit (libgambit.so on the chaos engine) answer for the player's stack every frame.
-- The game ends at FRAMES frames of play or at the loss; the result goes to OUT as one line of data, and the client quits.
--
-- Env: CHAOSBOT_SEED, CHAOSBOT_PATTERN (training_random | chain_garbage | combo_storm | thicc_combo_storm | insane_combo_storm),
--      CHAOSBOT_GLEVEL (garbage level 1-11), CHAOSBOT_GSPEED (garbage speed 1-11), CHAOSBOT_QUEUE (1 classic, 2 modern, 3 chaos),
--      CHAOSBOT_LEVEL (default 9), CHAOSBOT_MARGIN (1 off, 2 colors, 3 modoki, 4 chaos; default 1), CHAOSBOT_COLORS (default 6),
--      CHAOSBOT_FRAMES (default 21600), CHAOSBOT_OUT (the result file), CHAOSBOT_DRAW_EVERY (draw every nth frame; default 30),
--      GC_GAMBIT_DIR (libgambit.so and lua/board.lua), GC_GAMBIT_WORDS (the profile), GC_GAMBIT_LOG (Gambit's own log).
local env = function(k, d) local v = os.getenv(k); if v == nil or v == "" then return d end; return v end
local SEED = tonumber(env("CHAOSBOT_SEED", "1"))
local PATTERN = env("CHAOSBOT_PATTERN", "combo_storm")
local GLEVEL = tonumber(env("CHAOSBOT_GLEVEL", "9"))
local GSPEED = tonumber(env("CHAOSBOT_GSPEED", "9"))
local QUEUE = tonumber(env("CHAOSBOT_QUEUE", "2"))
local LEVEL = tonumber(env("CHAOSBOT_LEVEL", "9"))
local MARGIN = tonumber(env("CHAOSBOT_MARGIN", "1"))
local COLORS = tonumber(env("CHAOSBOT_COLORS", "6"))
local FRAMES = tonumber(env("CHAOSBOT_FRAMES", "21600"))
local OUT = env("CHAOSBOT_OUT", "chaosbot-result.txt")
local DRAW_EVERY = tonumber(env("CHAOSBOT_DRAW_EVERY", "30"))
-- the patterns as the Training menu lists them: width and height of the pattern's garbage (TrainingMenu:goToCharacterSelect)
local SHAPES = { training_random = { 1, 1 }, chain_garbage = { 6, 6 }, combo_storm = { 4, 1 }, thicc_combo_storm = { 4, 2 },
                 insane_combo_storm = { 3, 1 } }

local function say(s) print("CHAOSBOT " .. s); io.stdout:flush() end
local function result(fields)
  local f = io.open(OUT, "w")
  local parts = {}
  for _, k in ipairs(fields._order) do parts[#parts + 1] = k .. " " .. tostring(fields[k]) end
  local line = "RESULT " .. table.concat(parts, " ")
  if f then f:write(line, "\n"); f:close() end
  say(line)
end

local state, bot, engine, client, sources, startFrame, sentRows, frames = "boot", nil, nil, nil, {}, nil, 0, 0
local healthLostTop, lastHealth = 0, nil
local Gambit

local function finish(reason)
  if state == "done" then return end
  state = "done"
  local overruns, worst, dropped = 0, 0, 0
  if bot then overruns, worst, dropped = bot:budget(); pcall(bot.endMatch, bot) end
  local e = engine or {}
  local played = e.game_stopwatch or 0
  local r = { _order = { "seed", "pattern", "glevel", "gspeed", "queue", "level", "margin", "survived", "frames", "lostAt", "health",
                         "healthLostTop", "sentRows", "gpm", "overruns", "worstMs", "dropped", "reason" } }
  r.seed, r.pattern, r.glevel, r.gspeed, r.queue, r.level, r.margin = SEED, PATTERN, GLEVEL, GSPEED, QUEUE, LEVEL, MARGIN
  r.survived = (reason == "frames") and 1 or 0
  r.frames = played
  r.lostAt = (reason == "lost") and played or -1
  r.health = e.health or -1
  r.healthLostTop = healthLostTop
  r.sentRows = string.format("%.2f", sentRows)
  r.gpm = string.format("%.2f", played > 0 and sentRows * 3600 / played or 0)
  r.overruns, r.worstMs, r.dropped = overruns or 0, string.format("%.1f", (worst or 0) * 1000), dropped or 0
  r.reason = reason
  result(r)
  love.event.quit(0)
end

-- what the stack sent, in rows of the board's width (a 3-wide row half a row), counted as it is pushed (GarbageQueue:push / addChainLink)
local function countSends(stack)
  local og = stack.outgoingGarbage
  local push, link = og.push, og.addChainLink
  og.push = function(self, g)
    if not g.isChain then sentRows = sentRows + (g.width / 6) * (g.height or 1) end
    return push(self, g)
  end
  og.addChainLink = function(self, ...)
    if self.currentChain ~= nil then sentRows = sentRows + 1 end   -- a link past the first adds a row to the chain's slab
    return link(self, ...)
  end
end

local function startMatch()
  local GameModes = require("common.data.GameModes")
  local LevelPresets = require("common.data.LevelPresets")
  local BattleRoom = require("client.src.BattleRoom")
  local GameBase = require("client.src.scenes.GameBase")
  local Training = require("chaosbot.training")
  local player = GAME.localPlayer
  player:setStyle(GameModes.Styles.MODERN)
  player:setLevel(LEVEL)
  player:setLevelData(LevelPresets.getModern(LEVEL))
  player:setColorCount(COLORS)
  player:setGameMode(1)
  player:setMarginTime(MARGIN)
  player:setChaosMode(false)
  player:setQueueType(QUEUE)
  math.randomseed(SEED)
  local shape = SHAPES[PATTERN] or SHAPES.combo_storm
  local pattern = Training.make(loc(PATTERN), shape[1], shape[2], GLEVEL, GSPEED, QUEUE)
  GAME.battleRoom = BattleRoom.createLocalFromGameMode(GameModes.getPreset("ONE_PLAYER_TRAINING"), GameBase)
  assert(GAME.battleRoom, "chaosbot: no battle room")
  player:setAttackEngineSettings(pattern)
  player:setWantsReady(true)
  -- (readying up claims the first controller with a key held down -- BattleRoom.updateInputConfigurationForPlayer -- and nothing is
  -- held on a headless runner: the controller is claimed here, the keys come from the bot)
  if not player.inputConfiguration then
    player:setInputMethod("controller")
    player:restrictInputs(GAME.input.inputConfigurations[1])
  end
  math.randomseed(SEED + 7919)   -- the panels the match deals (BattleRoom:createPanelSource draws its seed from math.random)
  say(string.format("match asked: seed %d pattern %s glevel %d gspeed %d queue %d level %d margin %d", SEED, PATTERN, GLEVEL, GSPEED, QUEUE, LEVEL, MARGIN))
end

local function attach(match)
  for _, cs in ipairs(match.stacks) do
    if cs.player == GAME.localPlayer and cs.engine and cs.engine.panels then client, engine = cs, cs.engine end
  end
  assert(engine, "chaosbot: no stack of the local player")
  for _, src in ipairs(match.engine.garbageSources[engine] or {}) do sources[#sources + 1] = src end
  -- the fork's names Gambit's Lua side reads (GambitNative.lua's header), on the chaos stack, refreshed before every frame
  local function refresh()
    engine.stopWatch = engine.game_stopwatch or engine.clock
    engine.stopWatchIsRunning = engine.game_stopwatch_running and not engine.do_countdown
    engine.isToppedOut = engine.hasPanelsInTopRow
    for _, src in ipairs(sources) do src.stopWatch = engine.stopWatch end
  end
  countSends(engine)
  Gambit = Gambit or dofile(env("GC_GAMBIT_DIR", ".") .. "/lua/GambitNative.lua")
  bot = Gambit.new({})
  refresh()
  bot:startMatch(engine, match.engine)
  client.send_controls = function(self)
    refresh()
    local key = bot:input(engine, sources, nil)
    self.engine:receiveConfirmedInput(key)
  end
  say("bot attached")
end

local update = love.update
love.update = function(dt)
  update(dt)
  if state == "boot" then
    local top = GAME.navigationStack and GAME.navigationStack.scenes and GAME.navigationStack.scenes[#GAME.navigationStack.scenes]
    if GAME.localPlayer and top and top.name ~= "StartUp" then state = "room"; startMatch() end
  elseif state == "room" then
    local match = GAME.battleRoom and GAME.battleRoom.match
    if match and match.engine then state = "play"; attach(match) end
  elseif state == "play" then
    local e = engine
    if e.health and lastHealth and e.health < lastHealth and e.panels_in_top_row then healthLostTop = healthLostTop + (lastHealth - e.health) end
    lastHealth = e.health
    if e.game_over_clock and e.game_over_clock > 0 then finish("lost")
    elseif (e.game_stopwatch or 0) >= FRAMES then finish("frames") end
  end
end

local draw, drawn = love.draw, 0
love.draw = function()
  drawn = drawn + 1
  if state ~= "play" or drawn % DRAW_EVERY == 0 then draw() end
end
say("launcher loaded")
