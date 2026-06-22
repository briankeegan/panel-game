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
local RECOVERY_BUFFER = 5  -- raise fills only to top-5 (raise less); OFFENSE owns the wider band up to DANGER (top-1)

-- Chip selection is META-DRIVEN: each state expresses what it wants as a meta FILTER + a RANK, and extractByMeta turns
-- that into the ordered kind list useChips consumes. No name parsing, so any new family (BREAK_*, SHOGUN_*, ...) joins
-- automatically and sorts by real value. The only name policies: drop the wasteful COMBO_3 setups, and pin plain
-- COMBO_3 dead-last (a last-resort clear when nothing bigger exists).
local function isExcluded(kind) return kind:match("^COMBO_3_%a") ~= nil end
-- rank a chip by its META (ASC: lower = tried first). total = panels cleared, swaps = 1 ready / 2 setup, chain = depth.
local function rankKind(kind, meta)
  local setup = (meta and (meta.swaps or 1) > 1) and 1 or 0      -- ready clears before 2-swap setups
  local size = (meta and meta.total) or 0                        -- real panels cleared (name-independent)
  local chain = (meta and meta.chain) or 0
  return setup * 1000 - (size * 10 + chain)                      -- bigger / deeper first
end
-- extractByMeta(filter, rankFn) -> ordered kinds: every cache kind whose meta passes filter(meta, kind), sorted ASC by
-- rankFn(kind, meta), with plain COMBO_3 force-appended LAST (policy). THE selection primitive -- filter can be static
-- (OFFENSE/DANGER below) or situational (e.g. "garbage that breaks the incoming") computed per-decision.
local function extractByMeta(filter, rankFn)
  local cache = require("bot.chipCache")
  local seen, rows, hasC3 = {}, {}, false
  for _, c in ipairs(cache) do
    if not isExcluded(c.kind) and not seen[c.kind] and filter(c.meta, c.kind) then
      seen[c.kind] = true
      if c.kind == "COMBO_3" then hasC3 = true                  -- policy: plain 3-clear is the LAST RESORT in EVERY state
      else rows[#rows + 1] = { kind = c.kind, r = rankFn(c.kind, c.meta) } end
    end
  end
  table.sort(rows, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.kind < b.kind end)
  local kinds = {}; for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
  if hasC3 then kinds[#kinds + 1] = "COMBO_3" end               -- appended dead-last, after everything, in all states
  return kinds
end
local ANY = function() return true end
-- OFFENSE: build biggest (ready-first, then size/depth). DANGER: the SAME set so it never goes empty, but READY
-- single-swap clears FIRST -- clear NOW; setups/chains fall back only when no ready clear exists. COMBO_3 is pinned
-- dead-last in BOTH by extractByMeta.
local OFFENSE_PRIORITIES = extractByMeta(ANY, rankKind)
local DANGER_PRIORITIES = extractByMeta(ANY, function(kind, meta)
  local notReady = (meta and (meta.swaps or 1) == 1 and (meta.chain or 0) == 0) and 0 or 1
  return notReady * 1000000 + rankKind(kind, meta)
end)

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
  local totalHeight = state.totalHeight or height  -- stack INCLUDING garbage -- what must stay below the top
  local cursor = state.cursor or { math.min(rows, height + 1), 3 }

  -- RAISE FILLS the stack to the TOP. Garbage counts as part of the stack (totalHeight); NO reserve for incoming
  -- garbage. DANGER (within 1 of the top, incl garbage) takes over to clear, so the raise itself never tops us out.
  -- STATE precedence DANGER > RAISE > OFFENSE.
  local top = state.height or 12
  local raiseTarget = top - RECOVERY_BUFFER
  local move
  do
    local st = ((totalHeight >= top - 1 or state.toppedOut) and "DANGER")  -- within 1 of the top (incl garbage): clear NOW
      or (totalHeight < raiseTarget and "RAISE")                           -- below the top: fill material
      or "OFFENSE"
    self._state = st
    -- DANGER clears NOW (ready single-swap clears first); OFFENSE builds big (cascades/setups first). Same all-direction search.
    local priorities = (st == "DANGER") and DANGER_PRIORITIES or OFFENSE_PRIORITIES
    local chip = useChips.useChips(grid, rows, cursor, {
      chipPriorities = priorities, searchPriorities = { "UP", "DOWN", "LEFT", "RIGHT" },
      verify = self:chipVerify(stack, match), touchable = touchable,
    })
    if chip then
      self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1
      move = { type = "SWAP", pos = chip.swaps[1], swaps = chip.swaps, kind = chip.kind }
    elseif st == "RAISE" and not busy and (state.stopTime or 0) == 0 then
      move = { type = "RAISE" }              -- no chip + below the top -> fill material (DANGER clears before we top out)
    else
      move = { type = "WAIT" }
    end
  end
  -- Only cache a SETTLED decision. The signature is the color grid only -- it can't tell a settling board from the same
  -- board once it's at rest -- so caching a busy-frame WAIT (where the no-go mask blocked an otherwise-playable chip)
  -- would hand that stale WAIT back the instant it settles and SUPPRESS the chip. Caching only when not busy fixes it.
  if not busy then self._sig, self._move = sig, move else self._sig = nil end
  return move
end

return EnvelopeBrain
