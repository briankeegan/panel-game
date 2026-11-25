-- GAMBIT IN THE GAME'S OWN PROCESS: a stack of the panel-game client played by Gambit (libgambit.so: the C engine, Gambit and its
-- frame loop, gambit/native.c). Each frame the stack is written into the C engine's board (board.lua) as the player sees it, with the
-- garbage the senders' telegraphs show and the input budget's window, and the frame loop gives the keys. Nothing is decided here.
--
--   local G = dofile(<GameCreator>/games/the-game/ai/gambit/lua/GambitNative.lua)   -- once per process
--   local bot = G.new({})
--   bot:startMatch(stack)                 -- once per match: a fresh Gambit, the last match's quit
--   local char = bot:input(stack, sources, view)   -- every frame, before it is run (view: the opponent's shipped board, or nil)
--
-- Env: GC_GAMBIT_DIR (the gambit directory; default: this file's), GC_GAMBIT_WORDS (the profile as numbers, words.js; default
-- GC_GAMBIT_DIR/gambit.words), GC_GAMBIT_LOG (the run's log: GAMBITD lines and the match's stats).
local ffi = require("ffi")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local function budgetClass(name)
  local ok, class = pcall(require, "common.engine.computerPlayers." .. name)
  if ok then return class end
  return require("bot." .. name)
end
local ThinkBudget = budgetClass("ThinkBudget")
local InputBudget = budgetClass("InputBudget")
-- THE INPUT BUDGET: the standard one every computer player plays under (InputBudget.standard), in training and live alike. A held key
-- stops only at the wall (core/nodes.h legHeld), so a walk that ends mid-board is tapped, an action a cell, out of the same allowance.
local function counting(stack)
  if stack.do_countdown ~= nil then return stack.do_countdown end
  return stack.in_countdown
end

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/lua/[^/]*$") or "."
local DIR = os.getenv("GC_GAMBIT_DIR") or HERE
local STOP_AFTER = tonumber(os.getenv("GC_STOP_AFTER_HANDOVER") or "")

ffi.cdef [[
double *nb_io_head(void);
int32_t *nb_io_body(void);
int nb_nhead(void);
const char *nb_head_name(int i);
int gn_setup(int reaction, int swapGap, int cursor, int ahead, int gap, int jitter, int planHealth, const char *logPath);
int32_t *gn_io(void);
int gn_rules(int n);
void gn_rule_name(int i, const char *name);
void gn_profile(int mode, int ms, int extendMs, int width, int depth, int pool, int extendDepth, int extendOff);
void gn_switch(int min, int max);
void gn_share(int under, int otherwise);
void gn_then(int rule);
int32_t *gn_tele(void);
void gn_receiver_timed(int32_t on);
int32_t *gn_ages(void);
void gn_match(void);
int gn_frame(int limit, int window, int nages, int oppHas, int oppOut, int oppTop, int oppStop);
int gn_countdown(int left, int limit, int window, int oppHas, int oppOut, int oppTop, int oppStop);
void gn_end(void);
void gn_quit(void);
void gn_log(const char *s);
void gn_thread_stats(double *out);
]]
-- (THE LOAD NEVER COMPILED: a trace made of the first boards, garbage-free, leaves on every garbage panel once garbage lands, and on a
-- trace's exit LuaJIT drives the collector forward (lj_trace_exit, lj_gc_step) -- stopped or not, a step of it inside the frame: 9-14 ms
-- in the panels of the first frames with garbage. Run by the interpreter, the load leaves no trace to exit.)
local JIT_CTL = jit and jit.off and true
local boardChunk = assert(loadfile(DIR .. "/lua/board.lua"))
if JIT_CTL then jit.off(boardChunk, true) end
local B = boardChunk()
local NUL = B.NUL
-- (the instance in play -- open: its library, its io's head names, and the io's head and body)
local C, HI, NH, H, Bd

-- the profile, as words.js wrote it
local function configure()
  local file = os.getenv("GC_GAMBIT_WORDS") or (DIR .. "/gambit.words")
  local f = assert(io.open(file), "GambitNative: no " .. file .. " (words.js writes it)")
  local setup, profile, rules, switch, share
  -- (GC_GAMBIT_THEN: the mode a named opener gives way to at the top-out, `_` for a space -- answer.c gb_then)
  local thenName, thenRule = os.getenv("GC_GAMBIT_THEN"), -1
  if thenName == "" then thenName = nil end
  if thenName then thenName = thenName:gsub("_", " ") end
  for line in f:lines() do
    local kind, rest = line:match("^(%S+) (.*)$")
    if kind == "setup" or kind == "profile" or kind == "rules" or kind == "switch" or kind == "share" then
      local v = {}
      for n in rest:gmatch("%S+") do v[#v + 1] = tonumber(n) end
      if kind == "setup" then setup = v elseif kind == "profile" then profile = v elseif kind == "switch" then switch = v elseif kind == "share" then share = v else rules = v end
    elseif kind == "name" then
      local i, name = rest:match("^(%d+) (.*)$")
      C.gn_rule_name(tonumber(i), name)
      if name == thenName then thenRule = tonumber(i) end
    end
  end
  f:close()
  assert(setup and profile and rules, "GambitNative: " .. file .. " is not a whole profile")
  C.gn_setup(setup[1], setup[2], setup[3], setup[4], setup[5], setup[6], setup[7], os.getenv("GC_GAMBIT_LOG") or "")
  local io, n, len = C.gn_io(), rules[1], rules[2]
  for i = 1, len do io[i - 1] = rules[2 + i] end
  assert(C.gn_rules(n) == n, "GambitNative: the rules were refused")
  C.gn_profile(profile[1], profile[2], profile[3], profile[4], profile[5], profile[6], profile[7], profile[8])
  C.gn_switch(switch and switch[1] or 0, switch and switch[2] or 0)
  C.gn_share(share and share[1] or 0, share and share[2] or 0)
  assert(not thenName or thenRule >= 0, "GambitNative: GC_GAMBIT_THEN names no rule: " .. tostring(thenName))
  C.gn_then(thenRule)
end

-- A FRESH GAMBIT FOR EVERY MATCH (the owner: every game a fresh game, whoever it is against): a copy of the library loaded as an instance
-- of its own -- every one of its statics new, its threads its own -- and set up as the first match's was. The last match's instance is
-- quit before (native.c gn_quit: its threads joined, its memory freed) and let go. The process, its connection and its lobby stay.
local function open()
  local f = assert(io.open(DIR .. "/libgambit.so", "rb"), "GambitNative: no " .. DIR .. "/libgambit.so")
  local bytes = f:read("*a"); f:close()
  local path = os.tmpname()
  local o = assert(io.open(path, "wb")); o:write(bytes); o:close()
  C = ffi.load(path)
  os.remove(path)   -- (loaded: the copy is mapped, its file no longer needed)
  HI, NH = {}, C.nb_nhead()
  for i = 0, NH - 1 do HI[ffi.string(C.nb_head_name(i))] = i end
  H, Bd = C.nb_io_head(), C.nb_io_body()
  configure()
end
open()
local played = false   -- (the instance open has had a match)

local GambitNative = {}
GambitNative.__index = GambitNative

function GambitNative.new(opts)
  opts = opts or {}
  local self = setmetatable({}, GambitNative)
  self.thinking = opts.thinkBudget or ThinkBudget.standard()
  self.ownThinking = opts.thinkBudget == nil
  self.inputs = opts.inputBudget or InputBudget.standard()
  self.ownInputs = opts.inputBudget == nil
  self.dropped, self.frames, self.ages, self.pv = 0, 0, {}, {}
  self.ts0, self.ts1 = ffi.new("double[5]"), ffi.new("double[5]")
  return self
end

-- (the stack loaded once before play, so the first frame does not pay for the first load: the library's functions bound, the tables made)
function GambitNative:startMatch(stack, match)
  self.match, self.stack, self.frames = match, stack, 0
  -- (a match's clock starts again at 0: budgets of its own, or the last match's presses, frames ahead of this one's clock, never leave
  -- the window)
  if self.ownThinking then self.thinking = ThinkBudget.standard() end
  if self.ownInputs then self.inputs = InputBudget.standard() end
  self.dropped, self.ages, self.pv, self.slowLogged = 0, {}, {}, nil
  -- ONE INSTANCE FOR THE WHOLE RUN: gn_match (native.c) begins a match with nothing of the last carried on. A fresh instance per
  -- match (gn_quit, then open) hung the bot on its second match (gn_quit's thread join), and leaving the last one running instead
  -- used up the runner's memory (about 6 GB an instance) and killed the bot mid-game. So: no quit, no reload.
  played = true
  C.gn_match()
  -- (an engine without GarbageDelivery -- upstream's -- lands a transit due now before the frame runs: front.c receiverTimed)
  C.gn_receiver_timed((pcall(require, "common.engine.GarbageDelivery")) and 0 or 1)
  if stack and stack.panels then pcall(self.load, self, stack) end
end

-- The stack into the engine's io as the player sees it. The queue keeps the 192 to drop soonest (the search's boards hold 256, and 64
-- arriving).
local KEEP_QUEUED = 192
-- (the countdown frames left once its cursor has come to rest: Stack.runCountdown moves it for its first 40)
local COUNTDOWN_ASK = 135
-- (the one writer of a head field, into the io's head the instance made -- open: so a frame's load makes nothing)
local function put(k, v)
  local i = HI[k]
  if i and v ~= nil then H[i] = v == true and 1 or v == false and 0 or v end
end
if JIT_CTL then jit.off(put) end
function GambitNative:load(a)
  if a.do_countdown ~= nil then a.in_countdown = a.do_countdown and true or false end
  local pv = self.pv
  local l0 = ThinkBudget.now()
  for i = 0, NH - 1 do H[i] = 0 / 0 end
  B.head(a, put)
  local l1 = ThinkBudget.now()
  local inc, stall, landed = B.staged(a), B.stall(a), B.landed(a)
  local from = math.max(1, #inc - KEEP_QUEUED + 1)
  self.nrows, self.nqueued = #a.panels + 1, #inc
  put("nrows", #a.panels + 1); put("ninc", #inc - from + 1); put("nstall", #stall); put("nlanded", #landed); put("err", 0)
  put("unseenRows", 0); put("unseenBreaks", 0); put("nextInput", 0); put("pressSwap", 0); put("swapDeniedThisFrame", 0)
  local l2 = ThinkBudget.now()
  local x, flash = 0, a.levelData.frameConstants.FLASH
  for r = 0, #a.panels do
    for c = 1, a.width do
      B.panel(a.panels[r][c], pv, a.width, flash)
      for i = 1, B.NF do Bd[x] = pv[i]; x = x + 1 end
    end
  end
  local l3 = ThinkBudget.now()
  for j = from, #inc do x = B.putIncoming(inc[j], Bd, x) end
  for i = 1, #stall do x = B.putStall(stall[i], Bd, x) end
  for i = 1, #landed do Bd[x] = landed[i]; x = x + 1 end
  local drop = B.drop(a)
  for i = 1, #drop do Bd[x] = drop[i]; x = x + 1 end
  -- (where a load's time went, by part: the head, the queues read, the panels, the queues written -- a slow frame's log)
  self.loadParts = self.loadParts or {}
  local P = self.loadParts
  P[1], P[2], P[3], P[4] = l1 - l0, l2 - l1, l3 - l2, ThinkBudget.now() - l3
end
if JIT_CTL then jit.off(GambitNative.load, true) end

-- The garbage each source has sent and not yet delivered, as its telegraph shows it: whether its queue is held back (an attack engine's),
-- its transit by the stopWatch it lands on, then its staged that ship first (the end of the list), SOURCE_PIECES in all. Colours are not
-- in it.
local SOURCE_PIECES = 160
local function b01(v) return v and 1 or 0 end
local EMPTY = {}
local function piece(T, x, g)
  T[x], T[x + 1], T[x + 2], T[x + 3] = g.width, g.height, b01(g.isChain), b01(g.isMetal)
  T[x + 4] = g.frameEarned == nil and NUL or g.frameEarned
  T[x + 5] = g.finalized == nil and NUL or b01(g.finalized)
  return x + 6
end
-- A SOURCE WHOSE GARBAGE COMES OVER THE WIRE: the engine's own routing (common/engine/GarbageDelivery.lua looseSyncActive) -- loose
-- sync on and connected, the source not this client's: the server's relayed garbage is what lands, and the copy of the source played
-- here never delivers its own (its outgoing queue is never popped here). Anywhere else -- lockstep, Training, a local match -- the
-- source is played here exactly and delivers here, so its outgoing garbage is the garbage on its way and its board the opponent's own.
-- (THE WIRED SOURCE'S FORECAST: the copy is played from the opponent's relayed keys and the garbage this stack sends it (bot/BotClient),
-- so its telegraph is the opponent's: what it stages, and each transit not yet finished on the copy's own stopWatch. A finished one is
-- the server's to deliver -- it is in this stack's own queue once it comes, and never popped from the copy's, so it is left out.)
local function wired(src)
  return LOOSE_SYNC_GARBAGE and GAME and GAME.netClient and GAME.netClient.isConnected and GAME.netClient:isConnected()
    and not src.is_local and true or false
end
-- (a wired source's garbage delivered is read off this stack's own queue, what the server sent: board.lua loads it)
-- (A SOURCE PLAYED HERE BEHIND THIS STACK: an opponent's stack copied from its relayed keys runs as far as its keys have come, so it
-- can be frames behind this one -- its transits are timed on its own stopWatch, which the frame loop reads them against (front.c
-- arrivalsOf), so its stopWatch is given as it will be once it has caught up: the frames it is behind added)
-- (THE RECEIVER'S OWN TIME, upstream: upstream Panel Attack delivers a transit on the frame the RECEIVING stack's stopWatch reaches its
-- time -- Match:pushGarbageTo, the receiver rolled back when it has passed it -- where this fork's GarbageDelivery delivers it once the
-- sender's does. So on an upstream engine (no GarbageDelivery) the transits are read against this stack's own stopWatch, however far
-- the sender's copy here lags)
local SENDER_TIMED = (pcall(require, "common.engine.GarbageDelivery"))
local function caughtUp(src, me)
  if not SENDER_TIMED and me and me.stopWatch then return me.stopWatch end
  local lag = me and me.clock and src.clock and me.clock - src.clock or 0
  return src.stopWatch + (lag > 0 and lag or 0)
end
-- (GC_GAMBIT_BLIND: training played as the live server plays it -- every source as if wired, its garbage known only once it is in
-- this stack's own queue, as loose sync delivers it)
local BLIND = os.getenv("GC_GAMBIT_BLIND") == "1"
-- (THE WIRED SOURCE'S OWN TELEGRAPH: the opponent's client ships its outgoing garbage with every board it shows (DisplayEventCapture og,
-- BotClient's view.og) -- the blocks a player sees at the top -- and that is the opponent's own, where the copy played here from its
-- relayed keys runs behind it and can come apart from it. Each piece is told on the opponent's stopWatch (frameEarned); a board's
-- frame, and the frame this stack saw it on, carry that onto this stack's (the two stacks' countdowns taken as one length). A piece
-- still staged ships as the copy's would; one gone from the telegraph since is on its way: due LAND frames after the last board that
-- still showed it staged, and forgotten once that frame is past.)
local STAGING, LAND = 45 + 45 + 1, 60
local function viewTelegraph(self, T, x, view, me)
  local cd = (me.clock or 0) - (me.stopWatch or 0)
  local snapSW = view.clock - cd
  local nowSW = snapSW + (me.stopWatch - view.seenSW)
  local mem = self.ogMem or {}; self.ogMem = mem
  local seen = {}
  for _, g in ipairs(view.og) do
    -- (a chain grows, its frameEarned moving to its last link: it is known by its first)
    local first = nil
    if g.isChain then for f in pairs(g.links or EMPTY) do f = tonumber(f); if f and (not first or f < first) then first = f end end end
    local k = g.isChain and ("c" .. tostring(first or g.frameEarned)) or (tostring(g.frameEarned) .. ":" .. tostring(g.rowEarned) .. ":" .. tostring(g.colEarned))
    seen[k] = true
    mem[k] = { g = g, last = snapSW }
  end
  T[x], T[x + 1] = nowSW, 0; x = x + 2
  local at, nt, sent = x, 0, 0
  x = x + 1
  for k, e in pairs(mem) do
    if not seen[k] then
      local t = math.max((e.g.frameEarned or e.last) + STAGING, e.last) + LAND
      if t < nowSW - 2 or sent >= SOURCE_PIECES then mem[k] = nil
      else
        T[x], T[x + 1] = t, 1; x = x + 2
        x = piece(T, x, { width = e.g.width, height = e.g.height, isChain = e.g.isChain, isMetal = e.g.isMetal, frameEarned = e.g.frameEarned, finalized = true })
        nt, sent = nt + 1, sent + 1
      end
    end
  end
  T[at] = nt
  -- (still staged, the last to ship at the end, as the engine's staged list: the soonest earned last)
  local staged = {}
  for _, g in ipairs(view.og) do staged[#staged + 1] = g end
  table.sort(staged, function(a, b) return (a.frameEarned or 0) > (b.frameEarned or 0) end)
  local keep = math.max(0, math.min(#staged, SOURCE_PIECES - sent))
  T[x] = keep; x = x + 1
  for i = #staged - keep + 1, #staged do local g = staged[i]
    x = piece(T, x, { width = g.width, height = g.height, isChain = g.isChain, isMetal = g.isMetal, frameEarned = g.frameEarned, finalized = not g.isChain or nil }) end
  return x
end
function GambitNative:telegraph(sources, me, view)
  local T, x = C.gn_tele(), 1
  local n = 0
  for _, src in ipairs(sources or EMPTY) do
    local q = src.outgoingGarbage
    local w = wired(src)
    -- (THE FORECAST'S SOURCE, logged: what the opponent's board shipped of its telegraph, and the times read off it -- the first 60
    -- frames a game it holds a piece, and every 600th frame)
    if w then
      if not self.teleClock or (me.clock or 0) < self.teleClock then self.teleLogged = 0 end
      self.teleClock = me.clock or 0
      local nog = view and view.og and #view.og or -1
      if me.clock and ((nog > 0 and self.teleLogged < 60) or me.clock % 600 == 0) then
        self.teleLogged = self.teleLogged + (nog > 0 and 1 or 0)
        local first = view and view.og and view.og[1]
        C.gn_log(string.format("TELE clock %d sw %d: view %s og %d seenSW %s snapClock %s seen %s; first %s",
          me.clock, me.stopWatch or -1, view and "yes" or "no", nog, tostring(view and view.seenSW), tostring(view and view.clock),
          tostring(view and view.seen), first and string.format("%dx%d chain %s earned %s", first.width or -1, first.height or -1,
          tostring(first.isChain), tostring(first.frameEarned)) or "-"))
      end
    end
    if w and view and view.og and view.seenSW and view.clock and me.stopWatch and not BLIND then
      n = n + 1
      x = viewTelegraph(self, T, x, view, me)
    elseif q and src.stopWatch ~= nil and not BLIND then
      n = n + 1
      T[x], T[x + 1] = caughtUp(src, me), b01(q.illegalStuffIsAllowed); x = x + 2
      -- (every transit not yet delivered: one whose time has come waits while the stack has CAPPED_AT queued, GarbageDelivery; its count
      -- written once they are)
      local sent, nt, at = 0, 0, x
      x = x + 1
      if q.transitTimers then
        for k = q.transitTimers.first, q.transitTimers.last do
          local t = q.transitTimers[k]
          if t and sent < SOURCE_PIECES and (not w or t > src.stopWatch) then
            local list = q.garbageInTransit[t] or EMPTY
            T[x], T[x + 1] = t, #list; x = x + 2
            for i = 1, #list do x = piece(T, x, list[i]) end
            nt, sent = nt + 1, sent + #list
          end
        end
      end
      T[at] = nt
      local staged = q.stagedGarbage or EMPTY
      local keep = math.max(0, math.min(#staged, SOURCE_PIECES - sent))
      T[x] = keep; x = x + 1
      for i = #staged - keep + 1, #staged do x = piece(T, x, staged[i]) end
    end
  end
  T[0] = n
end

-- The stack this one fights, as the rules' `when` and `by` read it (gambit-rules.json enemy.*): whether there is one (an attack engine,
-- Training's, is no stack: none), whether it is topped out as the engine has it (Stack:isToppedOut: a panel, or garbage landed, in its
-- top row -- what drains its health once its stop runs out; garbage queued or still falling is not on its board) -- the highest row it
-- has a panel in, and the frames it is held up by. Read
-- off the opponent's own board as its client shipped it (view: BotClient's oppView, from the snapshots it paints from) when one came
-- within VIEW_FRESH frames -- its stop counted down since; else off the copy of its stack played here from its relayed keys: its stop
-- and pre-stop, or its shake when longer, as the judge reads a board's (judge.c dropAt).
-- An opponent whose garbage comes over the wire (wired) is read off its shipped board only, however old the last one -- the copy played
-- here is no source of its board -- and before the first, the board a match begins with: not topped out, low, no stop. One played here
-- exactly is read off its own stack. (A panel counts as the engine's Panel:dangerous counts it: garbage still falling is not the
-- stack's height, and does not top it out.)
local VIEW_FRESH = 90   -- frames a shipped board of the opponent is read as its board
local FIGHT = os.getenv("GC_GAMBIT_FIGHT") == "1"
local FOUGHT = false
local function counts(p) if not p then return false end if p.isGarbage then return p.state ~= "falling" end return (p.color or 0) ~= 0 end
local function opponentOf(sources, view, clock)
  local anyWired = false
  for _, src in ipairs(sources or EMPTY) do if src.panels and wired(src) then anyWired = true end end
  -- (a board shipped in this game only: the game's clock starts again at its countdown, and the last game's last board -- the enemy
  -- topped out, as a game ends -- is not this one's)
  -- (any opponent seen, by any of the three routes, makes this host a fighter for the session: FOUGHT)
  if view and clock and view.seen and view.seen <= clock and (anyWired or clock - view.seen <= VIEW_FRESH) then
    FOUGHT = true
    return 1, view.out and 1 or 0, view.out and 12 or (view.top4 or view.top or 0), math.max(0, (view.stop or 0) - (clock - view.seen))
  end
  if anyWired then FOUGHT = true return 1, 0, 0, 0 end
  local has, out, top, stop = 0, 0, 0, 0
  for _, src in ipairs(sources or EMPTY) do
    -- (a stack whose game has ended is the last game's: in a fight the next one's opponent is coming, low and not topped out)
    if type(src.game_ended) == "function" and src:game_ended() then
      if FIGHT or FOUGHT then return 1, 0, 0, 0 end
      return 0, 0, 0, 0
    end
    if type(src.isToppedOut) == "function" and src.panels then
      has = 1
      stop = math.max(stop, (src.stop_time or 0) + (src.pre_stop_time or 0), src.shake_time or 0)
      if src:isToppedOut() then out = 1 end
      -- (THE BOARD'S HEIGHT, AS STRONG PLAYERS READ IT: the row four of its six columns reach -- most of the board, not its one tall
      -- column; topped out is the top. plans/gambit-goal.md, Tanycanayt's finishes. A column's height is the cells it holds, as if the
      -- board had settled: a slab resting on one tall column over empty ones is not the others' height)
      local hs = {}
      for col = 1, src.width or 6 do
        local h = 0
        for row = 1, src.height or 12 do if counts(src.panels[row] and src.panels[row][col]) then h = h + 1 end end
        hs[#hs + 1] = h
      end
      table.sort(hs, function(a, b) return a > b end)
      local most = hs[4] or hs[#hs] or 0
      if src:isToppedOut() then most = src.height or 12 end
      if most > top then top = most end
    end
  end
  -- (GC_GAMBIT_FIGHT: training played as a fight -- the attack engine stands in for a stack that is there, low, not topped, held up by
  -- nothing, from the countdown on, so the opening is found the way a fight's is: the opener's table)
  -- (and a host that has fought an opponent this session is in a fight from each game's countdown on, before the new game's stack is
  -- wired: a match begins with the opponent not topped out, low, held up by nothing)
  if has == 1 then FOUGHT = true end
  if has == 0 and (FIGHT or FOUGHT) then return 1, 0, 0, 0, true end
  return has, out, top, stop
end

-- THE VIRTUAL ENEMY (GC_GAMBIT_ENEMY=virtual, training only -- the stand-in above made a stack that moves as players' do, so a rule that
-- reads the enemy's room is played offline): its own stack drifts about VE_BASE rows (VE_LO to VE_HI), a row up or down every VE_STEP
-- frames with chance VE_MOVE, pulled back toward VE_BASE; our garbage lands on it when it leaves our queue, a row a piece of each row
-- it is; it digs a row out every VE_DIG frames while any is on it; topped at 12. Measured on Tanycanayt's own board over 46 live games
-- (32,403 boards, one every 32 frames): its stack less its garbage rows median 7, sd 1.6, 3 to 11, moving 0.21 rows a sample; its
-- garbage dug out 0.21 rows a second net while any was on it. Topped with no shake left, it dies (VENEMY in the log) and a new one
-- begins. Seeded from PA_SEED: a run repeats.
local VIRTUAL = os.getenv("GC_GAMBIT_ENEMY") == "virtual"
local VE_BASE, VE_LO, VE_HI, VE_STEP, VE_MOVE, VE_DIG, VE_FLIGHT = 7, 3, 11, 32, 0.21, 285, 151
local VE = { clock = -1 }
local function veRand()   -- (a linear congruential stream, the same for a seed in any LuaJIT)
  VE.r = (VE.r * 1103515245 + 12345) % 2147483648
  return VE.r / 2147483648
end
local function virtualEnemy(me, clock)
  if clock < VE.clock or not VE.r then
    VE = { clock = clock, base = VE_BASE, garbage = 0, dig = 0, seen = {}, done = {}, r = (tonumber(os.getenv("PA_SEED") or "1") or 1) % 2147483648 }
  end
  local q, cur = me and me.outgoingGarbage, {}
  if q then
    for _, g in ipairs(q.stagedGarbage or EMPTY) do cur[g] = g.height or 1 end
    if q.transitTimers then
      for k = q.transitTimers.first, q.transitTimers.last do
        local t = q.transitTimers[k]
        for _, g in ipairs(t and q.garbageInTransit[t] or EMPTY) do cur[g] = g.height or 1 end
      end
    end
  end
  -- (A LANDING'S SHAKE, as the engine's onGarbageLand has it: by the piece's cells, 18 frames up to 4, 24 for 5, 42 to 11, 66 to 23, 76
  -- from 24; a landing while it shakes renews the largest shake since it was last 0; garbage landing above its top row shakes nothing)
  local function land(g, h)
    local before = VE.base + VE.garbage
    VE.garbage = VE.garbage + h; VE.landed = clock
    if before < 12 then
      local cells = (g.width or 6) * h
      local sh = cells <= 4 and 18 or cells == 5 and 24 or cells <= 11 and 42 or cells <= 23 and 66 or 76
      if (VE.shake or 0) <= 0 then VE.shakeMax = 0 end
      VE.shakeMax = math.max(VE.shakeMax or 0, sh); VE.shake = VE.shakeMax
    end
  end
  -- (a piece lands VE_FLIGHT frames after it is first seen on our queue, or as it leaves it -- training has no stack to take it, so it
  -- may never leave; until then it is a row on its way)
  local onWay, seen = 0, {}
  for g, h in pairs(cur) do
    local first = VE.seen[g] and VE.seen[g][1] or clock
    seen[g] = { first, h }
    if not VE.done[g] then
      if clock - first >= VE_FLIGHT then land(g, h); VE.done[g] = true else onWay = onWay + h end
    end
  end
  for g, e in pairs(VE.seen) do if not cur[g] and not VE.done[g] then land(g, e[2]) end end
  VE.seen = seen
  while VE.clock < clock do
    VE.clock = VE.clock + 1
    if VE.clock % VE_STEP == 0 and veRand() < VE_MOVE then
      local up = 0.5 + 0.1 * (VE_BASE - VE.base)
      VE.base = math.max(VE_LO, math.min(VE_HI, VE.base + (veRand() < up and 1 or -1)))
    end
    if (VE.shake or 0) > 0 then VE.shake = VE.shake - 1 end
    if VE.garbage > 0 then VE.dig = VE.dig + 1; if VE.dig >= VE_DIG then VE.dig = 0; VE.garbage = VE.garbage - 1 end else VE.dig = 0 end
  end
  -- (DEAD as a stack is: topped out with no shake left -- logged with the frames
  -- from its first top-out, and the next one begins: low, no garbage, as a new round's)
  local h = VE.base + VE.garbage
  if h >= 12 then
    VE.topped = VE.topped or clock
    if (VE.shake or 0) <= 0 then
      C.gn_log(string.format("VENEMY clock %d: died, %d frames from its top-out, %d kills", clock, clock - VE.topped, (VE.kills or 0) + 1))
      VE.kills = (VE.kills or 0) + 1; VE.base = VE_LO + math.floor(veRand() * (VE_BASE - VE_LO + 1)); VE.garbage = 0; VE.dig = 0; VE.topped = nil; VE.shake = 0
      h = VE.base
    end
  else VE.topped = nil end
  return math.min(12, h), h >= 12 and 1 or 0, onWay
end

-- (THE ENEMY AS OUR GARBAGE WILL LEAVE IT: the rows this stack has sent it that have not landed -- staged on the telegraph, or on their
-- way -- each piece its height, added to its tallest column: the rules' enemy.height is the board it will have, so a big chain on its
-- way brings on the mode that finishes it, and the next attack is sized to the room left)
local function rowsOnItsWay(me)
  local q, n = me and me.outgoingGarbage, 0
  if not q then return 0 end
  for _, g in ipairs(q.stagedGarbage or EMPTY) do n = n + (g.height or 1) end
  if q.transitTimers then
    for k = q.transitTimers.first, q.transitTimers.last do
      local t = q.transitTimers[k]
      for _, g in ipairs(t and q.garbageInTransit[t] or EMPTY) do n = n + (g.height or 1) end
    end
  end
  return n
end
function GambitNative:think(stack, sources, view)
  local idle = KeyDataEncoding.base64encode[1]
  -- (the countdown: once the cursor has come to rest, the opening asked of the board as play will begin with it -- gn_countdown)
  if counting(stack) then
    local left = stack.countdown_timer
    if left and left > 1 and left <= COUNTDOWN_ASK then
      self:load(stack)
      local has, out, top, stop = opponentOf(sources, view, stack.clock)
      C.gn_countdown(left, self.inputs.limit or 0, self.inputs.window or 0, has, out, top, stop)
    end
    return idle
  end
  if not stack.stopWatchIsRunning or stack:game_ended() then return idle end
  -- (the game's score, each time it changes: time attack is measured by it -- gambit_summary.js)
  if stack.score and stack.score ~= self.lastScore then
    self.lastScore = stack.score
    C.gn_log(string.format("SCORE clock %d score %d chain %d", stack.clock or 0, stack.score, stack.chain_counter or 0))
  end
  local t0 = ThinkBudget.now()
  self:load(stack)
  local t1 = ThinkBudget.now()
  self:telegraph(sources, stack, view)
  local ages, A = self.inputs:ages(stack.clock, self.ages), C.gn_ages()
  for i = 1, math.min(#ages, 512) do A[i - 1] = ages[i] end
  local has, out, top, stop, stand = opponentOf(sources, view, stack.clock)
  local onWay
  if stand and VIRTUAL then top, out, onWay = virtualEnemy(stack, stack.clock) end
  -- (the enemy as our garbage will leave it: most of its board, and every row we have sent it that has not landed -- a combo lands on
  -- top of them, so finish them is the board a combo's row tops out: the owner, a combo only where it can kill)
  if has == 1 then top = math.min(12, top + (onWay or rowsOnItsWay(stack))) end
  local t2 = ThinkBudget.now()
  local bits = C.gn_frame(self.inputs.limit, self.inputs.window, math.min(#ages, 512), has, out, top, stop)
  self.stepLoad, self.stepTele, self.stepFrame = t1 - t0, t2 - t1, ThinkBudget.now() - t2
  if bits < 0 then error("GambitNative: the engine refused the board at clock " .. tostring(stack.clock)) end
  -- (GC_STOP_AFTER_HANDOVER frames: the game ends alive that many frames after the opener's handover -- either stack topped out first,
  -- as answer.c ends the opener -- and the seconds after it measured, nothing past them; the training loop reads GC_TRAINING_STOP_AT)
  if STOP_AFTER and not self.stopSet and (out == 1 or (stack.isToppedOut and stack:isToppedOut())) then
    self.stopSet = true; rawset(_G, "GC_TRAINING_STOP_AT", stack.clock + STOP_AFTER)
  end
  self.frames = self.frames + 1
  return KeyDataEncoding.base64encode[bits + 1] or idle
end

-- The key, or idle when the allowance of keys cannot pay for it (the game does not press a key past it).
local KEYBITS = { 2, 3, 4, 5, 6 }
function GambitNative:press(key, clock)
  local keys, held, down = KeyDataEncoding.base64decode[key], self.inputs.held, 0
  for _, bit in ipairs(KEYBITS) do
    if keys and keys[bit] and not held[bit] then down = down + 1 end
  end
  if down > self.inputs:remaining(clock) then key = KeyDataEncoding.idle; self.dropped = self.dropped + 1 end
  self.inputs:press(key, clock)
  return key
end

-- The frame's work, charged to the thinking budget, its key pressed on the input budget -- the game's own.
-- (and no compiler at all while the frame is worked: a trace compiled anywhere in it -- the game's own code it calls included -- flips the
-- machine code's pages writable and back, and each flip waits for the process's memory map while Gambit's threads fault pages in: a
-- frame over the think budget on a millisecond of CPU. jit.off keeps the traces compiled; jit.on after the frame)
local JIT_OFF = jit and jit.off and jit.on and jit.status
function GambitNative:input(stack, sources, view)
  collectgarbage("stop")
  local jitWas = JIT_OFF and jit.status()
  if jitWas then jit.off() end
  C.gn_thread_stats(self.ts0)
  local began = ThinkBudget.now()
  local ok, key = pcall(self.think, self, stack, sources, view)
  if ok and self.ownInputs then key = self:press(key, stack.clock) end
  local took = ThinkBudget.now() - began
  if jitWas then jit.on() end
  collectgarbage("restart")
  if not ok then error(key, 0) end
  if self.ownThinking then self.thinking:charge(took) end
  -- a frame over the ceiling, and where its time went
  if took > self.thinking:snapshot().ceiling and self.stepLoad and (self.slowLogged or 0) < 50 then
    self.slowLogged = (self.slowLogged or 0) + 1
    -- (and the game thread's own account of it: its CPU time, the times it was taken off its core or gave it up, its page faults)
    local a, b, P = self.ts0, self.ts1, self.loadParts
    C.gn_thread_stats(b)
    C.gn_log(string.format("SLOWFRAME clock %d: %.1f ms (load %.1f, telegraph %.1f, frame loop %.1f) cpu %.1f ms, preempted %d, yielded %d, faults %d (major %d); %s",
      stack.clock, took * 1000, self.stepLoad * 1000, self.stepTele * 1000, self.stepFrame * 1000, b[0] - a[0], b[1] - a[1], b[2] - a[2], b[3] - a[3], b[4] - a[4],
      string.format("rows %d, queued %d; load head %.1f, queues %.1f, panels %.1f, queues written %.1f", self.nrows or 0, self.nqueued or 0,
        P and P[1] * 1000 or -1, P and P[2] * 1000 or -1, P and P[3] * 1000 or -1, P and P[4] * 1000 or -1)))
  end
  self.stepLoad = nil
  return key
end

---The frames whose thinking cost more than the ceiling, the worst frame (seconds), and the keys the allowance refused.
function GambitNative:budget()
  return self.thinking:overruns(), self.thinking:worst(), self.dropped
end

function GambitNative:endMatch() C.gn_end() end

-- NOTHING IN A FRAME IS COMPILED. The compiler records and compiles a loop the first time it runs hot, and a compile inside a frame
-- costs tens of milliseconds; this code is calls into C and table writes, which compiling does not speed up, so it runs interpreted, at
-- the same speed every frame.
if jit and jit.off then
  for _, t in ipairs({ GambitNative, B }) do
    for _, f in pairs(t) do if type(f) == "function" then jit.off(f, true) end end
  end
  jit.off(opponentOf, true); jit.off(put, true); jit.off(piece, true)
end

return GambitNative
