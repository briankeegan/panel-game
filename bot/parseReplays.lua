-- Re-simulate legacy input-replays under LÖVE (bit-exact love.math RNG) and emit
-- per-frame (state -> action) training rows per bot/DATA_CONTRACT.md.
-- LÖVE 11.5; launched via PA_PARSE_MODE=1 + `love .` (see bot/parse.sh).
--
-- Env config:
--   PA_PARSE_ID      target player publicId (the seat we extract)
--   PA_PARSE_INDIR   dir of replay .json files (batch)
--   PA_PARSE_FILE    single replay file (overrides INDIR; for one-off tests)
--   PA_PARSE_OUTDIR  dir for <gameId>.jsonl output
--   PA_PARSE_LIMIT   max files to process (0 = all)

require("common.lib.mathExtensions")
local util = require("common.lib.util")
util.addToCPath("./common/lib/??")
util.addToCPath("./server/lib/??")
local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.INFO)
require("client.src.globals")
local Game = require("client.src.Game")
local ReplayV3 = require("common.data.ReplayV3")
local Match = require("common.engine.Match")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local PanelStateCodes = require("client.src.network.PanelStateCodes")
local json = require("common.lib.dkjson")

local TARGET_ID = tonumber(os.getenv("PA_PARSE_ID") or "")
local INDIR = os.getenv("PA_PARSE_INDIR")
local FILE = os.getenv("PA_PARSE_FILE")
local OUTDIR = os.getenv("PA_PARSE_OUTDIR") or "."
local LIMIT = tonumber(os.getenv("PA_PARSE_LIMIT") or "0")

function love.load()
  -- Same engine bootstrap the test harness uses (createFromReplay needs GAME).
  GAME = Game()
  GAME:load()
  GAME.muteSound = true
  local cr = coroutine.create(GAME.setupRoutine)
  while coroutine.status(cr) ~= "dead" do
    local ok, status = coroutine.resume(cr, GAME)
    if not ok then error(status) end
  end
end

-- base64decode unpack order is: raise, swap, up, down, left, right (Stack.lua:713)
local function decodeInput(char)
  local d = KeyDataEncoding.base64decode[char]
  return {
    char = char,
    raise = d[1] or false, swap = d[2] or false,
    up = d[3] or false, down = d[4] or false, left = d[5] or false, right = d[6] or false,
  }
end

local function nonIdle(raw)
  return raw.swap or raw.raise or raw.up or raw.down or raw.left or raw.right
end

-- board: rows 1..height, bottom->top; each cell {c=color, s=stateCode}
local function boardOf(stack)
  local board = {}
  for r = 1, stack.height do
    local row = {}
    for c = 1, stack.width do
      local p = stack.panels[r] and stack.panels[r][c]
      row[c] = p and { c = p.color, s = PanelStateCodes.toCode(p.state) } or { c = 0, s = 0 }
    end
    board[r] = row
  end
  return board
end

-- topmost row index holding a real (non-empty) panel
local function stackHeight(stack)
  for r = stack.height, 1, -1 do
    for c = 1, stack.width do
      local p = stack.panels[r] and stack.panels[r][c]
      if p and p.color and p.color ~= 0 then return r end
    end
  end
  return 0
end

local function targetIndex(replay)
  for i, s in ipairs(replay.metadata.stacks) do
    if s.publicId == TARGET_ID then return i end
  end
end

-- re-sim winner's stack index, for the drop-on-desync check. We validate against
-- metadata.winnerIndex (which agrees with the re-sim + filename); metadata.winnerId
-- is unreliable in the legacy data (can disagree with its own winnerIndex).
local function resimWinnerIndex(match)
  local winners = match:getWinners()
  if #winners ~= 1 then return nil end
  for i, s in ipairs(match.stacks) do
    if s == winners[1] then return i end
  end
end

-- Dense-intent labeling (DATA_CONTRACT §10): a micro-sequence = a maximal run of
-- non-idle frames; each frame in it is labeled by the NEXT terminal (swap/raise)
-- reached within the run. Idle frames + dead-end tails = WAIT.
local function labelDecisions(rows)
  for _, r in ipairs(rows) do r.action.decision = { type = "WAIT" } end
  local i, n = 1, #rows
  while i <= n do
    if not nonIdle(rows[i].action.raw) then
      i = i + 1
    else
      local j = i
      while j <= n and nonIdle(rows[j].action.raw) do j = j + 1 end
      local segStart = i
      for k = i, j - 1 do
        local rk = rows[k].action.raw
        if rk.swap then
          local pos = { rows[k].cursor[1], rows[k].cursor[2] }
          for m = segStart, k do rows[m].action.decision = { type = "SWAP", pos = pos } end
          segStart = k + 1
        elseif rk.raise then
          for m = segStart, k do rows[m].action.decision = { type = "RAISE" } end
          segStart = k + 1
        end
      end
      i = j
    end
  end
end

---@return table? rows, string? err
local function parseReplay(path)
  local fh = io.open(path, "r")
  if not fh then return nil, "open-failed" end
  local content = fh:read("*a"); fh:close()
  local tbl = json.decode(content)
  if not tbl then return nil, "json-decode" end
  local replay = ReplayV3.createFromTable(tbl, true)
  local ti = targetIndex(replay)
  if not ti then return nil, "target-not-in-replay" end
  local oi = (ti == 1) and 2 or 1

  local match = Match.createFromReplay(replay)
  match:start()
  for _, s in ipairs(match.stacks) do s:setMaxRunsPerFrame(1) end
  local stack, opp = match.stacks[ti], match.stacks[oi]

  local meta = replay.metadata
  local tags = {
    id = TARGET_ID, gameId = meta.gameId, engineVersion = replay.engineVersion,
    timestamp = meta.timestamp, level = meta.stacks[ti].level,
    outcome = (meta.winnerIndex == ti) and "won" or "lost",
  }

  local rows = {}
  while not match:isLocallyEnded() do
    local clock = stack.clock
    local char = stack.confirmedInput[clock + 1]
    if char then
      rows[#rows + 1] = {
        frame = clock,
        board = boardOf(stack),
        cursor = { stack.cur_row, stack.cur_col },
        displacement = stack.displacement,
        height = stackHeight(stack),
        danger = stack:isToppedOut(),
        incoming = {}, -- TODO(v0b): read stack.incomingGarbage queue
        opp = {
          id = meta.stacks[oi].publicId,
          height = stackHeight(opp),
          danger = opp:isToppedOut(),
          sending = {}, -- TODO(v0b)
        },
        action = { raw = decodeInput(char) },
      }
    end
    match:run()
  end

  -- drop-on-desync: re-sim winner index must match the recorded winnerIndex
  if meta.winnerIndex ~= nil and resimWinnerIndex(match) ~= meta.winnerIndex then
    return nil, "resim-desync"
  end

  labelDecisions(rows)
  for _, r in ipairs(rows) do
    r.id, r.gameId, r.engineVersion = tags.id, tags.gameId, tags.engineVersion
    r.timestamp, r.outcome, r.level = tags.timestamp, tags.outcome, tags.level
  end
  return rows, nil
end

local function writeRows(gameId, rows)
  -- gzip the JSONL: per-frame full-board rows are verbose (~13MB/game plain).
  -- Schema is unchanged; consumers just gunzip. love.data.compress (we're under love).
  local buf = {}
  for _, r in ipairs(rows) do buf[#buf + 1] = json.encode(r) end
  local data = table.concat(buf, "\n") .. "\n"
  local gz = love.data.compress("string", "gzip", data)
  local path = OUTDIR .. "/" .. tostring(gameId) .. ".jsonl.gz"
  local fh = assert(io.open(path, "wb"))
  fh:write(gz)
  fh:close()
  return #rows
end

local function listFiles()
  if FILE then return { FILE } end
  local out = {}
  local p = io.popen('ls "' .. INDIR .. '"/*.json 2>/dev/null')
  if p then
    for line in p:lines() do out[#out + 1] = line end
    p:close()
  end
  return out
end

local started = false
function love.update()
  if started then return end
  started = true

  local files = listFiles()
  local processed, kept, dropped, totalRows = 0, 0, 0, 0
  local dropReasons = {}
  for _, path in ipairs(files) do
    if LIMIT > 0 and processed >= LIMIT then break end
    processed = processed + 1
    local ok, rowsOrErr, err = pcall(parseReplay, path)
    if not ok then
      dropped = dropped + 1
      dropReasons["crash"] = (dropReasons["crash"] or 0) + 1
      logger.error("crash on " .. path .. ": " .. tostring(rowsOrErr))
    elseif rowsOrErr then
      local n = writeRows(rowsOrErr[1] and rowsOrErr[1].gameId or "unknown", rowsOrErr)
      kept = kept + 1; totalRows = totalRows + n
    else
      dropped = dropped + 1
      dropReasons[err or "?"] = (dropReasons[err or "?"] or 0) + 1
    end
  end
  logger.info(string.format("PARSE DONE: processed=%d kept=%d dropped=%d rows=%d",
    processed, kept, dropped, totalRows))
  for reason, count in pairs(dropReasons) do
    logger.info(string.format("  drop[%s] = %d", reason, count))
  end
  love.event.quit()
end

function love.draw() end
