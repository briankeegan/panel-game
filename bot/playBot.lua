-- Playtest launcher: one bot that idles in the lobby and AUTO-ACCEPTS any
-- challenge — so a human just challenges it in the lobby to play. Heuristic brain
-- by default; pass "search"/"expert" or a model dir. Rematches forever (Ctrl+C).
--
-- Usage: zsh run_play.sh [ip] [port] [name] [difficulty] [brain]
--   defaults: 104.156.250.136 49569 PanelBot medium  (heuristic)
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.WARN) -- quiet; we print our own status

local socket = require("socket")
local BotClient = require("bot.BotClient")

local ip = arg[1] or "104.156.250.136"
local port = tonumber(arg[2]) or 49569
local name = arg[3] or "PanelBot"
local difficulty = arg[4] or "medium"
local modelDir = arg[5] -- optional

-- modelDir slot doubles as a brain selector: "search"/"expert" -> that brain,
-- a path -> trained model, nil -> heuristic.
local namedBrain = (modelDir == "search" or modelDir == "expert") and modelDir or nil
local brain = namedBrain or (modelDir and "model" or "heuristic")
if namedBrain then modelDir = nil end

-- PA_SEARCH_PROFILE=bot/profiles/<player>.json conditions the search eval per
-- player (Phase B); ignored unless brain == "search".
local bot = BotClient({
  ip = ip, port = port, name = name, difficulty = difficulty,
  brain = brain, modelDir = modelDir,
  searchProfile = (brain == "search") and os.getenv("PA_SEARCH_PROFILE") or nil,
})

if not bot:login() then print("login failed"); os.exit(1) end

-- shed any stale room from a prior run so we sit idle in the lobby (challengeable)
bot:leaveRoom()
local t = socket.gettime()
while socket.gettime() < t + 0.6 do bot:pump(); socket.sleep(0.01) end
bot:leaveRoom()

print(string.format(
  "\n=== Bot '%s' (%s, L%d, %s) is idle in the lobby on %s ===\n    Open your client, CHALLENGE '%s' in the lobby, and play — it auto-accepts.\n    Ctrl+C to stop.\n",
  name, brain, bot.level, difficulty, ip, name))

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
local readied = false

while true do
  bot:pump()

  -- Ready up only once the opponent is actually in the room (the proven flow;
  -- readying with just ourselves can be cleared when the joiner arrives).
  if not bot.match and not readied and playerCount() >= 2 then
    bot:sendReady()
    readied = true
    print("opponent joined the room — readying up (you ready up too)")
  end
  if playerCount() < 2 then readied = false end -- opponent left; wait again

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
    bot.capture, nextFrame, readied = nil, nil, false -- re-ready when both present again
  end

  socket.sleep(0.002)
end
