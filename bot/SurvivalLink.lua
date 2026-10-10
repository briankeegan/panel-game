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
-- The board is written into one reusable list of pieces and joined once, so a
-- frame makes one long string and none of the short ones the key-by-key
-- concatenation made (a few thousand on a board with garbage on it).
local buf, used = {}, 0
local function put(piece) used = used + 1; buf[used] = piece end
-- the text of a number, an object key (with and without the comma before it) and a string value, each made once
local numbers = setmetatable({}, { __index = function(t, v)
  local text = num(v)
  if v % 1 == 0 and v > -1e6 and v < 1e6 then t[v] = text end
  return text
end })
local firstKey = setmetatable({}, { __index = function(t, k) local q = string.format("%q", tostring(k)) .. ":"; t[k] = q; return q end })
local nextKey = setmetatable({}, { __index = function(t, k) local q = "," .. string.format("%q", tostring(k)) .. ":"; t[k] = q; return q end })
local words = setmetatable({}, { __index = function(t, v)
  local q = (string.format("%q", v):gsub("\\\n", "\\n"))
  if #v < 40 then t[v] = q end
  return q
end })
local function putScalar(v)
  local t = type(v)
  if t == "number" then
    if v ~= v then put('"NaN"') elseif v == math.huge then put('"Infinity"') elseif v == -math.huge then put('"-Infinity"') else put(numbers[v]) end
  elseif t == "boolean" then put(v and "true" or "false")
  else put(words[v]) end
end
-- A table's number, boolean and string fields as a JSON object.
local function putScalars(t)
  local first = true
  put("{")
  for k, v in pairs(t) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then
      put(first and firstKey[k] or nextKey[k])
      first = false
      putScalar(v)
    end
  end
  put("}")
end
-- a list of garbage blocks; an empty list is the empty object, as `enc` writes it
local function putGarbage(q)
  local n = q and #q or 0
  if n == 0 then put("{}") return end
  put("[")
  for i = 1, n do
    local g = q[i]
    if i > 1 then put(",") end
    put('{"width":') putScalar(g.width)
    put(',"height":') putScalar(g.height)
    put(',"isMetal":') putScalar(g.isMetal or false)
    put(',"isChain":') putScalar(g.isChain or false)
    if g.frameEarned ~= nil then put(',"frameEarned":') putScalar(g.frameEarned) end
    if g.finalized ~= nil then put(',"finalized":') putScalar(g.finalized) end
    put("}")
  end
  put("]")
end
-- The garbage each source has sent and not yet delivered: what its
-- telegraph shows (staged, oldest last) and what has left it (transit, by
-- the stopWatch it lands on). Its colours are not in it.
local function putTelegraph(sources)
  if not sources or #sources == 0 then put("{}") return end
  put("[")
  for i, src in ipairs(sources) do
    local q = src.outgoingGarbage
    if i > 1 then put(",") end
    put("{")
    if src.stopWatch ~= nil then put('"stopWatch":') putScalar(src.stopWatch) put(",") end
    put('"staged":') putGarbage(q and q.stagedGarbage)
    put(',"transit":')
    local any = false
    if q and q.transitTimers then
      for k = q.transitTimers.first, q.transitTimers.last do
        local t = q.transitTimers[k]
        if t then
          put(any and "," or "[")
          any = true
          put('{"at":') putScalar(t)
          put(',"garbage":') putGarbage(q.garbageInTransit[t])
          put("}")
        end
      end
    end
    put(any and "]" or "{}")
    put("}")
  end
  put("]")
end
local function scalars(t)
  local o = {}
  for k, v in pairs(t) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then o[k] = v end
  end
  return o
end

function SurvivalLink.dump(s, sources, prefix, suffix)
  used = 0
  if prefix then put(prefix) end
  put('{"stack":')
  putScalars(s)
  put(',"panels":[')
  local width = s.width
  for r = 0, #s.panels do
    local row = s.panels[r]
    put(r > 0 and ",[" or "[")
    for c = 1, width do
      if c > 1 then put(",") end
      local p = row and row[c]
      if p then putScalars(p) else put("false") end
    end
    put("]")
  end
  put('],"incoming":{"staged":')
  putGarbage(s.incomingGarbage.stagedGarbage)
  put("}")
  local backlog = {}
  for i, rec in ipairs(s.swapStallingBackLog or {}) do backlog[i] = scalars(rec) end
  local landed = {}
  for i, id in ipairs(s.garbageLandedThisFrame or {}) do landed[i] = id end
  put(',"swapStallingBackLog":') put(enc(backlog))
  put(',"garbageLandedThisFrame":') put(enc(landed))
  put(',"dropColumns":') put(enc(s.currentGarbageDropColumnIndexes))
  put(',"telegraph":') putTelegraph(sources)
  put("}")
  if suffix then put(suffix) end
  return table.concat(buf, "", 1, used)
end

-- Every field a panel can carry, with the kinds of value it takes. The compiler
-- compiles the encoder for the shapes it has seen and compiles again, inside a
-- frame, for each new one -- a loop of more than ~56 turns is compiled the first
-- time one runs that long, so the garbage lists run to 130 blocks. `warm` shows
-- it every shape before the match.
local PANEL_FIELDS = {
  chaining = "b", combo_index = "n", combo_size = "n", fell_from_garbage = "n", isSwappingFromLeft = "b",
  matchesGarbage = "b", matchesMetal = "b", matching = "b", propagatesChaining = "b", propagatesFalling = "b",
  state = "s", stateChanged = "b", timer = "n", color = "n", column = "n", row = "n", id = "n", dont_swap = "b",
  garbageId = "n", height = "n", initial_time = "n", isGarbage = "b", matchAnyway = "b", metal = "b", pop_index = "n",
  pop_time = "n", queuedHover = "b", senderId = "n", shake_time = "n", width = "n", x_offset = "n", y_offset = "n",
}
local WARM_STATES = { "normal", "swapping", "matched", "popping", "popped", "hovering", "falling", "landing", "dimmed", "dead" }
local function warmValue(kind, i)
  if kind == "b" then return i % 2 == 0 end
  if kind == "s" then return WARM_STATES[i % #WARM_STATES + 1] end
  return (i % 3 == 0) and (i % 97) or ((i % 3 == 1) and (i % 97) + 0.5 or -(i % 7))
end
local function warmGarbage(i)
  local list = {}
  for k = 1, i % 130 do
    list[k] = { width = 3 + k % 4, height = 1 + (i + k) % 3, isMetal = k % 2 == 0, isChain = (i + k) % 2 == 0,
                frameEarned = i * 7 + k, finalized = (i + k) % 3 == 0 }
  end
  return list
end
---Encodes boards of every shape the game can make, so the compiler has compiled the encoder before the first frame
---and compiles nothing for it within one.
function SurvivalLink.sampleBoard(i)
  local names = {}
  for name in pairs(PANEL_FIELDS) do names[#names + 1] = name end
  table.sort(names)
  local panels = {}
  for r = 0, 12 do
    panels[r] = {}
    for c = 1, 6 do
      if (r + c + i) % 5 ~= 0 then
        local p = {}
        for k, name in ipairs(names) do
          if (k + r * 3 + c + i) % 3 ~= 0 then p[name] = warmValue(PANEL_FIELDS[name], k + r + c + i) end
        end
        panels[r][c] = p
      end
    end
  end
  local s = { width = 6, panels = panels, clock = i, stopWatch = i, health = 3, rise_timer = i % 40, shake_time = i % 50,
              incomingGarbage = { stagedGarbage = warmGarbage(i) }, swapStallingBackLog = (i % 3 == 0) and { { frame = i, chaining = true } } or {},
              garbageLandedThisFrame = (i % 4 == 0) and { i } or {}, currentGarbageDropColumnIndexes = (i % 2 == 0) and { 1, 3 } or { 2 },
              danger = i % 2 == 0, mode = "vs" }
  local sources = { { stopWatch = (i % 7 ~= 0) and i or nil, outgoingGarbage = { stagedGarbage = warmGarbage(i + 2),
                      transitTimers = { first = i, last = i + 1, [i] = i + 30 }, garbageInTransit = { [i + 30] = warmGarbage(i + 3) } } } }
  return s, (i % 5 == 0) and {} or sources
end
function SurvivalLink.warm()
  for i = 1, 400 do SurvivalLink.dump(SurvivalLink.sampleBoard(i)) end
  -- A frame runs with the collector stopped, so the heap grows by everything the frame makes. Memory
  -- the process has not touched before is mapped when it is first written, which a frame should
  -- not wait for: grow the heap by several frames' worth now, then free it for the frames to reuse.
  collectgarbage("stop")
  for i = 1, 8 do SurvivalLink.dump(SurvivalLink.sampleBoard(129 + i * 130)) end
  collectgarbage("restart")
  collectgarbage()
end

-- A frame is held to this share of the thinking ceiling: what the system's own
-- pauses take from a frame comes out of the rest.
SurvivalLink.TARGET_SHARE = 0.35
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
  self.phase = { encode = 0, send = 0, wait = 0, read = 0, overBy = { encode = 0, send = 0, wait = 0, read = 0 } }
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

-- What goes to the survival bot in a frame never waits: a message the socket
-- cannot take whole stays in the outbox and goes with the next call, in order.
-- `now` (the match's start and end, outside any frame) waits for it.
function SurvivalLink:send(line, now, complete)
  local box = self.outbox
  if complete and (box == nil or box == "") then
    self.outbox = line   -- already ends in its newline: no second copy of a board
  else
    self.outbox = (box or "") .. line .. (complete and "" or "\n")
  end
  self:flush(now)
end

function SurvivalLink:flush(now)
  local box = self.outbox
  if not box or box == "" then return end
  self.sock:settimeout(now and 2 or 0)
  local sent, err, partial = self.sock:send(box)
  if sent then self.outbox = ""; return end
  if err ~= "timeout" then error("SurvivalLink: send failed: " .. tostring(err)) end
  self.outbox = partial and partial > 0 and box:sub(partial + 1) or box
  if now then error("SurvivalLink: send timed out") end
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

-- The next reply line, or nil at `deadline` (socket.gettime seconds). A wait
-- that blocks hands its thread back to the system, which returns it late when
-- every core is busy, so the whole wait polls.
function SurvivalLink:await(deadline)
  local before = socket.gettime()
  local line = self:receive(0)
  local now = socket.gettime()
  local longest = now - before
  while not line and now < deadline do
    line = self:receive(0)
    local after = socket.gettime()
    if after - now > longest then longest = after - now end
    now = after
  end
  if longest > self.longestPoll then self.longestPoll = longest end
  return line
end

function SurvivalLink:startMatch(stack)
  self:connect()
  SurvivalLink.warm()
  self:send(enc({ t = "match", levelData = stack.levelData, behaviours = stack.behaviours,
                  stackOverConditions = stack.stackOverConditions }), true)
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
  local stopOnOver = os.getenv("PA_STOP_ON_OVER") == "1"
  if stopOnOver and not SurvivalLink.tracing then
    SurvivalLink.tracing = { events = 0 }
    require("jit").attach(function() SurvivalLink.tracing.events = SurvivalLink.tracing.events + 1 end, "trace")
  end
  local traces0 = stopOnOver and SurvivalLink.tracing.events or 0
  local before = stopOnOver and SurvivalLink.machine() or nil
  local minor0, major0 = 0, 0
  if stopOnOver then minor0, major0 = SurvivalLink.faults() end
  collectgarbage("stop")
  local began = ThinkBudget.now()
  local cpu0 = os.clock()
  local ok, key = pcall(self.think, self, stack, sources)
  if ok and self.ownInputs then key = self:press(key, stack.clock) end
  local took = ThinkBudget.now() - began
  local cpu = os.clock() - cpu0
  collectgarbage("restart")
  if not ok then error(key, 0) end
  if self.ownThinking then self.thinking:charge(took) end
  local st = self.steps
  if st then
    for name, v in pairs(st) do
      if v > self.phase[name] then self.phase[name] = v end
      if took > self.thinking:snapshot().ceiling and v > self.phase.overBy[name] then self.phase.overBy[name] = v end
    end
    self.steps = nil
  end
  local faultsNow
  if stopOnOver then
    faultsNow = SurvivalLink.faults()
    self.faultFrames = (self.faultFrames or 0) + 1
    self.faultTotal = (self.faultTotal or 0) + (faultsNow - minor0)
  end
  -- PA_STOP_ON_OVER=1: the first frame over the ceiling ends the run, with what the machine and the frame did
  if stopOnOver and took > self.thinking:snapshot().ceiling and not self.stopReason then
    local after = SurvivalLink.machine()
    local text = {}
    for name, v in pairs(st or {}) do text[#text + 1] = string.format("%s %.1f", name, v * 1000) end
    table.sort(text)
    self.stopReason = string.format("STOPPED on the first frame over the ceiling: clock %d, wall %.1f ms, this process's cpu %.1f ms, steps (ms) [%s], compiler events in the frame %d, longest single poll %.1f ms, board %d bytes, garbage staged %d / in telegraphs %d; page faults in the frame: %d minor, %d major (%.1f a frame on average over the %d frames before); the machine over the frame: stolen %.1f ms, busy %.1f ms of %.1f ms, runnable %d, load %s",
      stack.clock, took * 1000, cpu * 1000, table.concat(text, ", "), SurvivalLink.tracing.events - traces0, (self.longestPoll or 0) * 1000, self.boardBytes or 0, #stack.incomingGarbage.stagedGarbage, SurvivalLink.telegraphCount(sources), faultsNow - minor0, select(2, SurvivalLink.faults()) - major0, ((self.faultTotal or 0) - (faultsNow - minor0)) / math.max(1, (self.faultFrames or 1) - 1), (self.faultFrames or 1) - 1, (after.steal - before.steal) * 10, (after.busy - before.busy) * 10, (after.total - before.total) * 10, after.running, after.load)
  end
  return key
end

---The process's minor and major page faults so far (/proc/self/stat), or zeros.
function SurvivalLink.faults()
  local f = io.open("/proc/self/stat", "r")
  if not f then return 0, 0 end
  local line = f:read("*l") or ""; f:close()
  local n = {}
  for v in (line:match("%) (.*)$") or ""):gmatch("%S+") do n[#n + 1] = v end
  return tonumber(n[8]) or 0, tonumber(n[10]) or 0
end

---How many garbage blocks the sources' telegraphs hold, staged and in transit.
function SurvivalLink.telegraphCount(sources)
  local n = 0
  for _, src in ipairs(sources or {}) do
    local q = src.outgoingGarbage
    if q then
      n = n + #q.stagedGarbage
      for _, list in pairs(q.garbageInTransit or {}) do n = n + #list end
    end
  end
  return n
end

---What the machine has done: jiffies (10 ms) stolen from it, busy and in all, on every cpu together (/proc/stat), the
---runnable threads now and the load average (/proc). Zeros where there is no /proc.
function SurvivalLink.machine()
  local m = { steal = 0, busy = 0, total = 0, running = 0, load = "?" }
  local f = io.open("/proc/stat", "r")
  if f then
    local line = f:read("*l"); f:close()
    local n = {}
    for v in (line or ""):gmatch("%d+") do n[#n + 1] = tonumber(v) end
    for i, v in ipairs(n) do m.total = m.total + v end
    m.steal = n[8] or 0
    m.busy = m.total - (n[4] or 0) - (n[5] or 0)
  end
  local l = io.open("/proc/loadavg", "r")
  if l then
    local text = l:read("*l") or ""; l:close()
    m.load = text:match("^(%S+ %S+ %S+)") or "?"
    m.running = tonumber(text:match("(%d+)/%d+")) or 0
  end
  return m
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
  local t0 = socket.gettime()
  local line = SurvivalLink.dump(stack, sources, '{"t":"f","state":', budget .. "}\n")
  self.boardBytes = #line
  local t1 = socket.gettime()
  self:send(line, nil, true)
  local t2 = socket.gettime()
  self.longestPoll = 0
  self.steps = { encode = t1 - t0, send = t2 - t1, wait = 0, read = 0 }
  self.awaiting = (self.awaiting or 0) + 1
  self.frames = self.frames + 1
  -- Answers come in order; one for an earlier frame is stale, but the keys
  -- it planned (reply.next, from the frame after its own) are the newest
  -- known. A frame whose answer is late presses what was planned for it.
  while self.awaiting > 0 do
    local w0 = socket.gettime()
    local line = self:await(math.min(deadline, socket.gettime() + self.waitSec))
    self.steps.wait = self.steps.wait + (socket.gettime() - w0)
    if not line then
      self.late = self.late + 1
      local planned = self.planned and self.planned[clock]
      return planned and KeyDataEncoding.base64encode[planned + 1] or idle
    end
    self.awaiting = self.awaiting - 1
    local r0 = socket.gettime()
    local reply = json.decode(line)
    self.steps.read = self.steps.read + (socket.gettime() - r0)
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
---The longest each step of a frame took, and the longest each took in a frame that went over the ceiling (seconds).
function SurvivalLink:phases()
  return self.phase
end

function SurvivalLink:budget()
  return self.thinking:overruns(), self.thinking:worst(), self.dropped
end

function SurvivalLink:endMatch()
  if not self.sock then return end
  pcall(function() self:send('{"t":"bye"}', true) end)
end

-- NOTHING IN A FRAME IS COMPILED. The compiler records and compiles a loop the first time it
-- runs hot -- the first board with a long list of garbage on it, the first long wait -- and a
-- compile inside the frame costs several milliseconds. This code is built from calls into C and
-- table writes, which the compiler does not speed up, so it runs interpreted, at the same speed
-- every frame.
if jit and jit.off then
  for _, f in pairs(SurvivalLink) do
    if type(f) == "function" then jit.off(f, true) end
  end
  for _, f in ipairs({ num, enc, put, putScalar, putScalars, putGarbage, putTelegraph, scalars,
                       getmetatable(numbers).__index, getmetatable(words).__index,
                       getmetatable(firstKey).__index, getmetatable(nextKey).__index, getmetatable(quoted).__index }) do
    jit.off(f, true)
  end
end

return SurvivalLink
