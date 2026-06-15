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

local ip = arg[1] or "104.156.250.136"
local port = tonumber(arg[2]) or 49569

local host = BotClient({ ip = ip, port = port, name = "BotHost" })
local join = BotClient({ ip = ip, port = port, name = "BotJoin" })

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

-- 1) log both in
if not host:login() then fail("host login") end
if not join:login() then fail("join login") end

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

print("=== MATCH SPIKE OK: both bots reached matchStart in room " .. tostring(host.roomNumber) .. " ===")
-- Leave cleanly so we don't strand a started-but-unsimulated match on prod.
host:disconnect()
join:disconnect()
os.exit(0)
