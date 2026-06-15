-- Emit a BOT's games in the SAME per-frame row schema as the human corpus
-- (parseReplays / DATA_CONTRACT §10), so `fit_targets.py <dir>` runs on the bot
-- exactly like on a player and `compare_profiles.py human.json bot.json` scores
-- how well a profile reproduces a player. Closes the data-track fit loop.
--
-- One engine match per invocation (real garbage exchange) → writes the HOST bot's
-- rows to <outDir>/<id>.jsonl.gz. Loop the invocation for N games (each gets a
-- fresh server seed). The host plays `searchProfile` (or difficulty); the joiner is
-- a sparring partner so there's real offense/defense.
--
-- Usage: luajit bot/emitBotGames.lua <outDir> <id> [ip] [port] [hostProfile] [difficulty]
--   e.g.: for i in $(seq 1 40); do luajit bot/emitBotGames.lua bot/data/botgames g$i \
--           127.0.0.1 49569 bot/profiles/chaos952.json hard; done
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN)
local socket = require("socket")
local json = require("common.lib.dkjson")
local BotClient = require("bot.BotClient")
local BoardState = require("bot.BoardState")
local GameModes = require("common.data.GameModes")

local outDir = assert(arg[1], "emitBotGames: need <outDir>")
local id = assert(arg[2], "emitBotGames: need <id>")
local ip = arg[3] or "127.0.0.1"
local port = tonumber(arg[4]) or 49569
local hostProfile = (arg[5] ~= "" and arg[5]) or nil -- a bot/profiles/*.json path, or nil
local difficulty = arg[6] or "hard"

-- account names suffixed with <id> so concurrent emits (parallel fit evals) don't
-- collide on the server (data track's request).
local host = BotClient({ ip = ip, port = port, name = "emit_host_" .. id, difficulty = difficulty,
  brain = "search", searchProfile = hostProfile })
local join = BotClient({ ip = ip, port = port, name = "emit_join_" .. id, difficulty = difficulty, brain = "search" })

local function fail(m) print("EMIT FAILED: " .. tostring(m)); os.exit(1) end
local function pumpUntil(cond, secs, label)
  local t = socket.gettime() + secs
  while socket.gettime() < t do host:pump(); join:pump(); if cond() then return true end; socket.sleep(0.01) end
  fail("timeout: " .. label)
end
local function nPlayers(b) local n = 0 if b.players then for _ in pairs(b.players) do n = n + 1 end end return n end

if not host:login() then fail("host login") end
if not join:login() then fail("join login") end
host:leaveRoom(); join:leaveRoom()
local t = socket.gettime(); while socket.gettime() < t + 0.5 do host:pump(); join:pump(); socket.sleep(0.01) end

host:createRoom(GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS), true)
pumpUntil(function() return host.roomNumber end, 8, "create_room")
join:joinRoom(host.roomNumber)
pumpUntil(function() return nPlayers(host) >= 2 end, 8, "join")
host:sendReady(); join:sendReady()
pumpUntil(function() return host.matchStart and join.matchStart end, 12, "matchStart")
host:startMatch(); join:startMatch()

-- open the gzip sink for the host's rows
local sink = assert(io.popen("gzip > '" .. outDir .. "/" .. id .. ".jsonl.gz'", "w"), "cannot open gzip sink")
local emitted = 0
local function emitRow(b)
  local st = b.lastState; if not st then return end
  local row = {
    frame = b.myStack and b.myStack.clock or 0,
    height = st.maxColHeight or 0,
    incoming = st.incoming or {},
    board = st.board,
    -- executed action (matches the human corpus's executed-action labeling), not
    -- the brain's per-frame intent — so swap-derived metrics are comparable.
    action = { decision = b.lastExecuted or { type = "WAIT" } },
  }
  sink:write(json.encode(row) .. "\n"); emitted = emitted + 1
end

local FRAME = 1 / 60
local nextFrame = host.scheduledStartMs / 1000
local deadline = socket.gettime() + 120
while socket.gettime() < deadline do
  host:pump(); join:pump()
  local now = socket.gettime()
  while now >= nextFrame and not (host.matchEnded and join.matchEnded) do
    host:tickMatch(); join:tickMatch()
    emitRow(host)
    nextFrame = nextFrame + FRAME; now = socket.gettime()
  end
  if host.matchEnded and join.matchEnded then break end
  socket.sleep(0.001)
end

sink:close()

-- offense stats line (4th fit_targets component), schema = parseReplays EMIT_STATS:
-- {frames, garbage:[{isChain,width,height,frameEarned}], ...} appended to stats.jsonl.
local stk = host.myStack
if stk and stk.outgoingGarbage then
  local garbage = {}
  for _, g in ipairs(stk.outgoingGarbage.history or {}) do
    garbage[#garbage + 1] = { isChain = g.isChain or false, width = g.width, height = g.height, frameEarned = g.frameEarned }
  end
  local stats = { gameId = id, outcome = host.outcome, frames = stk.clock,
    panels_cleared = stk.panels_cleared, score = stk.score, garbage = garbage }
  local sf = io.open(outDir .. "/stats.jsonl", "a")
  if sf then sf:write(json.encode(stats) .. "\n"); sf:close() end
end

print(string.format("emitted %d rows + stats -> %s/%s.jsonl.gz", emitted, outDir, id))
host:disconnect(); join:disconnect()
