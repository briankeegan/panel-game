-- "Human" driver: a REAL client NetClient (not my slim BotClient) that joins the
-- bot's room and plays — to validate the bot against the actual client code path
-- (protocol + match handshake) over real sockets, not just bot-vs-bot.
--
-- Uses the E2E TestPlayer (wraps a real NetClient), with LoveRandom installed so
-- its panels are byte-identical to the bot's (both = real LÖVE RNG). Reaching
-- matchStart proves my bot and a real client successfully set up a match.
--
-- Usage: zsh run_vs_human.sh-equivalent; args: [ip] [port] [roomNumber] [name]
io.stdout:setvbuf("no")

-- Headless client bootstrap (mirrors e2eTestLauncher.lua).
_G.love = require("server.tests.E2E.LoveStub")
-- love is truthy (stub) so utf8Additions takes its require("utf8") branch; alias
-- to luarocks luautf8 headless.
package.loaded["utf8"] = require("lua-utf8")
require("server.server_globals")
require("client.src.globals")
require("client.src.config")
-- Real LÖVE RNG so this client's panels match the bot's (bot-vs-bot uses the
-- stub LCG; here we want the REAL generator on both sides).
love.math.newRandomGenerator = require("common.lib.LoveRandom").newRandomGenerator

local socket = require("socket")
local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.WARN)
local TestPlayer = require("server.tests.E2E.TestPlayer")

local ip = arg[1] or "127.0.0.1"
local port = tonumber(arg[2]) or 49569
local room = tonumber(arg[3]) or error("vsHumanTest needs a room number (arg 3)")
local name = arg[4] or "HumanTP"

local p = TestPlayer(name)

local function pumpUntil(cond, secs, label)
  local deadline = socket.gettime() + secs
  while socket.gettime() < deadline do
    p:update()
    if cond() then return true end
    socket.sleep(0.01)
  end
  print("=== TIMEOUT waiting for: " .. label .. " ===")
  return false
end

p:login(ip, port)
if not pumpUntil(function() return p:isLoggedIn() end, 8, "login") then os.exit(1) end
print("human(real NetClient): logged in")

p:joinRoom(room)
if not pumpUntil(function() return p.roomNumber == room end, 8, "join room " .. room) then os.exit(1) end
print("human: joined the bot's room " .. room)

p:sendReady()
if not pumpUntil(function() return p.matchStarted end, 15, "match start") then os.exit(1) end

print("=== HUMAN vs BOT OK: a REAL client NetClient handshook a match with the bot in room " .. room .. " ===")
-- pump a bit so the bot ships us snapshots / inputs without protocol errors
local t = socket.gettime()
while socket.gettime() < t + 3 do p:update(); socket.sleep(0.01) end
print("human: 3s of post-start message exchange completed, no protocol error")
os.exit(0)
