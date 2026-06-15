-- Phase 0 step 2 spike: two headless bots create/join a room, ready up, and
-- both reach matchStart. Proves the lobby -> room -> ready -> matchStart
-- pipeline end-to-end without needing a human, on prod.
--
-- Usage: zsh run_bot.sh-equivalent; see run_bot_match.sh
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.INFO)

local socket = require("socket")
local BotClient = require("bot.BotClient")
local GameModes = require("common.data.GameModes")

local ip = arg[1] or "127.0.0.1"
local port = tonumber(arg[2]) or 49569

-- Heuristic (throttled to human-plausible cursor speed) vs random: the greedy
-- clearer should still keep its board low and outlast the raise-spamming random
-- bot, even with the APM cap.
-- arg[3] brain: "model" (default) | "heuristic" — heuristic runs the SAME
-- decide->execute path with a known-good brain to isolate model vs controller.
local brain = arg[3] or "model"
local hostOpts = { ip = ip, port = port, name = "chaos952_bot", brain = brain, difficulty = "medium" }
local joinOpts = { ip = ip, port = port, name = "mscl_bot", brain = brain, difficulty = "medium" }
if brain == "model" then hostOpts.modelDir, joinOpts.modelDir = "bot/models/chaos952", "bot/models/mscl" end
local host = BotClient(hostOpts)
local join = BotClient(joinOpts)

local function fail(msg)
  print("=== MATCH SPIKE FAILED: " .. tostring(msg) .. " ===")
  pcall(function() host:disconnect() end)
  pcall(function() join:disconnect() end)
  os.exit(1)
end

-- pump both bots until cond() or timeout
local function pumpUntil(cond, timeoutSec, label)
  local deadline = socket.gettime() + (timeoutSec or 8)
  while socket.gettime() < deadline do
    host:pump()
    join:pump()
    if cond() then return true end
    socket.sleep(0.01)
  end
  fail("timed out waiting for " .. tostring(label))
end

local function pumpFor(seconds)
  local t0 = socket.gettime()
  while socket.gettime() < t0 + seconds do
    host:pump(); join:pump()
    socket.sleep(0.01)
  end
end

-- 1) log both in
if not host:login() then fail("host login") end
if not join:login() then fail("join login") end

-- 1b) shed any stale room membership from a previously-crashed run (the server
-- re-attaches a returning account to its old room), then clear local state.
host:leaveRoom(); join:leaveRoom()
pumpFor(0.6)
host:leaveRoom(); join:leaveRoom()

-- 2) host creates an open 2p VS room
host:createRoom(GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS), true)
pumpUntil(function() return host.roomNumber ~= nil end, 8, "host create_room")
print("host room = " .. tostring(host.roomNumber))

-- 3) joiner joins it
join:joinRoom(host.roomNumber)
pumpUntil(function() return join.inRoom and join.roomNumber == host.roomNumber end, 8, "join addToRoom")
-- host should now see 2 players
pumpUntil(function() return host.players and (function() local n=0 for _ in pairs(host.players) do n=n+1 end return n>=2 end)() end,
  8, "host sees 2 players")

-- 4) both ready up
host:sendReady()
join:sendReady()

-- 5) both should receive matchStart
pumpUntil(function() return host.matchStart and join.matchStart end, 12, "matchStart on both bots")
print("both reached matchStart; building matches and simulating...")

-- 6) build both matches and run a full random match to completion
host:startMatch()
join:startMatch()
local simDeadline = socket.gettime() + 120
while socket.gettime() < simDeadline do
  host:pump(); join:pump()
  host:tickMatch(); join:tickMatch()
  if host.matchEnded and join.matchEnded then break end
  socket.sleep(1 / 60)
end

local function surv(b)
  local s = b.myStack
  local outG = s and s.outgoingGarbage and s.outgoingGarbage.history and #s.outgoingGarbage.history or 0
  return string.format("died@%s clock=%s maxCol=%s | cleared=%s score=%s outGarbage=%s",
    tostring(s and s.game_over_clock), tostring(s and s.clock),
    tostring(s and require("bot.BoardState").extract(s).maxColHeight),
    tostring(s and s.panels_cleared), tostring(s and s.score), tostring(outG))
end
local function acts(b)
  return string.format("decisions=%s swapIntents=%s swapInputs=%s",
    tostring(b._decTotal), tostring(b._decSwap), tostring(b._swapInputs))
end
local Reward = require("bot.Reward")
print(string.format("[brain=%s]", brain))
print(string.format("chaos952: %s | %s", surv(host), acts(host)))
print(string.format("   blocks: %s", Reward.summary(host.myStack)))
print(string.format("mscl:    %s | %s", surv(join), acts(join)))
print(string.format("   blocks: %s", Reward.summary(join.myStack)))
print(string.format("outcomes: host=%s, join=%s", tostring(host.outcome), tostring(join.outcome)))
print(string.format("display snapshots shipped: host=%s, join=%s",
  tostring(host._displaySendCount), tostring(join._displaySendCount)))
print(string.format("garbage sent/recv: host=%s/%s, join=%s/%s",
  tostring(host._garbageSendCount), tostring(host._garbageRecvCount),
  tostring(join._garbageSendCount), tostring(join._garbageRecvCount)))
if host.matchEnded and join.matchEnded then
  print("=== MATCH SPIKE OK: full random bot-vs-bot match played to completion in room "
    .. tostring(host.roomNumber) .. " ===")
  host:disconnect(); join:disconnect()
  os.exit(0)
else
  fail(string.format("simulation didn't finish (host.ended=%s, join.ended=%s, host.myStack frame=%s)",
    tostring(host.matchEnded), tostring(join.matchEnded),
    tostring(host.myStack and host.myStack.clock)))
end
