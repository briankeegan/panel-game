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

------------------------------------------------------------------ ENGINE VERIFY (garbage-faithful, via match rollback)
-- Play the candidate swaps on the LIVE board itself: save every stack, play the swaps via match:run (which processes
-- input + physics + garbage faithfully, unlike a bare stack:run), count this stack's panels_cleared delta (rise-robust),
-- then rollback EVERY stack to restore (so a 2p opponent isn't desynced). No text rebuild -> faithful on GARBAGE.
local KDE_swap = nil
function EnvelopeBrain:chipVerify(stack, match)
  return function(seq)
    if not stack or not match or not seq or #seq == 0 then return false end
    if not KDE_swap then KDE_swap = require("common.data.KeyDataEncoding").swap end
    local ok, fired = pcall(function()
      local clock0 = stack.clock
      for _, s in ipairs(match.stacks) do s:saveForRollback() end
      stack.stop_time = math.max(stack.stop_time or 0, 999)  -- FREEZE the auto-rise, or a rising row could fire the match instead of the swap
      local hit = false
      local token = {}  -- weak-keyed subscriber held in scope; "matched"/"garbageMatched" fire the INSTANT a clear is detected -- no pop-window guess
      stack:connectSignal("matched", token, function() hit = true end)
      stack:connectSignal("garbageMatched", token, function() hit = true end)
      for _, mv in ipairs(seq) do
        stack.cur_row, stack.cur_col = mv[1], mv[2]; stack:receiveConfirmedInput(KDE_swap); match:run()
        for k = 1, 20 do
          if hit then break end
          stack:receiveConfirmedInput("A"); match:run()
          if not stack:hasActivePanels() and not stack:hasChainingPanels() then break end
        end
      end
      stack:disconnectSignal("matched", token); stack:disconnectSignal("garbageMatched", token)
      for _, s in ipairs(match.stacks) do s:rollbackToFrame(clock0) end
      return hit
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

-- chip priorities = EVERY kind authored in bot/chipCache.lua, so this auto-includes new families on a cache update.
-- Order: READY clears (no 2-swap setup) first, then the 2-swap SETUPS; within each group, bigger base + deeper cascade
-- first (they clear more).
local function buildChipPriorities()
  local cache = require("bot.chipCache")
  local seen, kinds = {}, {}
  for _, c in ipairs(cache) do if not seen[c.kind] then seen[c.kind] = true; kinds[#kinds + 1] = c.kind end end
  local function rank(k)
    local setup = k:find("SWAP_2", 1, true) and 1 or 0       -- 2-swap setups sort after ready clears
    local base = tonumber(k:match("COMBO_(%d)")) or 0        -- base combo size
    local casc = tonumber(k:match("CASCADE_(%d)")) or 0      -- cascade depth
    return setup * 1000 - (base * 10 + casc)                 -- ready first; bigger/deeper first
  end
  table.sort(kinds, function(a, b) local ra, rb = rank(a), rank(b); if ra ~= rb then return ra < rb end return a < b end)
  return kinds
end
local CHIP_PRIORITIES = buildChipPriorities()

------------------------------------------------------------------ DECIDE (stateless, re-measured every frame)
function EnvelopeBrain:decide(state, stack, match)
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local top = math.min(rows, height + 1)
  local cursor = state.cursor or { top, 3 }

  -- a match is clearing -> WAIT: don't swap into it or undo a combo we just made (the engine won't let us re-swap
  -- matched panels anyway). This is the only anti-oscillation gate we need.
  if hasPendingMatch(grid, rows) then return { type = "WAIT" } end

  -- STATE by stack height. All states fire the same combo chips; the state only changes the no-play FALLBACK:
  -- RAISE pushes up for material, OFFENSE/DANGER never raise.
  local st = (height >= DANGER_ABOVE and "DANGER") or (height <= RAISE_BELOW and "RAISE") or "OFFENSE"
  self._state = st

  -- re-measure EVERY frame from the live cursor -- NO stale sig-commit. A chip forming while the board settles (panels
  -- falling/clearing below the top) is found immediately, not skipped because the top color-grid happened to be
  -- unchanged. The CursorController locks its target mid-travel, so re-deciding here can't thrash the cursor.
  local chip = useChips.useChips(grid, rows, cursor, {
    chipPriorities = CHIP_PRIORITIES, searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" },
    verify = self:chipVerify(stack, match),
  })
  if chip then
    self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1
    return { type = "SWAP", pos = chip.swaps[1], swaps = chip.swaps }  -- pass the FULL sequence; the controller completes it
  elseif st == "RAISE" then
    return { type = "RAISE" }              -- no chip + too low -> push stack up for material
  end
  return { type = "WAIT" }                  -- no chip -> wait (building is a future SETUP *chip*)
end

return EnvelopeBrain
