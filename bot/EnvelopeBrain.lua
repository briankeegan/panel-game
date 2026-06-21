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
-- DYNAMIC raise: never raise past a height that leaves this many rows of recovery headroom below the top, so a raise
-- can NEVER top us out. The target also reserves room for pending incoming garbage, and rises on its own as clearing
-- keeps the stack lower. (Tighten as clearing improves; raise-to-death is a bug, so this stays safe.)
local RECOVERY_BUFFER = 6

-- Per-state chip priorities, built from the cache (auto-includes new families). Order within a set: READY clears first,
-- then 2-swap SETUPS; bigger base + deeper cascade first (they clear more).
local EXCLUDE_KINDS = { COMBO_3 = true }  -- skip trivial 3-panel clears: force the bot toward bigger plays
local function rank(k)
  local setup = k:find("SWAP_2", 1, true) and 1 or 0       -- 2-swap setups sort after ready clears
  local base = tonumber(k:match("COMBO_(%d)")) or 0        -- base combo size
  local casc = tonumber(k:match("CASCADE_(%d)")) or 0      -- cascade depth
  return setup * 1000 - (base * 10 + casc)                 -- ready first; bigger/deeper first
end
local function buildPriorities(keep)
  local cache = require("bot.chipCache")
  local seen, kinds = {}, {}
  for _, c in ipairs(cache) do
    if not EXCLUDE_KINDS[c.kind] and not seen[c.kind] and keep(c.kind) then seen[c.kind] = true; kinds[#kinds + 1] = c.kind end
  end
  table.sort(kinds, function(a, b) local ra, rb = rank(a), rank(b); if ra ~= rb then return ra < rb end return a < b end)
  return kinds
end
-- OFFENSE: every chip, built big-first (cascades/setups lead). DANGER: the SAME full set so it never goes empty, but
-- READY single-swap clears FIRST -- clear now; chains/setups only fall back when no ready clear exists.
local OFFENSE_PRIORITIES = buildPriorities(function() return true end)
local DANGER_PRIORITIES = (function()
  local p = {}; for _, k in ipairs(OFFENSE_PRIORITIES) do p[#p + 1] = k end
  local function ready(k) return (not k:find("SWAP_2", 1, true) and not k:find("CASCADE", 1, true)) and 0 or 1 end
  table.sort(p, function(a, b) local ra, rb = ready(a), ready(b); if ra ~= rb then return ra < rb end return rank(a) < rank(b) end)
  return p
end)()

------------------------------------------------ DECIDE (re-measured on any board activity; cached while fully static)
function EnvelopeBrain:decide(state, stack, match)
  local rows = state.rows
  local grid = BoardSim.colorGrid(state.board, rows)
  local touchable = BoardSim.touchableGrid(state.board, rows)  -- NO-GO mask: cells the bot can read/swap (settled only)

  -- CACHE: while the board is fully static (nothing active/chaining/flashing) AND the grid is unchanged since the last
  -- decision, recognition returns the identical result -- skip the whole ~670-template pass. ANY board activity bypasses
  -- the cache, so chips forming as the board settles/pops/rises are seen at once. (Unlike the removed sig-commit, which
  -- keyed only on the top color-grid and stayed frozen through the 44-frame flash -- starving the brain.)
  -- signature includes the TOUCHABLE state, not just colors: a cell mid-action (no-go) blocks chips, so the same colors
  -- settled vs. settling are DIFFERENT playability and must not share a cache entry (that was suppressing chips).
  local sig = 0
  for r = 1, rows do for c = 1, BoardSim.WIDTH do
    sig = (sig * 31 + (grid[r][c] or 0) * 2 + (touchable[r] and touchable[r][c] and 1 or 0)) % 2147483647
  end end
  local busy = stack and (stack:hasActivePanels() or stack:hasChainingPanels())
  if not busy and sig == self._sig and self._move ~= nil then return self._move end

  local height = state.maxColHeight or BoardSim.maxHeight(grid, rows)
  local cursor = state.cursor or { math.min(rows, height + 1), 3 }

  -- STATE drives the tactic (precedence DANGER > RAISE > OFFENSE):
  --   DANGER (high stack)        -> clear NOW: ready single-swap combos only (no chains/setups), ease the cursor UP.
  --   RAISE  (low real material) -> feed the stack (the no-chip fallback raises).
  --   OFFENSE (default)          -> build big: every chip, search all directions.
  local move
  do
    local st = ((state.toppedOut or height >= DANGER_ABOVE) and "DANGER")  -- near the ceiling: the emergency
      or ((state.nonGarbageRows or 99) < 5 and "RAISE")                    -- low real material: feed the stack
      or "OFFENSE"
    self._state = st
    -- DANGER clears NOW (ready single-swap first), easing the cursor UP toward the top; OFFENSE builds big, all dirs.
    local priorities = (st == "DANGER") and DANGER_PRIORITIES or OFFENSE_PRIORITIES
    local search = (st == "DANGER") and { "UP", "LEFT", "RIGHT" } or { "UP", "DOWN", "LEFT", "RIGHT" }
    local chip = useChips.useChips(grid, rows, cursor, {
      chipPriorities = priorities, searchPriorities = search,
      verify = self:chipVerify(stack, match), touchable = touchable,
    })
    if chip then
      self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1
      move = { type = "SWAP", pos = chip.swaps[1], swaps = chip.swaps }  -- full sequence; the controller completes it
    else
      -- DYNAMIC safe-raise: climb only up to a target that still leaves RECOVERY_BUFFER rows to the top AND room to
      -- absorb pending incoming garbage. The target SELF-LIMITS, so a raise can never top us out (raise-to-death is a
      -- bug); it rises on its own as clearing keeps the stack lower. Settled (rise_lock) + no stop_time to waste.
      local incomingRows = 0
      for _, g in ipairs(state.incoming or {}) do incomingRows = incomingRows + (g.h or 0) end
      local raiseTarget = (state.height or 12) - RECOVERY_BUFFER - incomingRows
      if not busy and (state.stopTime or 0) == 0 and height < raiseTarget then
        move = { type = "RAISE" }            -- low enough that raising still leaves a full recovery buffer -> safe
      else
        move = { type = "WAIT" }             -- no safe headroom to raise (or breaking) -> wait; the brain keeps searching
      end
    end
  end
  -- Only cache a SETTLED decision. The signature is the color grid only -- it can't tell a settling board from the same
  -- board once it's at rest -- so caching a busy-frame WAIT (where the no-go mask blocked an otherwise-playable chip)
  -- would hand that stale WAIT back the instant it settles and SUPPRESS the chip. Caching only when not busy fixes it.
  if not busy then self._sig, self._move = sig, move else self._sig = nil end
  return move
end

return EnvelopeBrain
