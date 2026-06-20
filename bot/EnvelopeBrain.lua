-- EnvelopeBrain — the chips-brain live decide. STATELESS: every frame it re-measures from the CURRENT cursor and
-- picks an immediate move. No stored plan -> a mid-travel rise can't drift the target (next frame just re-measures
-- from the new cursor snapshot). Search is cursor-outward (here, then left/up/down/right, then further). A move is
-- only ever a VERIFIED chip (or a setup swap that makes one appear); otherwise wait for material.
--   decide(state) -> { type="SWAP", pos={r,c} } | { type="WAIT" }
local BoardSim = require("bot.BoardSim")
local useChips = require("bot.useChips")

local EnvelopeBrain = {}
EnvelopeBrain.__index = EnvelopeBrain

function EnvelopeBrain.new(_opts)
  return setmetatable({}, EnvelopeBrain)
end

------------------------------------------------------------------ ENGINE VERIFY (the HARD RULE: never play unverified)
-- Rebuild a throwaway Match from the grid and play the route on the REAL engine -- engine truth, NO BoardSim. A flat
-- grid can't reconstruct garbage, so a garbage board returns false (no break chips yet).
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
    for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
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

------------------------------------------------------------------ CONSTRUCT one setup move toward a chip
-- No ready chip, so try one setup swap NEAR the cursor and ask "does a VERIFIED chip appear after it?" If so, that
-- setup move is the play -- after it lands the next frame recognizes the now-ready chip. The chip on the imagined
-- board is searched relative to where the cursor LANDS (the setup cell). Cached per board signature.
function EnvelopeBrain:construct(grid, rows, cursor, sig)
  if self._conSig == sig then return self._conResult or nil end
  self._conSig = sig; self._conResult = false
  local cr, cc = cursor[1], cursor[2]
  local maxD = 4
  local cands = {}
  for r = math.max(1, cr - maxD), math.min(rows, cr + maxD) do for c = 1, BoardSim.WIDTH - 1 do
    local dist = math.abs(r - cr) + math.abs(c - cc)
    local a, b = grid[r][c], grid[r][c + 1]
    if dist <= maxD and a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE and a ~= b and (a ~= 0 or b ~= 0) then
      cands[#cands + 1] = { r, c, dist }
    end
  end end
  table.sort(cands, function(x, y) return x[3] < y[3] end)   -- nearest first
  for _, cand in ipairs(cands) do
    local r, c = cand[1], cand[2]
    local g2 = BoardSim.simSwap(grid, rows, r, c)
    if g2 and useChips.useChips(g2, rows, { r, c }, { chipPriorities = { "COMBO_5", "COMBO_4" },
         searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" }, verify = self:chipVerify(g2, rows) }) then
      self._setupUsed = (self._setupUsed or 0) + 1
      self._conResult = { { r, c } }
      return self._conResult
    end
  end
  return nil
end

-- a settled 3+ same-color run = a match mid-clear. While one exists, WAIT: don't swap into it or undo a combo we
-- just made. The engine won't let us re-swap matched panels anyway -- this just stops us flailing at a clearing
-- combo, with no magic cooldown. (Brian's intuition: "you can't re-swap somewhere active.")
local function hasPendingMatch(grid, rows)
  for r = 1, rows do for c = 1, BoardSim.WIDTH do
    local v = grid[r] and grid[r][c]
    if v and v ~= 0 and v ~= BoardSim.GARBAGE then
      if grid[r][c + 1] == v and grid[r][c + 2] == v then return true end       -- horizontal 3-run
      if grid[r + 1] and grid[r + 2] and grid[r + 1][c] == v and grid[r + 2][c] == v then return true end  -- vertical
    end
  end end
  return false
end

------------------------------------------------------------------ DECIDE (stateless, re-measured every frame)
function EnvelopeBrain:decide(state)
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local top = math.min(rows, height + 1)
  local cursor = state.cursor or { top, 3 }
  local sig = 0
  for r = 1, top do for c = 1, BoardSim.WIDTH do sig = (sig * 31 + grid[r][c]) % 2147483647 end end

  -- a match is clearing -> WAIT (don't swap into it or undo the combo we just made). Replaces the old magic cooldown.
  if hasPendingMatch(grid, rows) then self._sig, self._move = nil, nil; return { type = "WAIT" } end

  -- COMMIT (the memory the old plan had): hold our move while the board is UNCHANGED -- travel to it -- and re-decide
  -- ONLY when it actually changes. A rise (which changes the signature) re-targets us fresh.
  local move
  if sig == self._sig and self._move then
    move = self._move
  else
    self._sig = sig
    local chip = useChips.useChips(grid, rows, cursor, {                  -- READY chip, cursor-outward
      chipPriorities = { "COMBO_5", "COMBO_4" }, searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" },
      verify = self:chipVerify(grid, rows),
    })
    if chip then
      self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1
      move = { type = "SWAP", pos = chip.swaps[1] }
    else
      local setup = self:construct(grid, rows, cursor, sig)             -- else CONSTRUCT one setup move toward a chip
      move = setup and { type = "SWAP", pos = setup[1] } or { type = "WAIT" }
    end
    self._move = move
  end

  return move
end

return EnvelopeBrain
