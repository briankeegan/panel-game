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

------------------------------------------------------------------ ENGINE VERIFY (garbage-faithful, via rollback)
-- Run the candidate swaps on the LIVE stack itself -- save state, play the swaps, advance ONLY this stack
-- (stack:run, so a 2p opponent is never touched), check it cleared, then rollbackToFrame to restore. No text
-- rebuild -> faithful on GARBAGE boards. Needs the live stack (threaded through decide); without it, no verify.
local KDE_swap = nil
function EnvelopeBrain:chipVerify(stack)
  return function(seq)
    if not stack or not seq or #seq == 0 then return false end
    if not KDE_swap then KDE_swap = require("common.data.KeyDataEncoding").swap end
    local ok, fired = pcall(function()
      local function pan() local n = 0 for r = 1, stack.height do for c = 1, 6 do local p = stack.panels[r][c]; if p and not p.isGarbage and (p.color or 0) ~= 0 then n = n + 1 end end end return n end
      local clock0 = stack.clock
      stack:saveForRollback()
      local before = pan()
      for _, mv in ipairs(seq) do
        stack.cur_row, stack.cur_col = mv[1], mv[2]; stack:receiveConfirmedInput(KDE_swap)
        for k = 1, 40 do stack:run() if k >= 2 and not stack:hasActivePanels() and not stack:hasChainingPanels() then break end end
      end
      local cleared = before - pan()
      stack:rollbackToFrame(clock0)
      return cleared > 0
    end)
    return ok and fired or false
  end
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

-- STATE thresholds (knobs) by tallest-column height on the 12-row board:
--   <= RAISE_BELOW  -> RAISE  (too little material; push the stack up)
--   >= DANGER_ABOVE -> DANGER (near the top; must clear -- same combo chips for now, but never raise)
--   in between      -> OFFENSE (hunt/build combos at leisure)
local RAISE_BELOW = 4
local DANGER_ABOVE = 9

------------------------------------------------------------------ DECIDE (stateless, re-measured every frame)
function EnvelopeBrain:decide(state, stack)
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
    -- STATE by stack height. All states fire the same combo chips (DANGER uses the same chips for now); the state
    -- only changes the no-play FALLBACK: RAISE pushes up for material, OFFENSE/DANGER never raise.
    local st = (height >= DANGER_ABOVE and "DANGER") or (height <= RAISE_BELOW and "RAISE") or "OFFENSE"
    self._state = st

    local chip = useChips.useChips(grid, rows, cursor, {                  -- READY chip, cursor-outward
      chipPriorities = { "COMBO_5", "COMBO_4" }, searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" },
      verify = self:chipVerify(stack),
    })
    if chip then
      self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1
      move = { type = "SWAP", pos = chip.swaps[1] }
    elseif st == "RAISE" then
      move = { type = "RAISE" }              -- no chip + too low -> push stack up for material
    else
      move = { type = "WAIT" }               -- no chip -> wait. (Building is a future SETUP *chip*, not a panel-mover.)
    end
    self._move = move
  end

  return move
end

return EnvelopeBrain
