-- Playtest launcher for UPSTREAM Panel Attack: one bot that idles in the lobby
-- and AUTO-ACCEPTS any challenge -- a human just challenges it in the lobby to
-- play. Rematches until killed.
--
-- Usage: luajit bot/playBot.lua [ip] [port] [name] [cursorInterval] [reactionFrames]
--   defaults: betaserver.panelattack.com 59569 PanelBot, full speed
--   PA_SEARCH_PROFILE=bot/profiles/<file>.json names the weight set.
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.WARN) -- quiet; we print our own status

local socket = require("socket")
local BotClient = require("bot.BotClient")

local ip = arg[1] or "betaserver.panelattack.com"
local port = tonumber(arg[2]) or 59569
local name = arg[3] or "PanelBot"
local cursorInterval = tonumber(arg[4]) -- frames between cursor moves/swaps; nil = full speed
local reactionFrames = tonumber(arg[5]) -- reaction-cap frames; nil = full speed
local cursorSpeed = (cursorInterval or reactionFrames)
  and { cursorMoveInterval = cursorInterval or 8, reactionFrames = reactionFrames or 3 } or nil

local bot = BotClient({
  ip = ip, port = port, name = name, cursorSpeed = cursorSpeed,
  brain = "weighted", searchProfile = os.getenv("PA_SEARCH_PROFILE"),
})

local ok, err = bot:login()
if not ok then
  print("login failed: " .. tostring(err))
  if tostring(err):find("version") or tostring(err):find("update your game") then
    print("  -> the server runs a different Panel Attack build than the upstream code this bot was started on.\n" ..
          "     Run the workflow again with upstream_ref set to the server's build (a commit, tag or branch).")
  end
  os.exit(1)
end

-- shed any stale room from a prior run so we sit idle in the lobby (challengeable)
bot:leaveRoom()
local t = socket.gettime()
while socket.gettime() < t + 0.6 do bot:pump(); socket.sleep(0.01) end

local speedDesc = cursorSpeed and string.format("cursor %d/%d", cursorSpeed.cursorMoveInterval, cursorSpeed.reactionFrames) or "full speed"
print(string.format(
  "\n=== Bot '%s' (weighted, L%d, %s, %s) is idle in the lobby on %s:%d ===\n    Open your client, CHALLENGE '%s' in the lobby, and play — it auto-accepts.\n    Ctrl+C to stop.\n",
  name, bot.level, speedDesc, bot.ranked and "RANKED" or "unranked", ip, port, name))

local function playerCount()
  local n = 0
  if bot.players then for _ in pairs(bot.players) do n = n + 1 end end
  return n
end

-- 60Hz fixed timestep: one engine frame of OUR stack per tick, like a real
-- client's frame loop. The opponent's stack catches up inside Match:run.
local FRAME = 1 / 60
local nextFrame = nil
local lastReadyAt = 0
-- Pace check: how far the loop ever got from the 60Hz schedule this match, in
-- frames. Every frame's input is owed on time; this should stay under 1.
local worstOffSchedule = 0

while true do
  bot:pump()
  if bot.disconnected then print("disconnected from the server"); os.exit(1) end

  -- (Re)ready every 1.5s while in a room with an opponent and no match running;
  -- retrying survives the post-match reset back to character select.
  if not bot.match and not bot.matchStart and bot.inRoom and playerCount() >= 2 then
    local now = socket.gettime()
    if now - lastReadyAt > 1.5 then
      bot:sendReady()
      lastReadyAt = now
    end
  end

  if bot.matchStart and not bot.match then
    bot:startMatch()
    nextFrame = socket.gettime()
    print("both ready — match starting")
  end

  if bot.match and nextFrame then
    local now = socket.gettime()
    -- only while inputs are owed: after the result is reported the bot is
    -- just waiting for the server's gameResult, which is not a frame
    if not bot._resultReported then
      worstOffSchedule = math.max(worstOffSchedule, (now - nextFrame) / FRAME)
    end
    while now >= nextFrame and not bot._resultReported do
      bot:tickMatch()
      nextFrame = nextFrame + FRAME
      now = socket.gettime()
    end
  end

  -- The room says the match is over once BOTH sides have reported (gameResult),
  -- or it was aborted; then back to character select for the rematch.
  if bot.match and bot.matchEnded then
    print(string.format("match over — bot %s (pace: worst %.2f frames off schedule); waiting for a rematch",
      tostring(bot.outcome), worstOffSchedule))
    bot:resetMatch()
    nextFrame, lastReadyAt, worstOffSchedule = nil, 0, 0
  end

  socket.sleep(0.002)
end
