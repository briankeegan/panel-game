-- BITBOT, NATIVE: GameCreator's BitBot playing a stack of this engine,
-- inside this process.
--
-- BitBot is C now (GameCreator games/the-game/ai/eval/native: bit.c, bot.c,
-- front.c on pa.c, the server's rules), built as native/libbit.so. This is
-- GameCreator's own hookup for it, lua/train.lua, frame for frame: each frame
-- the stack is written into BitBot's board (lua/cboard.lua, native/pa.h), the
-- rows and garbage colours to come are fed as train.lua feeds them, and
-- front_frame gives the keys -- plus swap if the board says one was pressed.
-- Nothing is decided or pressed here.
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

local BitBotNative = {}
BitBotNative.__index = BitBotNative

-- BitBot's library, its declarations and cboard.lua, once per process.
local C, CB
local function load(dir)
  if C then return end
  local f = assert(io.open(dir .. "/lua/train.lua"), "BitBotNative: no lua/train.lua under GC_EVAL_DIR=" .. dir)
  local src = f:read("*a"); f:close()
  local cdef = src:match("ffi%.cdef%s*%[%[(.-)%]%]")
  assert(cdef, "BitBotNative: lua/train.lua has no ffi.cdef block to take BitBot's declarations from")
  ffi.cdef(cdef)
  C = ffi.load(dir .. "/native/libbit.so")
  CB = dofile(dir .. "/lua/cboard.lua")
end

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

function BitBotNative:startMatch(stack)
  load(self.dir)
  self.stack = stack
  self.board = C.nb_new()
  self.fid = -1
  -- What the stack will be dealt, off a copy of its source, and a count of
  -- what it has taken -- train.lua takes these once the countdown is over;
  -- the countdown deals nothing, so they are the same now, and taking them
  -- here keeps their cost (a fraction of a second) out of the first frame.
  self.dealt = { rows = 0, brks = 0 }
  self.rows, self.brks = CB.stream(stack, 20000)
  local src, dealt = stack.panelSource, self.dealt
  local newRow, brkRow = src.createNewRow, src.getGarbagePanelRowString
  src.createNewRow = function(...) dealt.rows = dealt.rows + 1; return newRow(...) end
  src.getGarbagePanelRowString = function(...) dealt.brks = dealt.brks + 1; return brkRow(...) end
  self.frames, self.maxMs = 0, 0
  self.HI, self.NH = {}, C.nb_nhead()
  for i = 0, self.NH - 1 do self.HI[ffi.string(C.nb_head_name(i))] = i end
  self.pv = {}
end

-- train.lua load(): the stack into BitBot's board, and the rows and garbage
-- colours it has not dealt yet.
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
  for i = self.dealt.rows + 1, #self.rows do
    local r = self.rows[i]
    if C.nb_feed_row(self.board, r[1], r[2], r[3], r[4], r[5], r[6]) == 0 then break end
  end
  for i = self.dealt.brks + 1, #self.brks do
    local r = self.brks[i]
    if C.nb_feed_break(self.board, r[1], r[2], r[3], r[4], r[5], r[6]) == 0 then break end
  end
end

-- The key to press this frame. Through the countdown nothing is pressed
-- (train.lua plays it out idle); BitBot starts when the stopwatch does.
function BitBotNative:input(stack)
  local idle = KeyDataEncoding.base64encode[1]
  if stack.in_countdown or not stack.stopWatchIsRunning or stack:game_ended() then return idle end
  local t0 = os.clock()
  self:load(stack)
  if self.fid < 0 then self.fid = C.front_new(self.board, self.reaction, self.allowRaise) end
  local bits = C.front_frame(self.fid, self.board)
  if bits < 0 then error("BitBotNative: BitBot failed at clock " .. tostring(stack.clock)) end
  if C.nb_pressed(self.board) ~= 0 then bits = bit.bor(bits, 16) end
  self.frames = self.frames + 1
  local ms = (os.clock() - t0) * 1000
  self.maxMs = math.max(self.maxMs, ms)
  self.slowMs = math.max(self.slowMs or 0, ms)
  -- a line every 10 seconds of play, for the log: is it moving, and in time
  if self.frames % 600 == 0 then
    local top = 0
    for r = #stack.panels, 1, -1 do
      for c = 1, stack.width do if stack.panels[r][c].color ~= 0 then top = r; break end end
      if top > 0 then break end
    end
    print(string.format("bitbot: clock %d swaps %d cleared %d top row %d health %d slowest %.1f ms",
      stack.clock, stack.swapCount or 0, stack.panels_cleared or 0, top, stack.health or 0, self.slowMs))
    self.slowMs = 0
  end
  return KeyDataEncoding.base64encode[bits + 1]
end

function BitBotNative:endMatch() end

return BitBotNative
