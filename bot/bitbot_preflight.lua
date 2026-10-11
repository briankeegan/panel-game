-- BITBOT PRE-FLIGHT: before BitBot joins a lobby, play it through the exact
-- live path, offline, and refuse to go live if the hookup is broken.
--
--   luajit bot/bitbot_preflight.lua [frames]      (bot/bitbot_link.js must be listening;
--                                                  PA_SURVIVOR_PORT / PA_SURVIVOR_WAIT as live)
--
-- The path is the live one end to end: this repo's Lua engine (a VS stack,
-- the live level and rules), bot/SurvivalLink.lua sending its board every
-- frame, bot/bitbot_link.js running GameCreator's BitBot on it, and the keys
-- that come back pressed. Only the server is missing: nothing connects.
--
-- It checks the hookup, not how well BitBot plays -- BitBot is still being
-- written and losing is allowed. It fails when BitBot, as GameCreator's main
-- has it today, does not actually play through the link:
--   * a frame's answer did not come back (SurvivalLink.late)
--   * no swap reached the engine, or nothing was cleared
-- PA_PREFLIGHT_LATE_OK=1 for a bot that answers from keys it planned ahead
-- (WasmSurvivor): a late answer is then its designed path, reported, not
-- failed. PA_PREFLIGHT_NAME names the bot in the output (default BitBot).
-- bitbot_link.js separately logs any stack call it cannot relay ("not
-- relayed"), which the workflow treats as a failure too.
io.stdout:setvbuf("no")
package.path = "./?.lua;" .. package.path
require("bot.headlessBoot")
local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.ERROR)
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local SurvivalLink = require("bot.SurvivalLink")

local FRAMES = tonumber(arg[1]) or 1800
local WHO = os.getenv("PA_PREFLIGHT_NAME") or "BitBot"
local LATE_OK = os.getenv("PA_PREFLIGHT_LATE_OK") == "1"

local mode = GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS)
local match = Match(GeneratorSource(tonumber(os.getenv("PA_PREFLIGHT_SEED")) or 20261001, true), mode.matchRules)
local stack = match:createStackWithSettings(LevelPresets.getModern(10), true, "controller")
match:start()

-- PA_PREFLIGHT_BRAIN=bitbot plays BitBot native, in this process
-- (bot/BitBotNative.lua) -- the live path for BitBot; otherwise the link.
local link = os.getenv("PA_PREFLIGHT_BRAIN") == "bitbot" and require("bot.BitBotNative").new({}) or SurvivalLink.new({})
-- PA_PREFLIGHT_OPPONENT=1: BitBot is told another player is in the match, as in a duel
-- (nobody sends it garbage here): the game with no network and no other bot in it.
local withOpponent = os.getenv("PA_PREFLIGHT_OPPONENT") == "1" and { stacks = { stack, { game_ended = function() return false end } } } or nil
link:startMatch(stack, withOpponent)

local swaps0 = stack.swapCount or 0
local frames, firstPlayed = 0, nil
while frames < FRAMES and not stack:game_ended() do
  local char = link:input(stack, match.garbageSources and match.garbageSources[stack])
  stack:receiveConfirmedInput(char)
  match:run()
  frames = frames + 1
  if not firstPlayed and stack.stopWatchIsRunning then firstPlayed = frames end
end
link:endMatch()

local played = frames - (firstPlayed or frames)
local swaps = (stack.swapCount or 0) - swaps0
local cleared = stack.panels_cleared or 0
print(string.format("%s pre-flight: %d frames played after the countdown%s; %d swaps made, %d panels cleared, %d of %d answers late",
  WHO, played, stack:game_ended() and " (topped out)" or "", swaps, cleared, link.late, link.frames))

if link.maxMs then print(string.format("%s: slowest frame %.1f ms (a frame is 16.7)", WHO, link.maxMs)) end

local problems = {}
if link.frames == 0 then problems[#problems + 1] = WHO .. " was never asked for a frame" end
if link.late > 0 and not LATE_OK then problems[#problems + 1] = link.late .. " frames' answers did not come back in time" end
if swaps == 0 then problems[#problems + 1] = "no swap " .. WHO .. " made reached the engine" end
if cleared == 0 then problems[#problems + 1] = WHO .. " cleared nothing" end
if #problems > 0 then
  print(WHO .. " pre-flight FAILED: " .. table.concat(problems, "; "))
  os.exit(1)
end
print(WHO .. " pre-flight passed")
