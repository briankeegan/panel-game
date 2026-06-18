-- Playtest launcher: one bot that idles in the lobby and AUTO-ACCEPTS any
-- challenge — so a human just challenges it in the lobby to play. Heuristic brain
-- by default; pass "search"/"expert" to pick a brain. Rematches forever (Ctrl+C).
--
-- Usage: zsh run_play.sh [ip] [port] [name] [cursorInterval] [reactionFrames] [brain]
--   cursorInterval/reactionFrames: optional cursor-speed knobs (frames); omit for full speed.
--   defaults: 104.156.250.136 49569 PanelBot  (full speed, heuristic) — the bot always plays full-quality.
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.WARN) -- quiet; we print our own status

local socket = require("socket")
local BotClient = require("bot.BotClient")

local ip = arg[1] or "104.156.250.136"
local port = tonumber(arg[2]) or 49569
local name = arg[3] or "PanelBot"
local cursorInterval = tonumber(arg[4]) -- frames between cursor moves/swaps; nil = full speed
local reactionFrames = tonumber(arg[5]) -- reaction-cap frames; nil = full speed
local brain = arg[6] or "heuristic"     -- "heuristic" | "search" | "expert"
local cursorSpeed = (cursorInterval or reactionFrames)
  and { cursorMoveInterval = cursorInterval or 8, reactionFrames = reactionFrames or 3 } or nil

-- PA_SEARCH_PROFILE=bot/profiles/<player>.json conditions the search eval per
-- player (Phase B); ignored unless brain == "search".
local bot = BotClient({
  ip = ip, port = port, name = name, cursorSpeed = cursorSpeed,
  brain = brain,
  searchProfile = (brain == "search") and os.getenv("PA_SEARCH_PROFILE") or nil,
})

if not bot:login() then print("login failed"); os.exit(1) end

-- shed any stale room from a prior run so we sit idle in the lobby (challengeable)
bot:leaveRoom()
local t = socket.gettime()
while socket.gettime() < t + 0.6 do bot:pump(); socket.sleep(0.01) end
bot:leaveRoom()

local speedDesc = cursorSpeed and string.format("cursor %d/%d", cursorSpeed.cursorMoveInterval, cursorSpeed.reactionFrames) or "full speed"
print(string.format(
  "\n=== Bot '%s' (%s, L%d, %s) is idle in the lobby on %s ===\n    Open your client, CHALLENGE '%s' in the lobby, and play — it auto-accepts.\n    Ctrl+C to stop.\n",
  name, brain, bot.level, speedDesc, ip, name))

local function playerCount()
  local n = 0
  if bot.players then for _ in pairs(bot.players) do n = n + 1 end end
  return n
end

-- 60Hz fixed-timestep so the bot's engine stays in lockstep wall-clock with the
-- human. tickMatch advances exactly one frame per call (and holds for the
-- aligned start instant internally).
local FRAME = 1 / 60
local nextFrame = nil
local lastReadyAt = 0

while true do
  bot:pump()

  -- (Re)ready ~every 1.5s while we're in the room with an opponent and no match
  -- is pending/running. Retrying (not single-shot) survives the post-match room
  -- reset: the challenge flow keeps both players in the room, so one mistimed
  -- ready would otherwise strand the rematch (the reported bug).
  if not bot.match and not bot.matchStart and playerCount() >= 2 then
    local now = socket.gettime()
    if now - lastReadyAt > 1.5 then
      bot:sendReady()
      lastReadyAt = now
    end
  end

  if bot.matchStart and not bot.match then
    bot:startMatch()
    nextFrame = bot.scheduledStartMs / 1000 -- first frame at the aligned start
    print("both ready — match starting")
  end

  if bot.match and not bot.matchEnded and nextFrame then
    local now = socket.gettime()
    while now >= nextFrame and not bot.matchEnded do
      bot:tickMatch()
      nextFrame = nextFrame + FRAME
      now = socket.gettime()
    end
  end

  if bot.matchEnded and bot.match then
    print("match over — bot " .. tostring(bot.outcome) .. "; waiting for a rematch")
    bot.match, bot.matchStart, bot.matchEnded = nil, nil, false
    bot.oppDied, bot.outcome, bot._resultReported, bot.deathSent = false, nil, false, false
    bot.capture, nextFrame, lastReadyAt = nil, nil, 0 -- re-ready promptly for the rematch
  end

  socket.sleep(0.002)
end
