-- EnvelopeBrain — PROTOTYPE layer-3 live brain for template-THEN-fit BUILD (team consensus 2026-06-16).
-- v3: MPC CADENCE (B's fix for the per-frame slowness). The subdepth FIT search is ~300ms on a full board —
-- too slow PER FRAME, but BUILD isn't frame-reactive. So: re-plan a multi-swap PLAN occasionally, execute it
-- OPEN-LOOP over the next K frames, re-plan only every `replanEvery` frames / when the plan is exhausted / on
-- danger. The expensive search runs ~once per K frames; between, decide() is O(1) (pop the next planned move).
-- 300ms amortized over K=30 frames ≈ 10ms/frame. (B's plan-cache over data's top-10 envelopes removes even the
-- per-replan spike — that's the next layer, keyed by board signature; here we validate the cadence itself.)
--
-- Generator is still the local fitSearch placeholder; B's ORACLE_STACK plan-generator drops in behind
-- generatePlan() once it's solid. Same decide(state) -> {SWAP|RAISE|WAIT} seam as SearchBrain.

local BoardSim = require("bot.BoardSim")
local BuildEnvelope = require("bot.buildEnvelope")
local deepFit = require("bot.deepFit") -- B's deep BoardSim FIT generator (the lever past the 50% plateau)
local planCache = require("bot.planCache") -- envelope-keyed plan cache (offline-authored, live lookup)
local timingController = require("bot.timingController") -- B's WHEN-FSM: picks the MODE (RAISE/BUILD/FIRE/BREAK)
local liveRecognize = require("bot.liveRecognize") -- B's live fire-site scan: chainReady/breakReady/best in one band scan
local chips = require("bot.chips") -- B's chip cache: guaranteed 1-move fire/break (play) + 2-move setup (setupPlay)

local EnvelopeBrain = {}
EnvelopeBrain.__index = EnvelopeBrain

local DEFAULTS = {
  fireChain   = 2,   -- fire if a single swap triggers a chain of >= this depth
  fireClear   = 6,   -- ...or clears >= this many panels (a fat combo)
  dangerFrac  = 0.80, -- board height >= this fraction of rows => emergency: fire/clear to survive
  opportunism = tonumber(os.getenv("PA_OPP")) or 4, -- while building, fire anyway if a swap chains >= this
  fireFill    = tonumber(os.getenv("PA_FILL")) or 57, -- fire a ready chain once board fill reaches ~here (data:
                                                      -- humans ignite ~57-58 fill); fires EARLIER+LOWER than flat-12
  -- FIT search (ports B's subdepth+capped receding-horizon): build a chain over several swaps.
  subDepth    = tonumber(os.getenv("PA_SUBDEPTH")) or 2, -- swaps of lookahead per commit
  beam        = tonumber(os.getenv("PA_BEAM")) or 3,     -- children expanded per level
  nodeBudget  = 1500, -- hard cap on board sims per re-plan (frame-budget guard for the spike)
  replanEvery = tonumber(os.getenv("PA_REPLAN")) or 30,  -- MPC cadence K: re-plan every K frames, else open-loop
  surface     = tonumber(os.getenv("PA_SURFACE")) or 5,  -- region cap: only search the top N stack rows
  -- B's deepFit generator (deeper chains than the live fitSearch can reach; amortized over the cadence).
  deepDepth   = tonumber(os.getenv("PA_DEEP")) or 4,
  deepBeam    = tonumber(os.getenv("PA_DEEPBEAM")) or 4,
  deepBudget  = tonumber(os.getenv("PA_DEEPBUDGET")) or 2000,
  -- B's timing FSM gates the mode (Audit 7: offense is gated on the stop-time clock, not board shape). Off ->
  -- legacy fill/fire path. A/B both via survivalStress before locking the default. PA_TIMINGFSM=0 disables.
  useTimingFSM = (os.getenv("PA_TIMINGFSM") ~= "0"),
}

function EnvelopeBrain.new(opts)
  opts = opts or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  for k, v in pairs(opts) do if k ~= "difficulty" then cfg[k] = v end end
  return setmetatable({ cfg = cfg, plan = nil, planIdx = 1, sinceReplan = 0, lastSig = nil,
                        prevHeight = nil, planRowOffset = 0 }, EnvelopeBrain)
end

-- REGION-CAPPED candidate gen (B's "cap harder on full boards"): only swaps in the top `surface` rows of
-- the stack. Bounds the candidate count (and thus the simSwap count, the real cost ~1.8ms each) to a fixed
-- ~surface×5 regardless of board height — so decide() doesn't blow up as the envelope builds toward full.
-- The surface is where rearrangement matters in live play (lower panels are locked in under the rising stack).
local function swaps(grid, top, surface)
  local out = {}
  local lo = surface and math.max(1, top - surface + 1) or 1
  for r = lo, top do
    for c = 1, BoardSim.WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        out[#out + 1] = { r, c }
      end
    end
  end
  return out
end

-- the single swap that fires the BIGGEST clear (chain depth first, then panels). Returns pos,chain,clear.
local function bestFireSwap(grid, rows, top)
  local bestPos, bestChain, bestClear = nil, 0, 0
  for r = 1, top do
    for c = 1, BoardSim.WIDTH - 1 do
      local a, b = grid[r][c], grid[r][c + 1]
      if a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
        local _, chain, total = BoardSim.simSwap(grid, rows, r, c)
        if total > 0 and (chain > bestChain or (chain == bestChain and total > bestClear)) then
          bestPos, bestChain, bestClear = { r, c }, chain, total
        end
      end
    end
  end
  return bestPos, bestChain, bestClear
end

-- FIT SEARCH (ports B's unifiedSolve FIT loop): subdepth DFS that, while building toward the envelope, finds
-- the swap SEQUENCE that best RAISES chain-POTENTIAL (arranges a firing chain). The envelope CAPS branching
-- (expand the children that flatten toward the form — a smooth gradient, no valley to stall in); score leaves
-- by the latent chain (bestClear) they set up. Returns the full best SEQUENCE (the open-loop plan) so the
-- cadence driver can execute it over K frames before re-planning. A multi-swap sequence raises potential
-- where 1 swap can't (the valley-crossing the greedy 1-ply placeholder lacked).
local function fitSearch(grid, rows, envelope, top, cfg)
  local _, _, _, _, base = BoardSim.chainPotential(grid, rows, top)
  local bestSeq, bestPot, bestLeaf = {}, base or 0, grid
  local budget = cfg.nodeBudget
  local function envDist(g) return envelope and BuildEnvelope.distance(g, rows, envelope) or 0 end
  local function dfs(g, depth, path)
    if depth >= cfg.subDepth or budget <= 0 then return end
    local kids = {}
    for _, sw in ipairs(swaps(g, top, cfg.surface)) do
      if budget <= 0 then break end
      budget = budget - 1
      local ng = BoardSim.simSwap(g, rows, sw[1], sw[2])
      local _, _, _, _, pot = BoardSim.chainPotential(ng, rows, top)
      pot = pot or 0
      local npath = {}
      for i = 1, #path do npath[i] = path[i] end
      npath[#npath + 1] = sw
      if pot > bestPot then bestPot, bestSeq, bestLeaf = pot, npath, ng end
      kids[#kids + 1] = { g = ng, path = npath, d = envDist(ng) }
    end
    table.sort(kids, function(a, b) return a.d < b.d end) -- expand the flattest-toward-form first
    for i = 1, math.min(cfg.beam, #kids) do dfs(kids[i].g, depth + 1, kids[i].path) end
  end
  dfs(grid, 0, {})
  return bestSeq, bestLeaf -- the build line + the chain-READY board it produces (to append the trigger to)
end

-- CHIP VERIFY: the REAL-ENGINE check chips.setupPlay calls per candidate. setupPlay now falls through to B's
-- goalSetup (goal-directed construction), which returns routes of 2..6 swaps where the FIRE is on the LAST swap
-- and the intermediate swaps are non-clearing alignment moves. So we must apply the FULL sequence and check the
-- FINAL state — the old "first 2 swaps" check rejected every deep (3+) construction (the fire was never reached).
--
-- We verify on a THROWAWAY Match rebuilt from the current board snapshot — NOT the live online Match. It's a
-- separate disposable engine (Puzzle{moves=99} so the engine never caps the later swaps — moves=1 false-negatives
-- everything after swap 1), so there's zero desync risk to the real game. BoardSim mispredicts multi-swap slide
-- routes (~44% — gravity during slides), so the engine is the source of truth here.
--
-- GARBAGE CAVEAT: the throwaway Match is rebuilt from a flat color grid (gridToStack), which loses garbage block
-- extent/reveal — garbage cells can't be faithfully reconstructed, so on a board WITH garbage we fall back to the
-- full-sequence BoardSim verify (which rides the GARBAGE sentinel through gravity correctly). goalSetup only builds
-- play-color triples (never garbage-break setups), so engine-verify covers the routes it actually produces.
local KDE_swap = nil

-- full-sequence BoardSim verify: apply every swap, check the FINAL resolve cleared panels or broke garbage.
local function boardSimVerifyFull(grid, rows, seq)
  local g = grid
  for i = 1, #seq - 1 do
    g = BoardSim.simSwap(g, rows, seq[i][1], seq[i][2]) -- intermediate alignment swaps (don't clear)
    if not g then return false end
  end
  local last = seq[#seq]
  local _, _, tot, _, gbroke = BoardSim.simSwap(g, rows, last[1], last[2])
  return (tot or 0) > 0 or (gbroke or 0) > 0
end

-- reconstruct a Puzzle stack string from the grid (top row first, bottom-right last). Garbage -> empty (we only
-- reach this path on garbage-free boards). nil = the grid has garbage (caller falls back to BoardSim).
local function gridToStack(grid, rows)
  local out = {}
  for r = rows, 1, -1 do
    for c = 1, BoardSim.WIDTH do
      local v = grid[r][c] or 0
      if v == BoardSim.GARBAGE then return nil end
      out[#out + 1] = tostring(v)
    end
  end
  return table.concat(out)
end

-- build a throwaway Match from a stack string, settle it, and apply a full swap route. Returns true iff the play
-- panel count OR garbage count dropped. Lazy-requires the engine (pcall) so EnvelopeBrain stays loadable in pure
-- BoardSim contexts; on any failure returns nil so the caller falls back to BoardSim.
local function engineVerifyFull(stack, seq)
  local ok, result = pcall(function()
    local Match = require("common.engine.Match"); require("common.engine.checkMatches")
    local Puzzle = require("common.engine.Puzzle")
    local LP = require("common.data.LevelPresets")
    local BoardState = require("bot.BoardState")
    if not KDE_swap then KDE_swap = require("common.data.KeyDataEncoding").swap end
    local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 99 }) -- moves=99: don't cap the later swaps
    local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
    st:setMaxRunsPerFrame(1); m:start()
    local function pan() local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
    local function gar() local n = 0 for r = 1, st.height do for c = 1, 6 do if st.panels[r][c].isGarbage then n = n + 1 end end end return n end
    for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end -- settle
    local pb, gb = pan(), gar()
    for _, mv in ipairs(seq) do
      st.cur_row, st.cur_col = mv[1], mv[2]; st:receiveConfirmedInput(KDE_swap); m:run()
      for k = 1, 80 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    end
    return pan() < pb or gar() < gb
  end)
  if not ok then return nil end
  return result
end

function EnvelopeBrain:chipVerify(grid, rows)
  return function(seq)
    if not seq or #seq == 0 then return false end
    local stack = gridToStack(grid, rows)   -- nil on garbage boards
    if stack then
      local res = engineVerifyFull(stack, seq)
      if res ~= nil then return res end     -- engine truth (garbage-free path)
    end
    return boardSimVerifyFull(grid, rows, seq) -- garbage board / engine unavailable: full-sequence BoardSim
  end
end

-- GENERATE PLAN (the expensive step — runs ~once per `replanEvery` frames via the cadence). Decides BUILD vs
-- FIRE and returns a move sequence to execute open-loop. B's ORACLE_STACK plan-generator slots in here later.
function EnvelopeBrain:generatePlan(grid, rows, top, danger, mode)
  local cfg = self.cfg
  -- B's live fire-site scan (one band scan): the best trigger + chain/break readiness for the FSM. `best` favors
  -- chain, then GARBAGE-BREAK (opens stop-time = survival), then panels. Cached on self for the FSM (read each
  -- frame between re-plans; the cadence lag is benign — clock/danger move slowly).
  local scan = self._scan or liveRecognize.scanFireSites(grid, rows, { bandDepth = cfg.surface + 1 })
  self.chainReady = scan.chainReady
  self.breakReady = scan.breakReady
  local firePos = scan.best and { scan.best.r, scan.best.c } or nil
  local fireChain = scan.best and scan.best.chain or 0
  local fireClear = scan.best and scan.best.total or 0
  if danger and firePos then return { firePos } end                       -- emergency: fire to survive
  -- fill-based ignition (data: humans fire ~57-58 fill, not at topout). Count play panels; fire a ready chain
  -- once the board is built enough — keeps the board LOWER (survival) and matches the human ignition point.
  local fill = 0
  for r = 1, top do for c = 1, BoardSim.WIDTH do
    local v = grid[r][c]; if v ~= 0 and v ~= BoardSim.GARBAGE then fill = fill + 1 end
  end end
  local envelope = BuildEnvelope.recognize(grid, rows)
  local built = (envelope == nil)
  -- FIRE gate. With the timing FSM on (mode set), the WHEN is the FSM's call: FIRE/BREAK -> spend the window
  -- (fire any real trigger); BUILD -> hold fire (only grab a big opportunistic chain). With it off (mode nil),
  -- the legacy fill/built ignition decides.
  local fsmFire = (mode == "FIRE" or mode == "BREAK")
  local legacyFire = (mode == nil) and ((built and (fireChain >= cfg.fireChain or fireClear >= cfg.fireClear))
                                        or (fill >= cfg.fireFill and fireChain >= cfg.fireChain))
  if firePos and (fsmFire or fireChain >= cfg.opportunism or legacyFire) then
    return { firePos }                                                    -- spend the window / big chain / built
  end
  -- CHIPS (B's chip cache): guaranteed plays the band-scan above may have missed.
  -- 1) chips.play -> a verified IMMEDIATE 1-move fire/break. Take it whenever the FSM/legacy gate wants to fire
  --    (or always when in danger). chips.play already RECOGNIZE+VERIFYs, so a non-nil result is guaranteed to fire.
  if (fsmFire or legacyFire or danger) then
    local p = chips.play(grid, rows)
    if p then self._chipsUsed = (self._chipsUsed or 0) + 1; return { { p.r, p.c } } end
  end
  -- 2) chips.setupPlay -> a 2-MOVE setup (alignment now, fire next tick). This is the CONSTRUCTION step the live
  --    fitSearch couldn't reliably reach. Play seq[1] now; the fire becomes immediate next tick and the FIRE gate
  --    above takes it. Only attempt when we actually want offense (a fire mode / built / danger), so BUILD-mode
  --    holding-fire is preserved. `chipVerify` (built below) confirms the seq on a real simSwap before committing.
  if (fsmFire or legacyFire or danger) then
    local seq = chips.setupPlay(grid, rows, self:chipVerify(grid, rows))
    if seq then self._chipsUsed = (self._chipsUsed or 0) + 1; return seq end
  end
  -- CACHE FIRST: if the plan-cache has a plan for this envelope, recall it (zero live search). Miss -> fall
  -- through to a live deepFit search. Cache is authored offline, so this is the fast path once it's populated.
  local cached = planCache.match(grid, rows)
  local seq
  if cached then
    seq = {}
    for i = 1, #cached.plan do seq[i] = cached.plan[i] end -- copy (we mutate: append the trigger below)
  else
    -- BUILD then FIRE via B's DEEP FIT generator (the live fallback on a cache miss).
    seq = deepFit.search(grid, rows, envelope, top,
      { subDepth = cfg.deepDepth, beam = cfg.deepBeam, surface = cfg.surface, budget = cfg.deepBudget })
  end
  if #seq > 0 then
    local leaf = grid
    for _, sw in ipairs(seq) do leaf = BoardSim.simSwap(leaf, rows, sw[1], sw[2]) end
    local ltop = math.min(rows, BoardSim.maxHeight(leaf, rows) + 1)
    local fp, fchain, fclear = bestFireSwap(leaf, rows, ltop)  -- the trigger on the BUILT board
    if fp and (fchain >= cfg.fireChain or fclear >= cfg.fireClear) then
      seq[#seq + 1] = fp                                       -- build..., then FIRE
    end
    return seq
  end
  if firePos then return { firePos } end
  return {}
end

function EnvelopeBrain:decide(state)
  local cfg = self.cfg
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local top = math.min(rows, height + 1)
  local danger = height >= rows * cfg.dangerFrac

  -- SCAN FIRST (B fix 2026-06-18): the FSM must read THIS frame's readiness, not last frame's. Previously the scan
  -- ran inside generatePlan (AFTER the FSM), so frame 1 saw chainReady=nil → picked BUILD → the build swap DESTROYED
  -- the chain before it ever fired (traced: bot swapped at 1,3 ×17 instead of firing the chain at 3,3). Scan here,
  -- cache on self, and generatePlan reuses it.
  local scan = liveRecognize.scanFireSites(grid, rows, { bandDepth = cfg.surface + 1 })
  self.chainReady, self.breakReady, self.comboReady = scan.chainReady, scan.breakReady, scan.comboReady
  self._scan = scan

  -- TIMING FSM (B's timingController, Audit 7): pick the MODE from the stop-time clock + pressure; the FIT/cache
  -- decides the WHAT within the mode. RAISE lets us SKIP the deep search (offense can't land with no freeze).
  local mode = nil
  if cfg.useTimingFSM then
    local eta = math.huge
    for _, g in ipairs(state.incoming or {}) do if g.eta and g.eta < eta then eta = g.eta end end
    mode = timingController.decide({
      stopClock   = state.frozenFrames or state.stopTime or 0,
      danger      = height / rows,
      incomingEta = eta,
      chainReady  = self.chainReady,
      breakReady  = self.breakReady,
      comboReady  = self.comboReady,
    })
  end

  -- RISE-INVARIANT FRAME (B + Brian's fix): the board rises continuously — a uniform rise shifts every panel up
  -- one row but changes NOTHING relative. So track rows-risen since the plan was made and OFFSET the plan's rows
  -- at execution (the planned panel keeps its identity), instead of letting absolute (r,c) drift onto wrong
  -- cells. A rise increases maxColHeight by ~1; treat that as the rise signal. A rise is NOT a move-landing.
  local rose = self.prevHeight and height > self.prevHeight
  if rose then self.planRowOffset = self.planRowOffset + (height - self.prevHeight) end
  self.prevHeight = height

  -- ADVANCE the plan only when a move actually LANDED (board changed) AND it wasn't just a rise. One swap takes
  -- ~10 frames of cursor travel; advancing per-frame shreds the plan (the never-fire bug). `not rose` stops a
  -- rise (which also changes the signature) from being mis-read as a move-landing — my earlier bug.
  local sig = 0
  for r = 1, top do for c = 1, BoardSim.WIDTH do sig = (sig * 31 + grid[r][c]) % 2147483647 end end
  if self.plan and self.lastSig and sig ~= self.lastSig and not rose then
    self.planIdx = self.planIdx + 1
  end
  self.lastSig = sig

  -- RAISE means "no freeze to SPEND yet" — NOT "stop playing". Idling the cursor here lets the board rise into
  -- death (measured: FSM-on 11.3s vs off 15.3s, the whole regression). So RAISE keeps ARRANGING via the build
  -- path (same as BUILD); the only thing the clock gates is the FIRE timing (FIRE/BREAK spend the window). Treat
  -- RAISE as BUILD for plan generation.
  if mode == "RAISE" then mode = "BUILD" end

  -- MPC CADENCE: re-plan when there's no plan / it's exhausted / every K frames / on danger / when the FSM just
  -- switched to a fire mode and the current plan isn't already a fire.
  local wantFire = (mode == "FIRE" or mode == "BREAK")
  if (not self.plan) or self.planIdx > #self.plan or self.sinceReplan >= cfg.replanEvery or danger
     or (wantFire and not self._planIsFire) then
    self.plan = self:generatePlan(grid, rows, top, danger, mode)
    self._planIsFire = (wantFire and self.plan and #self.plan == 1) or nil
    self.planIdx = 1
    self.sinceReplan = 0
    self.planRowOffset = 0
  else
    self.sinceReplan = self.sinceReplan + 1
  end

  -- HOLD the current move (each frame until it lands), with the rise offset applied to its row.
  local mv = self.plan and self.plan[self.planIdx]
  if mv then
    local r = mv[1] + self.planRowOffset
    if r >= 1 and r <= rows then return { type = "SWAP", pos = { r, mv[2] } } end
    self.planIdx = #self.plan + 1 -- drifted out of range -> force a re-plan next frame
  end
  return { type = "WAIT" }
end

return EnvelopeBrain
