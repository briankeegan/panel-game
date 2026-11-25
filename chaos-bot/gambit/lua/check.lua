-- THE HOOKUP CHECKED: the server's Lua plays a training match as the game builds it (the player's stack at the level the games play -- PA_LEVEL, 11 -- a simulated
-- opponent sending the pattern) and Gambit plays the stack in this process (GambitNative.lua), for FRAMES frames. It checks the
-- plumbing -- keys pressed, swaps made, every board the frame loop predicted the one the game made (it exits 1 on any other) -- not how
-- well Gambit plays.
--
--   (in a panel-game checkout with its LUA_PATH; GC_GAMBIT_WORDS from words.js)
--   luajit <GameCreator>/games/the-game/ai/gambit/lua/check.lua MODE [FRAMES] [SEED]
require("bot.headlessBoot")
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local Match = require("common.engine.Match")
require("common.engine.checkMatches")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
local G = dofile(here .. "/GambitNative.lua")

local MODE, FRAMES, SEED = arg[1] or "factory", tonumber(arg[2]) or 600, tonumber(arg[3]) or 1
local SIZES = { combo_storm = { 4, 1 }, factory = { 6, 2 }, large_garbage = { 6, 12 }, endless = { 0, 0 } }   -- (endless: nothing sent, the stack's own rise)
local size = assert(SIZES[MODE], "check: no mode " .. tostring(MODE))
local patterns = {}
for i = 1, 50 do patterns[#patterns + 1] = { width = math.max(size[1], 1), height = math.max(size[2], 1), startTime = size[1] > 0 and i or 1e9 + i, metal = false, chain = false, endsChain = false } end
local mode = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_TRAINING)
local match = Match(GeneratorSource(SEED, true), mode.matchRules)
local a = match:createStackWithSettings(LevelPresets.getModern(tonumber(os.getenv("PA_LEVEL")) or 11), true, "controller")   -- (the level the games play)
a:setMaxRunsPerFrame(1)
local foe = match:createSimulatedStackWithSettings({ delayBeforeStart = 150, delayBeforeRepeat = 900, attackPatterns = patterns })
foe:setMaxRunsPerFrame(1)
match:addTarget(foe, a)
match:start()

local bot = G.new({})
bot:startMatch(a, match)
local KeyDataEncoding = require("common.data.KeyDataEncoding")
-- (at the game's own pace, sixty frames a second: Gambit thinks while the game runs on, as it does in the client)
local socket = require("socket")
local pressed, frame, t0 = 0, 0, socket.gettime()
while frame < FRAMES and not a:game_ended() do
  frame = frame + 1
  local due = t0 + frame / 60
  while socket.gettime() < due do socket.sleep(0.001) end
  local ch = bot:input(a, match.garbageSources[a])
  if ch ~= KeyDataEncoding.base64encode[1] then pressed = pressed + 1 end
  a:receiveConfirmedInput(ch)
  match:run()
end
bot:endMatch()
local over, worst, dropped = bot:budget()
print(string.format("check %s: %d frames, %d with keys, swaps %d, cleared %d, died %s, thinkOver %d, thinkWorstMs %.1f, dropped %d",
  MODE, frame, pressed, a.swapCount or 0, a.panels_cleared or 0, tostring(a:game_ended()), over, worst * 1000, dropped))
-- THE TRUTH: every board the frame loop predicted is the one the game made (the match's last stats line in the run's log). A board that
-- differs is a plan made on a board that never was; any is a failure.
local logf = os.getenv("GC_GAMBIT_LOG")
local diverged
if logf then
  local f = io.open(logf, "r")
  if f then
    for l in f:lines() do local d = l:match('^match over: .*"diverged":(%d+)'); if d then diverged = tonumber(d) end end
    f:close()
  end
end
print(string.format("truth %s: %s boards predicted otherwise", MODE, diverged and tostring(diverged) or "no stats"))
if diverged ~= 0 then os.exit(1) end
