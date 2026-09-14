-- Win-rate harness (GOAL #1): run N real engine matches between a HOST profile
-- and a JOINER profile, with real garbage exchange, and report the host's win%.
-- Built on emitBotGames.lua's lobby->room->ready->matchStart->tick loop. Logs in
-- ONCE (persistent connections, so the same account names don't re-login-collide),
-- then loops N games: create/join a fresh room, ready, play to completion, leave,
-- repeat. Each new room gets a fresh server seed so it's not the same deterministic
-- match every time. Tallies host.outcome.
--
-- This is the gate that says whether the EXCELLENT-hard config actually WINS a
-- contested match against an active attacker (the whole point of counterPressure).
--
-- Usage: luajit bot/winRateTest.lua <hostProfile> <joinProfile> [N] [ip] [port] [difficulty]
--   e.g.: luajit bot/winRateTest.lua bot/profiles/hard_excellent.json bot/profiles/kekeke.json 12
--   hostProfile / joinProfile: a bot/profiles/*.json path, or "" / "hard" for plain difficulty.
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN)
local socket = require("socket")
local BotClient = require("bot.BotClient")
local GameModes = require("common.data.GameModes")

local hostProfile = (arg[1] and arg[1] ~= "" and arg[1] ~= "hard") and arg[1] or nil
local joinProfile = (arg[2] and arg[2] ~= "" and arg[2] ~= "hard") and arg[2] or nil
local N = tonumber(arg[3]) or 12
local ip = arg[4] or "127.0.0.1"
local port = tonumber(arg[5]) or 49569
local difficulty = arg[6] or "hard"

-- account names must be <=16 chars (server limit); keep the suffix short + unique
local suffix = tostring(os.time() % 100000)

local function fail(m) print("WINRATE FAILED: " .. tostring(m)); os.exit(1) end

local host = BotClient({ ip = ip, port = port, name = "wH" .. suffix, difficulty = difficulty,
  brain = "search", searchProfile = hostProfile })
local join = BotClient({ ip = ip, port = port, name = "wJ" .. suffix, difficulty = difficulty,
  brain = "search", searchProfile = joinProfile })

local function pumpUntil(cond, secs, label)
  local t = socket.gettime() + secs
  while socket.gettime() < t do host:pump(); join:pump(); if cond() then return true end; socket.sleep(0.01) end
  fail("timeout: " .. label)
end
local function pumpFor(secs)
  local t = socket.gettime() + secs
  while socket.gettime() < t do host:pump(); join:pump(); socket.sleep(0.01) end
end
local function nPlayers(b) local n = 0 if b.players then for _ in pairs(b.players) do n = n + 1 end end return n end

if not host:login() then fail("host login") end
if not join:login() then fail("join login") end
host:leaveRoom(); join:leaveRoom()
pumpFor(0.6)
host:leaveRoom(); join:leaveRoom()
pumpFor(0.4)

-- clear all per-match state on a BotClient so it can play a fresh room cleanly
local function resetForNextGame(b)
  b.match = nil; b.myStack = nil; b.matchStart = nil
  b.matchEnded = nil; b.outcome = nil; b.oppDied = nil
  b.deathSent = nil; b._resultReported = nil
  b.roomNumber = nil; b.inRoom = nil; b.players = nil
  b._garbageSendCount = 0; b._garbageRecvCount = 0
  if b.capture then pcall(function() b.capture:stop() end); b.capture = nil end
end

-- play one full match in a fresh room, return host outcome + a stat line
local function playOne(gameIdx)
  resetForNextGame(host); resetForNextGame(join)

  -- openRoom=false: unlisted in the lobby room list. `join` still gets in via a
  -- direct roomNumber join (handleJoinRoom never gates that on openRoom) -- this
  -- only stops a real lobby-browsing player from spotting/joining our test room,
  -- which matters now that this script also targets the live prod server.
  host:createRoom(GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS), false)
  pumpUntil(function() return host.roomNumber end, 8, "create_room")
  join:joinRoom(host.roomNumber)
  pumpUntil(function() return nPlayers(host) >= 2 end, 8, "join")
  host:sendReady(); join:sendReady()
  pumpUntil(function() return host.matchStart and join.matchStart end, 12, "matchStart")
  host:startMatch(); join:startMatch()

  -- PA_FAST=1 runs the match AS FAST AS THE CPU ALLOWS instead of pacing to 60Hz
  -- wallclock — many more games per minute for the win-rate sweep. Loose-sync
  -- tolerates this (each bot sims locally + applies relayed garbage on arrival). We
  -- still hold for the aligned start instant (tickMatch's internal gate), then tick
  -- both bots in lockstep, pumping the sockets every few frames so relay keeps up.
  local fast = os.getenv("PA_FAST") ~= nil
  local FRAME = 1 / 60
  local nextFrame = host.scheduledStartMs / 1000
  local deadline = socket.gettime() + 150
  if fast then
    -- wait out the aligned start, then tick flat-out
    while socket.gettime() * 1000 < host.scheduledStartMs do host:pump(); join:pump(); socket.sleep(0.001) end
    local i = 0
    while socket.gettime() < deadline and not (host.matchEnded and join.matchEnded) do
      host:tickMatch(); join:tickMatch()
      i = i + 1
      if i % 4 == 0 then host:pump(); join:pump() end -- drain relayed garbage frequently
    end
    host:pump(); join:pump()
  else
    while socket.gettime() < deadline do
      host:pump(); join:pump()
      local now = socket.gettime()
      while now >= nextFrame and not (host.matchEnded and join.matchEnded) do
        host:tickMatch(); join:tickMatch()
        nextFrame = nextFrame + FRAME; now = socket.gettime()
      end
      if host.matchEnded and join.matchEnded then break end
      socket.sleep(0.001)
    end
  end

  local hostDied = (host.myStack and (host.myStack.game_over_clock or -1) > 0)
  local joinDied = (join.myStack and (join.myStack.game_over_clock or -1) > 0)
  local outcome
  if host.outcome == "won" or host.outcome == "lost" then
    outcome = host.outcome
  elseif hostDied and not joinDied then outcome = "lost"
  elseif joinDied and not hostDied then outcome = "won"
  else outcome = "draw" end

  local hc = host.myStack and host.myStack.clock or 0
  local line = string.format("game %2d: %-5s  hostClock=%d  garbSent host=%d join=%d  (hostDied=%s joinDied=%s)",
    gameIdx, outcome, hc, host._garbageSendCount or 0, join._garbageSendCount or 0,
    tostring(hostDied), tostring(joinDied))

  -- leave the room so the next createRoom gets a clean fresh-seed room
  host:leaveRoom(); join:leaveRoom()
  pumpFor(0.5)
  host:leaveRoom(); join:leaveRoom()
  pumpFor(0.3)
  return outcome, line
end

print(string.format("WIN-RATE: host=%s  join=%s  N=%d  difficulty=%s",
  hostProfile or difficulty, joinProfile or difficulty, N, difficulty))
local won, lost, draw = 0, 0, 0
for i = 1, N do
  local outcome, line = playOne(i)
  if outcome == "won" then won = won + 1
  elseif outcome == "lost" then lost = lost + 1
  else draw = draw + 1 end
  print(line)
end
local decided = won + lost
local winPct = decided > 0 and (100 * won / decided) or 0
local winPctAll = N > 0 and (100 * won / N) or 0
print(string.format("RESULT: won=%d lost=%d draw=%d  win%%(decided)=%.0f  win%%(all)=%.0f",
  won, lost, draw, winPct, winPctAll))
host:disconnect(); join:disconnect()
os.exit(0)
