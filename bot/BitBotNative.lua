-- BITBOT, NATIVE: GameCreator's BitBot playing a stack of this engine,
-- inside this process.
--
-- BitBot is C now (GameCreator games/the-game/ai/eval/native: bit.c, bot.c,
-- front.c on pa.c, the server's rules), built as native/libbit.so. This is
-- GameCreator's own hookup for it, lua/train.lua, frame for frame: each frame
-- the stack is written into BitBot's board (lua/cboard.lua, native/pa.h) and
-- front_frame gives the keys -- plus swap if the board says one was pressed.
-- Nothing is decided or pressed here.
--
-- ONE DIFFERENCE FROM train.lua, ON PURPOSE: BitBot sees what a human sees.
-- train.lua also feeds the rows the stack will be dealt and the colours its
-- garbage will break into (off a copy of the generator); a player sees only
-- the board, the dimmed next row included. So nothing is fed: a row or a
-- break BitBot's engine needs and was not given takes pa.c's UNSEEN_COLOUR,
-- which matches nothing and which front.c leaves alone.
--
-- Everything BitBot-side is read from GameCreator's checkout at GC_EVAL_DIR
-- (<GameCreator>/games/the-game/ai/eval) when a match starts -- cboard.lua,
-- libbit.so, and the C declarations, taken from train.lua's own ffi.cdef --
-- so this follows whatever its main has. libbit.so is built by the line in
-- native/build.sh that builds it (bot/fight.sh does that).
--
--   local bb = require("bot.BitBotNative").new({})
--   bb:startMatch(stack)               -- once per match
--   local char = bb:input(stack)       -- every frame, before it is run
local ffi = require("ffi")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local ThinkBudget = require("common.engine.computerPlayers.ThinkBudget")

local DEATHLOG = tonumber(os.getenv("PA_BITBOT_DEATHLOG") or 90)   -- frames of BitBot's own log kept, printed if it dies (train.lua GC_DEATHLOG)
local LOGP, LOGN = ffi.new("char *[1]"), ffi.new("size_t[1]")
local BOT_TIME = os.getenv("PA_BITBOT_BOT_TIME") == "1"
local BOTLOG_FRAMES = tonumber(os.getenv("PA_BITBOT_LOG_FRAMES") or 30)   -- the first 30 live frames only: the trace is written inside the timed decision, and bot_time reads that as slow

local BitBotNative = {}
BitBotNative.__index = BitBotNative

-- BitBot's library, its declarations and cboard.lua, once per process.
local C, CB, TS
local BOARD, FID     -- one board and one BitBot per process: libbit restarts its front itself when the clock goes back
local function load(dir)
  if C then return end
  local f = assert(io.open(dir .. "/lua/train.lua"), "BitBotNative: no lua/train.lua under GC_EVAL_DIR=" .. dir)
  local src = f:read("*a"); f:close()
  local cdef = src:match("ffi%.cdef%s*%[%[(.-)%]%]")
  assert(cdef, "BitBotNative: lua/train.lua has no ffi.cdef block to take BitBot's declarations from")
  ffi.cdef(cdef)
  C = ffi.load(dir .. "/native/libbit.so")
  TS = ffi.new("gc_timespec")     -- declared in train.lua's cdef, with clock_gettime
  CB = dofile(dir .. "/lua/cboard.lua")
end

-- Wall-clock milliseconds, as train.lua times a frame (CLOCK_MONOTONIC). Not os.clock():
-- that is CPU time, and BitBot thinks on worker threads, so it counts every thread at once
-- and shows the bot a frame several times as slow as it was -- it then cuts its search.
local function nowMs() ffi.C.clock_gettime(1, TS); return tonumber(TS.tv_sec) * 1e3 + tonumber(TS.tv_nsec) / 1e6 end

function BitBotNative.new(opts)
  opts = opts or {}
  local self = setmetatable({}, BitBotNative)
  self.dir = opts.dir or os.getenv("GC_EVAL_DIR")
  assert(self.dir and self.dir ~= "", "BitBotNative: GC_EVAL_DIR=<GameCreator>/games/the-game/ai/eval")
  self.reaction = opts.reaction or 12     -- train.lua's front_new(board, 12, 1)
  self.allowRaise = opts.allowRaise == false and 0 or 1
  self.frames, self.late, self.maxMs = 0, 0, 0
  return self
end

function BitBotNative:startMatch(stack, match)
  self.match = match
  self.lastThought = 0
  load(self.dir)
  local t0 = os.clock()
  self.matchNo = (self.matchNo or 0) + 1
  self.firstLive, self.pressed, self.idleFrames = nil, 0, 0
  self.raiseFrames, self.raiseRuns, self.raiseDown = 0, 0, false
  print(string.format("bitbot: match begins (front restarts itself on a new clock; loaded in %.0f ms)", (os.clock() - t0) * 1000))
  self.stack = stack
  BOARD = BOARD or C.nb_new()
  self.board = BOARD
  self.fid = FID or -1
  self.frames, self.maxMs = 0, 0
  self.HI, self.NH = {}, C.nb_nhead()
  for i = 0, self.NH - 1 do self.HI[ffi.string(C.nb_head_name(i))] = i end
  self.pv = {}
  -- BitBot is given the board and made now, before the countdown runs a frame
  self:load(stack)
  if self.fid < 0 then
    self.fid = C.front_new(self.board, self.reaction, self.allowRaise)
    if self.fid < 0 then error("BitBotNative: BitBot could not be created (front_new answered " .. self.fid .. ")") end
    FID = self.fid
  end
  self:tellOpponent(stack)
end

-- train.lua load(): the stack into BitBot's board -- and nothing to come
-- (see the top).
function BitBotNative:load(a)
  local HI, NH, pv = self.HI, self.NH, self.pv
  local H, B = C.nb_io_head(), C.nb_io_body()
  for i = 0, NH - 1 do H[i] = 0 / 0 end
  for k, v in pairs(CB.head(a)) do
    local i = HI[k]
    if i then H[i] = v == true and 1 or v == false and 0 or v end
  end
  local inc, stall, landed = CB.incoming(a), CB.stall(a), CB.landed(a)
  local made = { nrows = #a.panels + 1, ninc = #inc, nstall = #stall, nlanded = #landed, err = 0, unseenRows = 0,
                 unseenBreaks = 0, nextInput = 0, pressSwap = 0, swapDeniedThisFrame = 0 }
  for k, v in pairs(made) do H[HI[k]] = v end
  local x = 0
  for r = 0, #a.panels do
    for c = 1, a.width do
      CB.panel(a.panels[r][c], pv)
      for i = 1, CB.NF do B[x] = pv[i]; x = x + 1 end
    end
  end
  for _, g in ipairs(inc) do for i = 1, 6 do B[x] = g[i]; x = x + 1 end end
  for _, s in ipairs(stall) do for i = 1, 5 do B[x] = s[i]; x = x + 1 end end
  for _, id in ipairs(landed) do B[x] = id; x = x + 1 end
  for _, d in ipairs(CB.drop(a)) do B[x] = d; x = x + 1 end
  local err = C.nb_load(self.board)
  if err ~= 0 then error("BitBotNative: BitBot's engine refused the board (err " .. err .. ")") end
end

-- Everything handed to BitBot on this frame, to be read against what train.lua
-- hands it on the same frame: the head, field by field, and the board.
function BitBotNative:dump(a)
  local H, out = C.nb_io_head(), {}
  for i = 0, self.NH - 1 do out[#out + 1] = ffi.string(C.nb_head_name(i)) .. "=" .. tostring(tonumber(H[i])) end
  print(string.format("bitbot: HEAD at live frame %d clock %d: %s", self.frames, a.clock, table.concat(out, " ")))
  for r = #a.panels, 0, -1 do
    local row = {}
    for c = 1, a.width do
      local p = a.panels[r][c]
      row[c] = string.format("%s%d", p.isGarbage and "g" or "", p.color or 0)
    end
    print(string.format("bitbot: BOARD row %2d: %s", r, table.concat(row, " ")))
  end
end

-- What the host tells BitBot about the opponent (train.lua leaves this to the
-- harness): another player is in the match, and that stack has lost.
function BitBotNative:tellOpponent(stack)
  local present, topped = 0, 0
  for _, other in pairs(self.match and self.match.stacks or {}) do
    if other ~= stack then
      present = 1
      if other:game_ended() then topped = 1 end
    end
  end
  C.front_opponent(self.fid, present, topped)
end

-- The key to press this frame. Through the countdown nothing is pressed
-- (train.lua plays it out idle); BitBot starts when the stopwatch does.
function BitBotNative:input(stack)
  local idle = KeyDataEncoding.base64encode[1]
  if stack.in_countdown or not stack.stopWatchIsRunning or stack:game_ended() then
    -- train.lua makes the bot during the countdown, not on a live frame
    if self.fid < 0 and not stack:game_ended() then
      self:load(stack)
      self.fid = C.front_new(self.board, self.reaction, self.allowRaise)
      FID = self.fid
    end
    return idle
  end
  local t0 = os.clock()
  local tb0 = nowMs()
  self:load(stack)
  local loadMs = nowMs() - tb0
  if self.fid < 0 then self.fid = C.front_new(self.board, self.reaction, self.allowRaise); FID = self.fid end
  if self.fid < 0 then error("BitBotNative: BitBot could not be created (front_new answered " .. self.fid .. ")") end
  -- BitBot's own log of its decisions (train.lua's GC_BOTLOG), for the opening
  -- frames of each match: what it decided, and why, while it was standing still
  local logging = self.frames < BOTLOG_FRAMES
  if logging then io.stderr:write("@ clock " .. tostring(stack.clock) .. "\n"); C.botTraceOn = 1 end
  -- the host's part, every frame before front_frame (train.lua): the think
  -- ceiling and what the last frame's thinking took, and the opponent
  if self.frames == 1 or self.frames == 100 then self:dump(stack) end   -- outside the timed part
  local tb1 = nowMs()
  self:tellOpponent(stack)
  -- bot_time (train.lua calls it) is OFF unless PA_BITBOT_BOT_TIME=1: it makes the bot cut its search to the
  -- time it measures, and on a CI runner shared with other bots that time is not its own -- it fell back to
  -- raising and stopped evaluating swaps. Without it the bot's own budgets stand (bot.c: "With no host the
  -- start values stand").
  if BOT_TIME then C.bot_time(ThinkBudget.ceilingMillis(), self.lastThought, ThinkBudget.ceilingMillis() - loadMs) end
  local mem
  if DEATHLOG > 0 and not logging then mem = ffi.C.open_memstream(LOGP, LOGN); C.botLogTo = mem; C.botTraceOn = 1 end
  local bits = C.front_frame(self.fid, self.board)
  if mem then
    ffi.C.fclose(mem); C.botLogTo = nil; C.botTraceOn = 0
    local blog = ffi.string(LOGP[0], LOGN[0]); ffi.C.free(LOGP[0])
    self.ring = self.ring or {}
    local keep = { clock = stack.clock, log = blog, bits = bits }
    if self.frames % 3 == 0 then keep.board = self:boardText(stack) end
    self.ring[self.frames % DEATHLOG + 1] = keep
  end
  self.lastThought = loadMs + (nowMs() - tb1)     -- ms: this frame's load and front_frame, as train.lua charges it
  if logging then C.botTraceOn = 0 end
  if bits < 0 then error("BitBotNative: BitBot failed at clock " .. tostring(stack.clock)) end
  if C.nb_pressed(self.board) ~= 0 then bits = bit.bor(bits, 16) end
  -- how the raise key goes out: frames held, and in how many separate presses
  if bit.band(bits, 32) ~= 0 then
    self.raiseFrames = (self.raiseFrames or 0) + 1
    if not self.raiseDown then self.raiseRuns = (self.raiseRuns or 0) + 1 end
    self.raiseDown = true
  else
    self.raiseDown = false
  end
  self.frames = self.frames + 1
  self.firstLive = self.firstLive or stack.clock
  if bits == 0 then self.idleFrames = self.idleFrames + 1 end
  local ms = (os.clock() - t0) * 1000
  self.maxMs = math.max(self.maxMs, ms)
  self.slowMs = math.max(self.slowMs or 0, ms)
  -- a line every 10 seconds of play, for the log: is it moving, and in time
  local early = self.frames == 60 or self.frames == 180 or self.frames == 360
  if early or self.frames % 600 == 0 then
    local top = 0
    for r = #stack.panels, 1, -1 do
      for c = 1, stack.width do if stack.panels[r][c].color ~= 0 then top = r; break end end
      if top > 0 then break end
    end
    print(string.format("bitbot: live frame %d clock %d swaps %d cleared %d top row %d health %d slowest %.1f ms",
      self.frames, stack.clock, stack.swapCount or 0, stack.panels_cleared or 0, top, stack.health or 0, self.slowMs))
    self.slowMs = 0
  end
  return KeyDataEncoding.base64encode[bits + 1]
end

function BitBotNative:topRow(stack)
  for r = #stack.panels, 1, -1 do
    for c = 1, stack.width do if stack.panels[r][c].color ~= 0 then return r end end
  end
  return 0
end

function BitBotNative:boardText(stack)
  local rows = {}
  for r = math.min(#stack.panels, 13), 1, -1 do
    local row = {}
    for c = 1, stack.width do
      local p = stack.panels[r][c]
      row[c] = p.color == 0 and "." or (p.isGarbage and "g" or tostring(p.color))
    end
    rows[#rows + 1] = table.concat(row)
  end
  return table.concat(rows, " ") .. string.format(" | cur %d,%d disp %s inc %d", stack.cur_row, stack.cur_col, tostring(stack.displacement), #stack.incomingGarbage.stagedGarbage)
end

-- GameCreator's DEATH REPORT (train.lua): BitBot's own log of the last frames before it lost
function BitBotNative:deathReport(stack)
  if not self.ring or (stack.game_over_clock or -1) <= 0 then return end
  print(string.format("bitbot: DEATH REPORT -- the last %d frames before clock %d", math.min(self.frames, DEATHLOG), stack.game_over_clock))
  for f = math.max(1, self.frames - DEATHLOG + 1), self.frames do
    local k = self.ring[(f - 1) % DEATHLOG + 1]
    if k then
      io.write("@ clock ", tostring(k.clock), " keys ", tostring(k.bits), "\n", k.log)
      if k.board then io.write("  board: ", k.board, "\n") end
    end
  end
  print("bitbot: END DEATH REPORT")
end

function BitBotNative:endMatch()
  local st = self.stack
  if not st then return end
  print(string.format("bitbot: match ends -- %d live frames (first at clock %s, last at %d), %d idle, swaps %d cleared %d health %s, game over clock %s, garbage landed on it %s, queued at the end %d, top row %d, raise key held %d frames in %d presses",
    self.frames or 0, tostring(self.firstLive), st.clock or -1, self.idleFrames or 0, st.swapCount or 0, st.panels_cleared or 0,
    tostring(st.health), tostring(st.game_over_clock), tostring(st.garbageCreatedCount), #st.incomingGarbage.stagedGarbage, self:topRow(st), self.raiseFrames or 0, self.raiseRuns or 0))
  self:deathReport(st)
end

return BitBotNative
