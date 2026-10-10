-- SURVIVAL LINK: WasmSurvivor's hands on the server.
--
-- The survival bot lives in GameCreator (games/the-game/ai/eval/survivor.js,
-- a Node process beside this one): it plans on the server's own rules and
-- answers, every frame, what to press. This end sends it the board as it is
-- at the start of each frame and presses what comes back.
--
-- What goes over is only what a player can see on the board -- every panel,
-- the timers, the garbage already queued. Not the rows the generator has not
-- shown yet, and not the colours garbage will break into.
--
--   local link = require("bot.SurvivalLink").new({ port = 47777 })   -- or PA_SURVIVOR_PORT / PA_SURVIVOR_HOST
--   link:startMatch(stack)            -- once per match
--   local char = link:input(stack, match.garbageSources[stack])   -- every frame, before it is run
local socket = require("socket")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local ThinkBudget = require("common.engine.computerPlayers.ThinkBudget")
local InputBudget = require("common.engine.computerPlayers.InputBudget")

local SurvivalLink = {}
SurvivalLink.__index = SurvivalLink

-- ---------------------------------------------------------------- the board as JSON
-- The same form as GameCreator's lua/engineRecord.lua, which pa-engine.js
-- (fromLua) is checked against; the generator's buffers are left out.
local function num(v)
  if v % 1 == 0 and v > -2 ^ 53 and v < 2 ^ 53 then return string.format("%d", v) end
  return string.format("%.17g", v)
end
-- an object key as JSON, made once
local quoted = setmetatable({}, { __index = function(t, k) local q = string.format("%q", tostring(k)); t[k] = q; return q end })
local function enc(v, depth)
  local t = type(v)
  if v == nil then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v then return '"NaN"' end
    if v == math.huge then return '"Infinity"' end
    if v == -math.huge then return '"-Infinity"' end
    return num(v)
  end
  if t == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
  if t == "table" then
    depth = depth or 0
    if depth > 6 then return '"<deep>"' end
    local n = #v
    local isArray = n > 0 or next(v) == nil
    if isArray then for k in pairs(v) do if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then isArray = false; break end end end
    local parts = {}
    if isArray and n > 0 then
      for i = 1, n do parts[#parts + 1] = enc(v[i], depth + 1) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, x in pairs(v) do
      local tk, tx = type(k), type(x)
      if (tk == "string" or tk == "number") and tx ~= "function" and tx ~= "userdata" and tx ~= "thread" then keys[#keys + 1] = k end
    end
    for _, k in ipairs(keys) do parts[#parts + 1] = quoted[k] .. ":" .. enc(v[k], depth + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
local function scalars(t)
  local o = {}
  for k, v in pairs(t) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then o[k] = v end
  end
  return o
end
-- A table's number, boolean and string fields as a JSON object, without the table `scalars` makes.
local function encScalars(t)
  local parts, n = {}, 0
  for k, v in pairs(t) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then n = n + 1; parts[n] = quoted[k] .. ":" .. enc(v) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function garbageList(q)
  local o = {}
  for i = 1, #q do
    local g = q[i]
    o[i] = { width = g.width, height = g.height, isMetal = g.isMetal or false, isChain = g.isChain or false,
             frameEarned = g.frameEarned, finalized = g.finalized }
  end
  return o
end
-- The garbage each source has sent and not yet delivered: what its
-- telegraph shows (staged, oldest last) and what has left it (transit, by
-- the stopWatch it lands on). Its colours are not in it.
local function telegraph(sources)
  local out = {}
  for i, src in ipairs(sources or {}) do
    local q = src.outgoingGarbage
    local transit = {}
    if q and q.transitTimers then
      for k = q.transitTimers.first, q.transitTimers.last do
        local t = q.transitTimers[k]
        if t then transit[#transit + 1] = { at = t, garbage = garbageList(q.garbageInTransit[t] or {}) } end
      end
    end
    out[i] = { stopWatch = src.stopWatch, staged = garbageList(q and q.stagedGarbage or {}), transit = transit }
  end
  return out
end

function SurvivalLink.dump(s, sources)
  local rows = {}
  for r = 0, #s.panels do
    local cells = {}
    for c = 1, s.width do
      local p = s.panels[r] and s.panels[r][c]
      cells[c] = p and encScalars(p) or "false"
    end
    rows[r + 1] = "[" .. table.concat(cells, ",") .. "]"
  end
  local backlog = {}
  for i, rec in ipairs(s.swapStallingBackLog or {}) do backlog[i] = scalars(rec) end
  local landed = {}
  for i, id in ipairs(s.garbageLandedThisFrame or {}) do landed[i] = id end
  return '{"stack":' .. encScalars(s) .. ',"panels":[' .. table.concat(rows, ",") .. ']'
    .. ',"incoming":' .. enc({ staged = garbageList(s.incomingGarbage.stagedGarbage) })
    .. ',"swapStallingBackLog":' .. enc(backlog) .. ',"garbageLandedThisFrame":' .. enc(landed)
    .. ',"dropColumns":' .. enc(s.currentGarbageDropColumnIndexes) .. ',"telegraph":' .. enc(telegraph(sources)) .. '}'
end

-- ---------------------------------------------------------------- the link
-- A frame is held to this share of the thinking ceiling: what the system's own
-- pauses take from a frame comes out of the rest.
SurvivalLink.TARGET_SHARE = 0.5
function SurvivalLink.new(opts)
  opts = opts or {}
  local self = setmetatable({}, SurvivalLink)
  self.host = opts.host or os.getenv("PA_SURVIVOR_HOST") or "127.0.0.1"
  self.port = opts.port or tonumber(os.getenv("PA_SURVIVOR_PORT") or "") or 47777
  -- The game's budgets: the ceiling on a frame's thinking, and the allowance
  -- of keys. A budget the game hands in is the game's to charge and press;
  -- one made here is ours.
  self.thinking = opts.thinkBudget or ThinkBudget.standard()
  self.ownThinking = opts.thinkBudget == nil
  self.inputs = opts.inputBudget or InputBudget.standard()
  self.ownInputs = opts.inputBudget == nil
  self.waitSec = opts.waitSec or tonumber(os.getenv("PA_SURVIVOR_WAIT") or "") or self.thinking:snapshot().ceiling
  self.dropped = 0
  self.ages = {}
  self.buffer = ""
  self.late = 0
  self.frames = 0
  return self
end

function SurvivalLink:connect()
  if self.sock then return true end
  local sock = socket.tcp()
  sock:settimeout(2)
  local ok, err = sock:connect(self.host, self.port)
  if not ok then error("SurvivalLink: cannot reach the survival bot at " .. self.host .. ":" .. self.port .. " (" .. tostring(err) .. ")") end
  sock:setoption("tcp-nodelay", true)
  self.sock = sock
  return true
end

function SurvivalLink:send(line)
  local ok, err = self.sock:send(line .. "\n")
  if not ok then error("SurvivalLink: send failed: " .. tostring(err)) end
end

-- The next reply line, or nil after `timeout` seconds. A line read in part
-- is kept for the next call.
function SurvivalLink:receive(timeout)
  self.sock:settimeout(timeout, "t")   -- a total for the whole read, not a wait per piece of the line
  local line, err, partial = self.sock:receive("*l")
  if line then
    line = self.buffer .. line
    self.buffer = ""
    return line
  end
  self.buffer = self.buffer .. (partial or "")
  if err == "closed" then error("SurvivalLink: the survival bot closed the link") end
  return nil
end

-- The next reply line, or nil at `deadline` (socket.gettime seconds). The
-- system's timers wake a wait late by a millisecond or two, so a wait blocks
-- only until SPIN_SEC before the deadline and polls the rest.
SurvivalLink.SPIN_SEC = 0.002
function SurvivalLink:await(deadline)
  local coarse = deadline - SurvivalLink.SPIN_SEC - socket.gettime()
  local line = self:receive(coarse > 0 and coarse or 0)
  while not line and socket.gettime() < deadline do line = self:receive(0) end
  return line
end

function SurvivalLink:startMatch(stack)
  self:connect()
  self:send(enc({ t = "match", levelData = stack.levelData, behaviours = stack.behaviours,
                  stackOverConditions = stack.stackOverConditions }))
  self.awaiting = 1   -- the match's ok, read with the first frame's answer
  self.planned = nil
  self.frames = 0
end

-- The key to press this frame. Before the countdown ends the bot holds
-- still (the search plays only a stack in play).
-- `sources` are the stacks sending this one garbage; their telegraphs go
-- with the board.
-- The frame's work, with the collector held off for it: a collection that
-- fell inside would be thinking time the bot did not use, and is left to the
-- game's own work between frames. The frame is charged to the thinking budget
-- and its key pressed on the input budget, the game's own.
function SurvivalLink:input(stack, sources)
  collectgarbage("stop")
  local began = ThinkBudget.now()
  local ok, key = pcall(self.think, self, stack, sources)
  if ok and self.ownInputs then key = self:press(key, stack.clock) end
  local took = ThinkBudget.now() - began
  collectgarbage("restart")
  if not ok then error(key, 0) end
  if self.ownThinking then self.thinking:charge(took) end
  return key
end

-- The key, or idle when the allowance of keys cannot pay for it (the game
-- does not press a key past it).
function SurvivalLink:press(key, clock)
  local keys, held, down = KeyDataEncoding.base64decode[key], self.inputs.held, 0
  for _, bit in ipairs({2, 3, 4, 5, 6}) do
    if keys and keys[bit] and not held[bit] then down = down + 1 end
  end
  if down > self.inputs:remaining(clock) then key = KeyDataEncoding.idle; self.dropped = self.dropped + 1 end
  self.inputs:press(key, clock)
  return key
end

function SurvivalLink:think(stack, sources)
  local idle = KeyDataEncoding.base64encode[1]
  if stack.in_countdown or not stack.stopWatchIsRunning or stack:game_ended() then return idle end
  local clock = stack.clock
  -- Everything this frame costs -- the board encoded, sent, every wait and
  -- every reply read -- counts against the frame's thinking budget, so the
  -- waits are cut to what is left of it.
  local deadline = socket.gettime() + self.thinking:snapshot().ceiling * SurvivalLink.TARGET_SHARE
  -- the game's window of keys goes with the board: the frames ago each key still inside it was pressed
  local ages = self.inputs:ages(clock, self.ages)
  local budget = ',"budget":{"limit":' .. self.inputs.limit .. ',"window":' .. self.inputs.window .. ',"ages":[' .. table.concat(ages, ",") .. ']}'
  self:send('{"t":"f","state":' .. SurvivalLink.dump(stack, sources) .. budget .. '}')
  self.awaiting = (self.awaiting or 0) + 1
  self.frames = self.frames + 1
  -- Answers come in order; one for an earlier frame is stale, but the keys
  -- it planned (reply.next, from the frame after its own) are the newest
  -- known. A frame whose answer is late presses what was planned for it.
  while self.awaiting > 0 do
    local line = self:await(math.min(deadline, socket.gettime() + self.waitSec))
    if not line then
      self.late = self.late + 1
      local planned = self.planned and self.planned[clock]
      return planned and KeyDataEncoding.base64encode[planned + 1] or idle
    end
    self.awaiting = self.awaiting - 1
    local reply = json.decode(line)
    if reply and reply.clock then
      self.planned = {}
      for i, bits in ipairs(reply.next or {}) do self.planned[reply.clock + i] = bits end
    end
    if reply and reply.clock == clock then
      return KeyDataEncoding.base64encode[(reply.input or 0) + 1] or idle
    end
  end
  return idle
end

---The frames whose thinking cost more than the ceiling, the worst frame (seconds), and the keys the allowance refused.
function SurvivalLink:budget()
  return self.thinking:overruns(), self.thinking:worst(), self.dropped
end

function SurvivalLink:endMatch()
  if not self.sock then return end
  pcall(function() self:send('{"t":"bye"}') end)
end

return SurvivalLink
