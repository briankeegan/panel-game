-- EnvelopeBrain — the chips-brain live decide. STATELESS: every frame it re-measures from the CURRENT cursor and
-- picks an immediate move. No stored plan -> a mid-travel rise can't drift the target (next frame just re-measures
-- from the new cursor snapshot). Search is cursor-outward (here, then left/up/down/right, then further). A move is
-- only ever a VERIFIED chip (or a setup swap that makes one appear); otherwise wait for material.
--   decide(state) -> { type="SWAP", pos={r,c} } | { type="WAIT" }
local BoardSim = require("bot.BoardSim")
local useChips = require("bot.useChips")
local garbageReveal = require("bot.garbageReveal")     -- fair reveal reader (breakingRow / openColumns) for CATCH
local catchPrimitive = require("bot.catchPrimitive")    -- findCatch: the biggest lined-up chip the freed color completes

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
    local ok, fired, broke = pcall(function()
      local clock0 = stack.clock
      for _, s in ipairs(match.stacks) do s:saveForRollback() end
      stack.stop_time = math.max(stack.stop_time or 0, 999)  -- freeze the rise so a rising row can't fire the match instead of the swap
      local hit, gbroke = false, false
      local token = {}  -- weak-keyed subscriber held in scope; signals fire the INSTANT a clear is detected
      stack:connectSignal("matched", token, function() hit = true end)
      stack:connectSignal("garbageMatched", token, function() hit = true; gbroke = true end)  -- garbage broke -> this chip is a BREAK
      for _, mv in ipairs(seq) do
        -- teleport+swap, settling between swaps. The controller's ADAPTIVE settle (wait for the prior swap to land, then
        -- fire the next) reproduces this tightly on the live board, so a chip that verifies here actually fires when
        -- executed -- the routing model over-rejected multi-swap chips that DO execute (proven: +70 panels with them on).
        stack.cur_row, stack.cur_col = mv[1], mv[2]; stack:receiveConfirmedInput(KDE_swap); match:run()
        for k = 1, 20 do
          if hit then break end                          -- garbageMatched fires in the SAME checkMatches as matched, so gbroke is already set
          stack:receiveConfirmedInput("A"); match:run()
          if not stack:hasActivePanels() and not stack:hasChainingPanels() then break end
        end
      end
      stack:disconnectSignal("matched", token); stack:disconnectSignal("garbageMatched", token)
      for _, s in ipairs(match.stacks) do s:rollbackToFrame(clock0) end
      return hit, gbroke
    end)
    if not ok then return false end
    return fired, broke   -- fired = it clears; broke = it broke garbage
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
-- RECOVERY_BUFFER 5->11: in endless the stack already rises passively, so manual raising just tops the bot out faster.
-- raiseTarget = top-11 = 1, so it only raises to avoid an EMPTY board. A/B over 10 seeds: avg survived 27s->38s, median
-- 1295f->1883f, cleared 36->52 -- better on every percentile incl. the worst case.
-- RECOVERY_BUFFER 11->6 (garbage/team build): a SHORTER buffer = TALLER held stack, so incoming garbage lands ON full
-- material with a reachable edge instead of floating high on a short lopsided stack (proven: single block 0 breaks -> 5/8
-- on the fast test; RB=5 tops out, RB=6 is the sweet spot). NOTE: trades off endless survival (RB=11 was tuned for the
-- passive-rise endless mode where manual raising tops out faster) -- revisit a mode-aware buffer once breaking is solid.
local RECOVERY_BUFFER = tonumber(os.getenv("PA_RB")) or 6

-- Chip selection is META-DRIVEN: each state expresses what it wants as a meta FILTER + a RANK, and extractByMeta turns
-- that into the ordered kind list useChips consumes. No name parsing, so any new family (BREAK_*, SHOGUN_*, ...) joins
-- automatically and sorts by real value. The only name policies: drop the wasteful COMBO_3 setups, and pin plain
-- COMBO_3 dead-last (a last-resort clear when nothing bigger exists).
local function isExcluded(kind) return kind == "COMBO_3" or kind:match("^COMBO_3_%a") ~= nil end  -- COMBO_3 NOT allowed (even under pressure -- there's always a better solve: a combo/chain/lineup, not a cheap 3-clear).
-- rank a chip by its META (ASC: lower = tried first). total = panels cleared, swaps = 1 ready / 2 setup, chain = depth.
local function rankKind(kind, meta)
  local setup = (meta and (meta.swaps or 1) > 1) and 1 or 0
  local size = (meta and meta.total) or 0                        -- real panels cleared (name-independent)
  local chain = (meta and meta.chain) or 0
  return -(size * 100 + chain * 50) + setup                      -- BIGGER (incl multi-step setups) first; ready only breaks ties
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
-- CATCH priorities: the catch CREDITS a freed-panel-completed 3+ (incl COMBO_3) as a CHAIN -- the panel falls from the
-- breaking garbage onto a lined-up pair (Brian: "3+ is great, horizontal too"). So unlike OFFENSE/DANGER (which forbid the
-- cheap STANDALONE 3-clear), the catch list KEEPS COMBO_3 -- appended last so a bigger combo/chain still wins when the drop
-- enables one. useChips recognizes both orientations, so this gives HORIZONTAL and VERTICAL 3+ catches.
local CATCH_PRIORITIES = {}; for _, k in ipairs(OFFENSE_PRIORITIES) do CATCH_PRIORITIES[#CATCH_PRIORITIES+1] = k end; CATCH_PRIORITIES[#CATCH_PRIORITIES+1] = "COMBO_3"
-- in OFFENSE we HOLD small clears and organize toward bigger ones; only FIRE a clear this big (or any chain).
local META = (function() local cache = require("bot.chipCache"); local m = {}; for _, c in ipairs(cache) do m[c.kind] = m[c.kind] or c.meta end; return m end)()
local OFFENSE_FIRE_MIN = 6
local function chipIsBig(kind) local m = META[kind]; return m ~= nil and ((m.total or 0) >= OFFENSE_FIRE_MIN or (m.chain or 0) >= 1) end

------------------------------------------------ DECIDE (re-measured on any board activity; cached while fully static)
-- CATCH (Brian's lineup): my garbage is breaking -> top off the revealing colors into chains. Loop opened columns
-- RIGHT->LEFT (most lead first); return the first catch that needs a SWAP to set up (catalog combo/chain preferred,
-- topOff as the floor). Ready 'already' catches need no move -- they fire when the freed row drops. {swaps,kind} | nil.
function EnvelopeBrain:tryCatch(grid, rows, stack, priorities, verify, touchable)
  local open = garbageReveal.openColumns(stack)
  for c = BoardSim.WIDTH, 1, -1 do
    local color = open[c]
    if color then
      local cat = catchPrimitive.findCatch(grid, rows, c, color, { priorities = CATCH_PRIORITIES, verify = verify })  -- CATCH_PRIORITIES keeps COMBO_3 -> credits a freed-drop 3+ (H or V) as a chain
      if cat and cat.kind ~= "TOPOFF" then return { swaps = cat.swaps, kind = "CATCH_" .. cat.kind } end       -- catalog combo/chain
      if cat and cat.kind == "TOPOFF" and cat.swap then return { swaps = { cat.swap }, kind = "CATCH_TOPOFF" } end -- 1-swap floor
      local route = (not os.getenv("PA_NOROUTE")) and catchPrimitive.catchRoute(grid, rows, c, color, touchable) or nil  -- multi-swap stack; PA_NOROUTE isolates whether ONLY this disruptive path hurts vs the 1-swap topoff
      if route then return { swaps = { route }, kind = "CATCH_ROUTE" } end
    end
  end
  return nil
end

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
  -- Raise/build a base BEFORE a block lands; the MOMENT garbage is ON the board, STOP raising (Brian: the trigger is
  -- garbage LANDED, not incoming -- you keep playing while it's still in transit, and lock down once it's actually here).
  local safeToRaise = not state.lowestGarbageRow
  -- RAISE on the AVERAGE column fill, not the tallest: gating on the tallest let a single height-6 column keep the bot in
  -- OFFENSE forever while the rest of the board sat empty -> it never raised, never built material, couldn't break (Brian:
  -- "the first thing it should do is raise; otherwise it has no material"). Average fill builds material everywhere first.
  local sumH = 0
  for c = 1, BoardSim.WIDTH do local h = 0; for r = rows, 1, -1 do if (grid[r][c] or 0) ~= 0 then h = r; break end end; sumH = sumH + h end
  local avgH = sumH / BoardSim.WIDTH
  local move
  do
    local st = ((totalHeight >= top - 1 or state.toppedOut) and "DANGER")  -- within 1 of the top (incl garbage): clear NOW
      or (avgH < raiseTarget and totalHeight < top - 5 and safeToRaise and "RAISE")  -- build material on AVERAGE fill, but CAP the tallest (top-5): leave headroom so a landing garbage block still has empty room to build a break in -- raising the board solid means breakRoute can't fire and the bot deadlocks (broke freezes, tops out)
      or "OFFENSE"
    self._state = st
    -- DANGER clears NOW (ready single-swap clears first); OFFENSE builds big (cascades/setups first). Same all-direction search.
    local priorities = (st == "DANGER") and DANGER_PRIORITIES or OFFENSE_PRIORITIES
    local verify = self:chipVerify(stack, match)
    local search = { "UP", "DOWN", "LEFT", "RIGHT" }
    -- ===================== DECISION TREE (Brian: one decision per situation -- no competing, nothing unreachable) =====
    -- A) my garbage is BREAKING -> CATCH the revealing colors. We have time, and a catch clear re-breaks the block on its
    --    own, so NEVER force another break here. B) sealed garbage on the board -> COMMIT to clearing the block: break it,
    --    or flatten ONLY to ENABLE the break -- no raise/plan distractions. C) no garbage -> the height state decides.
    -- breaking and lowestGarbageRow are mutually exclusive situations, so exactly ONE branch runs each frame.
    local breaking = stack and garbageReveal.breakingRow(stack)
    local function clearChip(req, allowC3)
      local o = { chipPriorities = priorities, searchPriorities = search, verify = verify, touchable = touchable }
      if req then o.requireBreak = true end
      local chip = useChips.useChips(grid, rows, cursor, o)
      if chip and chip.kind == "COMBO_3" and not allowC3 then return nil end  -- plain 3-clear: only under pressure (clear freed rows / drop height); held in OFFENSE so it doesn't drain the material we raised
      return chip
    end
    local function fireChip(chip, sub)   -- a recognized catalog chip -> SWAP (keep its kind for the executor), tally use
      self._comboUse = self._comboUse or {}; self._comboUse[chip.kind] = (self._comboUse[chip.kind] or 0) + 1
      self._substate = sub; move = { type = "SWAP", pos = chip.swaps[1], swaps = chip.swaps, kind = chip.kind }
    end
    local function fireSwap(rc, kind)    -- a raw routing / organize swap {r,c}
      self._substate = kind; move = { type = "SWAP", pos = rc, swaps = { rc }, kind = kind }
    end
    local function wait() self._substate = "WAIT"; move = { type = "WAIT" } end
    -- last resort when nothing direct is playable: build toward a break/clear (NOT a competing path -- only runs after the
    -- situation's real options all returned nil). keepMaterial holds in OFFENSE-with-garbage (build to break), clears in DANGER.
    local function planFallback()
      local mv = useChips.planMove(grid, rows, touchable, cursor, st == "DANGER", false)  -- keepMaterial=false: under a flood, CLEAR/drop height rather than hold (the catch+break already supply the breaking)
      if mv then fireSwap(mv, "PLAN") else wait() end
    end
    self._substate = nil
    if breaking then
      -- A. BREAKING: my garbage is popping -> don't break again. The CATCH (lining up freed panels) is OUT: on the real
      -- engine it nets NEGATIVE -- it disrupts the board and halves total breaks (off=31.3s/broke78 vs on=25.6s/broke42,
      -- topoff-only=24.2s). Back to the table for a non-disruptive catch. For now: clear what's there, else flatten so the
      -- NEXT break lands flat, else build toward a clear.
      local catch = self:tryCatch(grid, rows, stack, priorities, verify, touchable)  -- LINE UP the freed panels into the biggest combo/chain they complete (the better solve, not a 3-clear)
      if catch then self._substate = "CATCH"; move = { type = "SWAP", pos = catch.swaps[1], swaps = catch.swaps, kind = catch.kind }
      else local cl = clearChip(false)
        if cl then fireChip(cl, "CLEAR")
        else local fl = catchPrimitive.flattenMove(grid, rows, touchable)
          if fl then fireSwap(fl, "FLATTEN") else planFallback() end
        end
      end
    elseif state.lowestGarbageRow then
      -- B. SEALED garbage: commit to removing the block -- break it, or flatten ONLY to enable the break.
      local bc = clearChip(true, true)                                    -- a ready clear that pops the block (incl a COMBO_3 break+clear)
      if bc then fireChip(bc, "CLEAR")
      else local br = catchPrimitive.breakRoute(grid, rows, touchable)    -- route to complete the vertical-3 next to it
        if br then fireSwap(br, "BREAK_ROUTE")
        else local fl = catchPrimitive.flattenMove(grid, rows, touchable) -- break unreachable -> flatten to ENABLE it
          if fl then fireSwap(fl, "FLATTEN")
          else local cl = clearChip(false, true)                         -- otherwise clear (incl 3s) to drop height while we set up
            if cl then fireChip(cl, "CLEAR") else planFallback() end
          end
        end
      end
    else
      -- C. NO garbage: the height state decides.
      if st == "DANGER" then
        local cl = clearChip(false, true)                                -- near the top: clear ANYTHING (incl 3s) to drop height
        if cl then fireChip(cl, "CLEAR") else planFallback() end
      elseif st == "RAISE" and not busy then
        self._substate = "RAISE"; move = { type = "RAISE" }              -- low material: fill the stack
      else                                                               -- OFFENSE
        local cl = clearChip(false, false)                               -- HOLD small 3-clears (build material); fire only big combos
        if cl then fireChip(cl, "CLEAR")
        else local mv = useChips.planMove(grid, rows, touchable, cursor, false, true)  -- keepMaterial=TRUE in OFFENSE: build toward big combos, hold material; don't drain it with small clears
          if mv then fireSwap(mv, "PLAN")
          elseif not busy and safeToRaise then self._substate = "RAISE"; move = { type = "RAISE" }
          else wait() end
        end
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
