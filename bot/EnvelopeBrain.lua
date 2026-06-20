-- EnvelopeBrain — the chips-brain live decide. The board's situation picks a VERIFIED chip (useChips); if none fits,
-- raise new material. There is NO construction fallback: recognizing a ready combo is all this does for now — the
-- "construct-toward-a-verified-chip" layer is the next piece. (Old FSM / deepFit / planCache path deleted 2026-06-20.)
--   decide(state) -> { type="SWAP", pos={r,c} } | { type="RAISE" } | { type="WAIT" }
local BoardSim = require("bot.BoardSim")
local useChips = require("bot.useChips")

local EnvelopeBrain = {}
EnvelopeBrain.__index = EnvelopeBrain

function EnvelopeBrain.new(_opts)
  return setmetatable({ plan = nil, planIdx = 1, lastSig = nil, prevHeight = nil, planRowOffset = 0 }, EnvelopeBrain)
end

------------------------------------------------------------------ ENGINE VERIFY (the HARD RULE: never play unverified)
-- Rebuild a throwaway Match from the grid and play the route on the REAL engine -- engine truth, NO BoardSim. A flat
-- grid can't reconstruct garbage, so a garbage board returns false (no break chips yet); a faithful garbage verify
-- lands with the break vocabulary.
local KDE_swap = nil
local function gridToStack(grid, rows)
  local out = {}
  for r = rows, 1, -1 do for c = 1, BoardSim.WIDTH do
    local v = grid[r][c] or 0
    if v == BoardSim.GARBAGE then return nil end
    out[#out + 1] = tostring(v)
  end end
  return table.concat(out)
end
local function engineVerifyFull(stack, seq)
  local ok, result = pcall(function()
    local Match = require("common.engine.Match"); require("common.engine.checkMatches")
    local Puzzle = require("common.engine.Puzzle"); local LP = require("common.data.LevelPresets")
    if not KDE_swap then KDE_swap = require("common.data.KeyDataEncoding").swap end
    local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 99 })
    local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil)
    st:setMaxRunsPerFrame(1); m:start()
    local function pan() local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
    for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end -- settle
    local pb = pan()
    for _, mv in ipairs(seq) do
      st.cur_row, st.cur_col = mv[1], mv[2]; st:receiveConfirmedInput(KDE_swap); m:run()
      for k = 1, 80 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    end
    return pan() < pb
  end)
  if not ok then return false end
  return result
end
function EnvelopeBrain:chipVerify(grid, rows)
  return function(seq)
    if not seq or #seq == 0 then return false end
    local stack = gridToStack(grid, rows)
    if not stack then return false end
    return engineVerifyFull(stack, seq) == true
  end
end

------------------------------------------------------------------ CHIPS: the plan source
-- The engine verify is the cost; the board only changes when a move lands or rises, so cache the result by board
-- signature -> the verify runs ONCE per board state, not every frame.
function EnvelopeBrain:tryChips(grid, rows, cursor, sig)
  if self._chipSig == sig then return self._chipResult or nil end
  local chip = useChips.useChips(grid, rows, cursor, {
    chipPriorities = { "COMBO_5", "COMBO_4" },   -- each call site passes its own priorities (one site, for now)
    searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" }, maxDistance = 3,  -- from the cursor outward, kept CLOSE so
    verify = self:chipVerify(grid, rows),                                   -- the swap lands before the board drifts
  })
  self._chipSig = sig
  self._chipResult = chip and chip.swaps or false
  if chip then self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1 end
  return self._chipResult or nil
end

-- CONSTRUCT toward a chip (the "scan", chip-as-leaf): no ready chip, so try one setup swap and ask "does a VERIFIED
-- chip appear after it?" If so, that setup move IS the plan — after it lands, the next replan recognizes the now-ready
-- chip and fires it. The leaf test is a real verified chip (not a heuristic), so it can't chase phantoms. Cached per
-- board signature. (Depth 1 for now; deepen if usage is low.)
function EnvelopeBrain:construct(grid, rows, cursor, sig)
  if self._conSig == sig then return self._conResult or nil end
  self._conSig = sig; self._conResult = false
  local cr = (cursor and cursor[1]) or math.min(rows, BoardSim.maxHeight(grid, rows) + 1)
  local cc = (cursor and cursor[2]) or 3
  local maxD = 3
  -- candidate setup swaps NEAR the cursor (search outward, like the puzzle search), nearest first
  local cands = {}
  for r = math.max(1, cr - maxD), math.min(rows, cr + maxD) do for c = 1, BoardSim.WIDTH - 1 do
    local dist = math.abs(r - cr) + math.abs(c - cc)
    local a, b = grid[r][c], grid[r][c + 1]
    if dist <= maxD and a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
      cands[#cands + 1] = { r, c, dist }
    end
  end end
  table.sort(cands, function(x, y) return x[3] < y[3] end)
  for _, cand in ipairs(cands) do
    local r, c = cand[1], cand[2]
    local g2 = BoardSim.simSwap(grid, rows, r, c)
    -- after playing this setup, the cursor lands at (r,c) -> search the chip RELATIVE TO THERE (not the old cursor)
    if g2 and useChips.useChips(g2, rows, { r, c }, { chipPriorities = { "COMBO_5", "COMBO_4" },
         searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" }, maxDistance = maxD, verify = self:chipVerify(g2, rows) }) then
      self._setupUsed = (self._setupUsed or 0) + 1
      self._conResult = { { r, c } }                    -- this setup move makes a verified chip available
      return self._conResult
    end
  end
  return nil
end

------------------------------------------------------------------ DECIDE
function EnvelopeBrain:decide(state)
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local top = math.min(rows, height + 1)

  -- board signature: detect a LANDED move (board changed) vs a uniform rise (shift only -> offset the plan, don't replan)
  local sig = 0
  for r = 1, top do for c = 1, BoardSim.WIDTH do sig = (sig * 31 + grid[r][c]) % 2147483647 end end
  local rose = self.prevHeight and height > self.prevHeight
  if rose then self.planRowOffset = (self.planRowOffset or 0) + (height - self.prevHeight) end
  self.prevHeight = height
  if self.plan and self.lastSig and sig ~= self.lastSig and not rose then self.planIdx = self.planIdx + 1 end -- a move landed
  self.lastSig = sig

  -- CHIPS-ONLY: the plan is a verified chip near the cursor, or nothing.
  if (not self.plan) or self.planIdx > #self.plan then
    self.plan = self:tryChips(grid, rows, state.cursor, sig)        -- ready chip?
              or self:construct(grid, rows, state.cursor, sig)      -- else one setup move toward a verified chip
    self.planIdx = 1; self.planRowOffset = 0
  end
  local mv = self.plan and self.plan[self.planIdx]
  if mv then
    local r = mv[1] + (self.planRowOffset or 0)   -- hold the move each frame until it lands, with the rise offset
    if r >= 1 and r <= rows then return { type = "SWAP", pos = { r, mv[2] } } end
    self.planIdx = #self.plan + 1                 -- drifted out of range -> replan next frame
  end

  -- no chip available: raise NEW material (bounded so we don't raise into the ceiling), else idle.
  local raiseCeil = tonumber(os.getenv("PA_RAISECEIL")) or 0.6
  if height < rows * raiseCeil then return { type = "RAISE" } end
  return { type = "WAIT" }
end

return EnvelopeBrain
