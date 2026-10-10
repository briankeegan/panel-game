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
local brain = arg[6] or "heuristic"     -- "heuristic" | "search" | "expert" | "weighted" | "survival" | "bitbot"
local cursorSpeed = (cursorInterval or reactionFrames)
  and { cursorMoveInterval = cursorInterval or 8, reactionFrames = reactionFrames or 3 } or nil

-- PA_SEARCH_PROFILE=bot/profiles/<file>.json names the weight set. For
-- brain == "weighted" that is a bot/PanelEval.lua weight set (default
-- bot/profiles/trained.json when unset).
local bot = BotClient({
  ip = ip, port = port, name = name, cursorSpeed = cursorSpeed,
  brain = brain,
  searchProfile = (brain == "search" or brain == "weighted") and os.getenv("PA_SEARCH_PROFILE") or nil,
})

do local ok, why = bot:login(); if not ok then print("login failed: " .. tostring(why)); os.exit(1) end end

-- shed any stale room from a prior run so we sit idle in the lobby (challengeable)
bot:leaveRoom()
local t = socket.gettime()
while socket.gettime() < t + 0.6 do bot:pump(); socket.sleep(0.01) end
bot:leaveRoom()

local speedDesc = cursorSpeed and string.format("cursor %d/%d", cursorSpeed.cursorMoveInterval, cursorSpeed.reactionFrames) or "full speed"
print(string.format(
  "\n=== Bot '%s' (%s, L%d, %s, %s) is idle in the lobby on %s ===\n    Open your client, CHALLENGE '%s' in the lobby, and play — it auto-accepts.\n    Ctrl+C to stop.\n",
  name, brain, bot.level, speedDesc, bot.ranked and "RANKED" or "unranked", ip, name))

-- PA_CHALLENGE=<name>: also CHALLENGE that player whenever both sides are in
-- the lobby (it auto-accepts if it is a bot like this one), so two bots play
-- each other for as long as they run -- BitBot's self-play. Unset: the bot
-- only waits to be challenged, as always.
local challengeName = os.getenv("PA_CHALLENGE")
if challengeName == "" then challengeName = nil end
local lastChallengeAt = 0
local function challengeIfFree()
  if not challengeName or bot.inRoom or bot.match or not bot.lobby or not bot.lobby.players then return end
  local now = socket.gettime()
  if now - lastChallengeAt < 3 then return end
  for _, p in pairs(bot.lobby.players) do
    if p.name == challengeName and p.state == "lobby" then
      lastChallengeAt = now
      bot.gameplay:sendRequest(require("common.network.ClientProtocol").updateChallengeStatus(
        bot.publicId, p.publicId, require("common.data.GameModes").IDs.TWO_PLAYER_VS, true))
      return
    end
  end
end
if challengeName then print("    and challenging '" .. challengeName .. "' whenever both are in the lobby.\n") end

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

-- Reset local match state the same way a normal match-end does, so a bot
-- that hit an error can still rejoin for a future rematch instead of being
-- stuck (or, pre-xpcall below, instead of the whole process just dying).
local function resetMatchState()
  bot.match, bot.matchStart, bot.matchEnded = nil, nil, false
  bot.oppDied, bot.outcome, bot._resultReported, bot.deathSent = false, nil, false, false
  bot.capture, nextFrame, lastReadyAt = nil, nil, 0
end

while true do
  -- Nothing here was ever caught: an uncaught error anywhere in a tick (the
  -- brain, the engine, a signal handler) used to kill this whole process
  -- outright. That's invisible to anyone spectating this bot -- its board
  -- just stops updating, with no error shown anywhere, since the crash and
  -- its traceback happened on THIS machine, not the viewer's. Catching it
  -- here can't undo a match already desynced by the error, but it turns a
  -- silent, unexplained death into a visible one with a trace to diagnose
  -- from, and lets the bot recover for the next rematch instead of vanishing.
  local ok, err = xpcall(function()
    bot:pump()
    challengeIfFree()

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
      resetMatchState()
    end
  end, debug.traceback)

  if not ok then
    print("=== BOT TICK ERROR (recovering, match abandoned) ===")
    print(err)
    resetMatchState()
    socket.sleep(1) -- back off in case the failure is persistent (e.g. in pump() itself)
  end

  socket.sleep(0.002)
end
