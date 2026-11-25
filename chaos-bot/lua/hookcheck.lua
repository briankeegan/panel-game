-- THE HOOKUP CHECKED HEADLESS: the chaos Lua stack written into the bot's engine exactly as the game will write it (gambit/lua/board.lua
-- through libgambit.so's wire, nb_load), one frame run on both with the same keys, and the engine's board read back (nb_save) and
-- compared with the Lua's, every head field and every panel field. A divergence here is a divergence in a game.
--
--   luajit chaos-bot/lua/hookcheck.lua LIBGAMBIT.so SEED FRAMES [LEVEL] [SCENARIO]
-- Prints "hookcheck frames N divergences D" and exits 1 on any divergence.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = here .. "?.lua;" .. package.path
require("headless")(here .. "../reference/chaos-v3")
local ffi = require("ffi")
local Match = require("common.engine.Match")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local KeyDataEncoding = require("common.data.KeyDataEncoding")

local LIB, SEED, FRAMES, LEVEL = arg[1], tonumber(arg[2]) or 1, tonumber(arg[3]) or 2000, tonumber(arg[4]) or 9
ffi.cdef [[
double *nb_io_head(void);
int32_t *nb_io_body(void);
int nb_nhead(void);
const char *nb_head_name(int i);
typedef struct Board Board;
Board *nb_new(void);
int nb_load(Board *b);
int nb_save(Board *b);
void nb_set_input(Board *b, int32_t bits);
int nb_run(Board *b);
int nb_feed_row(Board *b, int32_t c1, int32_t c2, int32_t c3, int32_t c4, int32_t c5, int32_t c6);
int nb_feed_break(Board *b, int32_t c1, int32_t c2, int32_t c3, int32_t c4, int32_t c5, int32_t c6);
]]
local C = ffi.load(LIB)
local B = dofile(here .. "../gambit/lua/board.lua")
local H, Bd, NH = C.nb_io_head(), C.nb_io_body(), C.nb_nhead()
local HI, NAMES = {}, {}
for i = 0, NH - 1 do local n = ffi.string(C.nb_head_name(i)); HI[n] = i; NAMES[i] = n end

local state = (SEED * 2654435761) % 4294967296
local function rand(n) state = (state * 1103515245 + 12345) % 2147483648; return math.floor(state / 65536) % n end

local rules = GameModes.getPreset("ONE_PLAYER_TRAINING").matchRules
rules.doCountdown = false
local match = Match(GeneratorSource(SEED, true), rules)
match:setCountdown(false)
local QUEUE, CHAOS, MARGIN = 1 + rand(3), rand(2) == 1, 1 + rand(4)
local stack = match:createStackWithSettings(LevelPresets.getModern(LEVEL), true, "controller", nil, 6, 1, QUEUE, CHAOS, MARGIN)
stack.do_countdown = false
stack.incomingGarbage.GarbageQueueType = QUEUE
stack.incomingGarbage.illegalStuffIsAllowed = true
stack:starting_state()

-- what a frame deals, to feed the engine the same (the player never sees these ahead; the check does, so the boards can be compared)
local dealtRows, dealtBreaks = {}, {}
local src = stack.panelSource
local createNewRow, getBreak = src.createNewRow, src.getGarbagePanelRowString
src.createNewRow = function(self, st, row)
  local r = createNewRow(self, st, row)
  local c = {}; for col = 1, st.width do c[col] = r[col].color end
  dealtRows[#dealtRows + 1] = c
  return r
end
src.getGarbagePanelRowString = function(self, st)
  local s = getBreak(self, st)
  local c = {}; for col = 1, #s do c[col] = tonumber(s:sub(col, col)) end
  dealtBreaks[#dealtBreaks + 1] = c
  return s
end

local function put(k, v) local i = HI[k]; if i and v ~= nil then H[i] = v == true and 1 or v == false and 0 or v end end
-- the stack into the io, as GambitNative:load writes it (no colour hidden: the check compares the whole board)
local function load()
  for i = 0, NH - 1 do H[i] = 0 / 0 end
  B.head(stack, put)
  local inc, stall, landed = B.staged(stack), B.stall(stack), B.landed(stack)
  put("nrows", #stack.panels + 1); put("ninc", #inc); put("nstall", #stall); put("nlanded", #landed); put("err", 0)
  put("unseenRows", 0); put("unseenBreaks", 0); put("nextInput", 0); put("pressSwap", 0); put("swapDeniedThisFrame", 0)
  local x, pv = 0, {}
  for r = 0, #stack.panels do
    for c = 1, stack.width do
      local p = stack.panels[r][c]
      B.panel(p, pv, stack.width, nil)
      pv[4] = p.color
      for i = 1, B.NF do Bd[x] = pv[i]; x = x + 1 end
    end
  end
  for j = 1, #inc do x = B.putIncoming(inc[j], Bd, x) end
  for i = 1, #stall do x = B.putStall(stall[i], Bd, x) end
  for i = 1, #landed do Bd[x] = landed[i]; x = x + 1 end
  for _, d in ipairs(B.drop(stack)) do Bd[x] = d; x = x + 1 end
end

local bad, frames = 0, 0
local function report(what, lua, c)
  if bad < 30 then io.stderr:write(string.format("frame %d: %s lua %s engine %s\n", stack.clock, what, tostring(lua), tostring(c))) end
  bad = bad + 1
end
local board = C.nb_new()
local NUL = -2147483648
for f = 1, FRAMES do
  if stack:game_ended() then break end
  -- garbage now and then, of every kind
  if rand(90) == 0 then
    local k = rand(4)
    local g = k == 0 and { width = 6, height = 1 + rand(5), isChain = true, isMetal = false, finalized = true }
           or k == 1 and { width = 6, height = 1, isChain = false, isMetal = true }
           or { width = 3 + rand(4), height = 1 + (rand(4) == 0 and rand(3) or 0), isChain = false, isMetal = false }
    g.frameEarned = stack.clock
    stack.incomingGarbage:push(g)
  end
  load()
  local err = C.nb_load(board)
  if err ~= 0 then report("nb_load error", 0, err); break end
  local bits = 0
  local d = rand(9)
  if d < 4 then bits = ({ 1, 2, 4, 8 })[d + 1] end
  if rand(4) == 0 then bits = bits + 16 end
  dealtRows, dealtBreaks = {}, {}
  stack:receiveConfirmedInput(KeyDataEncoding.base64encode[bits + 1])
  stack:run()
  for _, r in ipairs(dealtRows) do C.nb_feed_row(board, r[1], r[2], r[3], r[4], r[5], r[6]) end
  for _, r in ipairs(dealtBreaks) do C.nb_feed_break(board, r[1], r[2], r[3], r[4], r[5], r[6]) end
  C.nb_set_input(board, bits)
  C.nb_run(board)
  local saved = C.nb_save(board)
  -- the engine's head against the Lua's, by name
  local want = {}
  B.head(stack, function(k, v) if v ~= nil then want[k] = v == true and 1 or v == false and 0 or v end end)
  for k, v in pairs(want) do
    local i = HI[k]
    if i then
      local got = H[i]
      if got ~= got then got = nil end
      if got ~= v and not (got == nil and v == nil) then report(k, v, got) end
    end
  end
  -- every panel
  local x, pv = 0, {}
  if H[HI["nrows"]] ~= #stack.panels + 1 then report("nrows", #stack.panels + 1, H[HI["nrows"]])
  else
    for r = 0, #stack.panels do
      for c = 1, stack.width do
        local p = stack.panels[r][c]
        B.panel(p, pv, stack.width, nil)
        pv[4] = p.color
        for i = 1, B.NF do
          if Bd[x] ~= pv[i] then report(string.format("panel %d,%d field %d", r, c, i), pv[i], Bd[x]) end
          x = x + 1
        end
      end
    end
  end
  frames = frames + 1
  if bad > 0 then break end
end
print(string.format("hookcheck frames %d divergences %d seed %d level %d queue %d chaos %s margin %d", frames, bad, SEED, LEVEL, QUEUE, tostring(CHAOS), MARGIN))
os.exit(bad == 0 and 0 or 1)
