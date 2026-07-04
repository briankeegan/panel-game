-- EnvelopeBrain — the chips-brain live decide. STATELESS: every frame it re-measures from the CURRENT cursor and
-- picks an immediate move. No stored plan -> a mid-travel rise can't drift the target (next frame just re-measures
-- from the new cursor snapshot). Search is cursor-outward (here, then left/up/down/right, then further). A move is
-- only ever a VERIFIED chip (or a setup swap that makes one appear); otherwise wait for material.
--   decide(state) -> { type="SWAP", pos={r,c} } | { type="WAIT" }
local BoardSim = require("bot.BoardSim")
local useChips = require("bot.useChips")
local garbageReveal = require("bot.garbageReveal")     -- fair reveal reader (breakingRow / openColumns) for CATCH
local catchPrimitive = require("bot.catchPrimitive")    -- findCatch: the biggest lined-up chip the freed color completes
local chainSim = require("bot.chainSim")                -- bestChain: the deepest single-swap chain on the live board (depth matches engine); the height drop IS the danger escape

local EnvelopeBrain = {}
EnvelopeBrain.__index = EnvelopeBrain

function EnvelopeBrain.new(_opts)
  -- _endless gates the chain ORGANIZE/fire: ride-the-board-up-then-fire-a-deep-chain is an ENDLESS strategy; in garbage
  -- it's suicide (the packed board leaves no headroom for a landing block -> instant topout). Default OFF = garbage-safe.
  -- _bigGarbageGame: tall blocks (h>=3) are coming (known mode, e.g. the large_garbage training preset). Also flips on
  -- automatically the first time one shows up in the incoming queue -- but a surprise first block gives only ~1s of
  -- telegraph, so a mode that KNOWS should announce it up front and the bot postures short/flat from frame 0.
  return setmetatable({
    _endless = _opts and _opts.endless or false,
    _bigGarbageGame = (_opts and _opts.bigGarbage) or false,
  }, EnvelopeBrain)
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
    local function dumpBoard()
      local rows = {}
      for r = math.min(stack.height or 12, 6), 1, -1 do
        local row = {}
        for c = 1, 6 do
          local p = stack.panels[r] and stack.panels[r][c]
          row[c] = p and string.format("%s/%s/%s/%s/%s", tostring(p.color or 0), tostring(p.isGarbage), tostring(p.state), tostring(p.timer), tostring(p.pop_time)) or "."
        end
        rows[#rows+1] = table.concat(row, " ")
      end
      return table.concat(rows, "|") .. " clock=" .. tostring(stack.clock) .. " stopWatch=" .. tostring(stack.stopWatch)
        .. " stop_time=" .. tostring(stack.stop_time) .. " pre_stop=" .. tostring(stack.pre_stop_time)
        .. " rise_timer=" .. tostring(stack.rise_timer) .. " displacement=" .. tostring(stack.displacement)
        .. " rise_lock=" .. tostring(stack.rise_lock) .. " manual_raise=" .. tostring(stack.manual_raise)
    end
    if os.getenv("PA_VERIFYDIAG") then _G._verifyCallCount = (_G._verifyCallCount or 0) + 1 end
    local before = os.getenv("PA_VERIFYDIAG") and dumpBoard() or nil
    local ok, fired, broke = pcall(function()
      local clock0 = stack.clock
      -- ROOT-CAUSE FIX (2026-07, single-seed trace on seed 1010), take 2: the FIRST fix attempt (truncate
      -- confirmedInput back to its pre-test length after Stack:rollbackToFrame) crashed with "bad argument #1 to
      -- 'unpack' (table expected, got nil)" in Stack:controls. Root cause of THAT crash: Stack:rollbackToFrame sets
      -- lastRollbackFrame = the PRE-rollback clock (see its own comment: "match will try to fast forward this stack
      -- to that frame") -- i.e. it's the "rewind then RESIMULATE forward with corrected input" primitive used for real
      -- netcode rollback, not a "test then fully undo" primitive. With lastRollbackFrame > clock afterwards,
      -- Stack:behindRollback() is true, so Stack:shouldRun ignores the confirmedInput buffer entirely and forces
      -- Match:run to keep calling stack:run() until stack.clock catches up to Match.clock (which our test's own
      -- match:run() calls had already ratcheted forward, since Match.clock only ever increases) -- consuming
      -- confirmedInput indices we had just truncated away. The engine ships the exact primitive we actually want:
      -- Stack:rewindToFrame (and Match:rewindToFrame, which also resets Match.clock itself, undoing the ratchet)
      -- sets lastRollbackFrame = the TARGET clock, so behindRollback() is immediately false and nothing tries to
      -- fast-forward. Combined with truncating confirmedInput back to its pre-test length (still necessary --
      -- rewind/rollback restore panels/scalars but never touch confirmedInput, which is our own addition via
      -- receiveConfirmedInput below), the stack is left in a state byte-identical to "this verify() call never
      -- happened", confirmed via PA_INPUTDIAG/PA_ROLLBACKDIAG/PA_VERIFYDIAG's board dumps.
      local inputLen0 = {}
      for _, s in ipairs(match.stacks) do s:saveForRollback(); inputLen0[s] = #s.confirmedInput end
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
      local clockBeforeRewind = match.clock
      match:rewindToFrame(clock0)   -- rewinds EVERY stack + Match.clock itself; sets lastRollbackFrame=clock0 so nothing fast-forwards back
      if os.getenv("PA_ROLLBACKDIAG") and stack.clock ~= clock0 then
        print(string.format("  ROLLBACKDIAG: rewindToFrame(%d) FAILED -- stack clock now %s, match clock was %s now %s",
          clock0, tostring(stack.clock), tostring(clockBeforeRewind), tostring(match.clock)))
      end
      for _, s in ipairs(match.stacks) do
        if os.getenv("PA_INPUTDIAG") then
          print(string.format("  INPUTDIAG clock0=%d #confirmedInput_before_trunc=%d inputLen0=%d stack.clock_after_rewind=%s",
            clock0, #s.confirmedInput, inputLen0[s] or -1, tostring(s.clock)))
        end
        for i = #s.confirmedInput, (inputLen0[s] or 0) + 1, -1 do s.confirmedInput[i] = nil end  -- erase the phantom test input this call appended
      end
      return hit, gbroke
    end)
    if not ok then
      if os.getenv("PA_VERIFYDIAG") then print("  VERIFYDIAG: chipVerify pcall FAILED: " .. tostring(fired)) end  -- pcall puts the error message in the 2nd return slot on failure
      return false
    end
    if before then
      local after = dumpBoard()
      if after ~= before then
        print("  VERIFYDIAG: board CHANGED across a single verify() call")
        print("    before: " .. before)
        print("    after:  " .. after)
      end
    end
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
local function extractByMeta(filter, rankFn, includeC3)
  local cache = require("bot.chipCache")
  local seen, rows, hasC3 = {}, {}, false
  for _, c in ipairs(cache) do
    -- COMBO_3 handling (2026-07-03, root-caused by bot/tests/popNowVerify.lua): the old code checked
    -- `c.kind == "COMBO_3"` AFTER the isExcluded gate, which excludes COMBO_3 -- so the documented "pinned
    -- dead-last in every state" was dead code and OFFENSE/DANGER never contained a plain 3-clear. Making it
    -- reachable everywhere was then MEASURED WORSE on the 10-seed 6x12 sweep (median 22.0s -> 17.4s: the bot
    -- mines its own break material with cheap 3s), so the exclusion stands for OFFENSE/DANGER and the append
    -- is now an EXPLICIT opt-in (includeC3) for the callers whose semantics genuinely need a bare 3-clear:
    -- POP-NOW ("any immediate pop beats a still frame at stop 0") -- without it that guard can never fire.
    if c.kind == "COMBO_3" then hasC3 = hasC3 or (includeC3 and filter(c.meta, c.kind) or false)
    elseif not isExcluded(c.kind) and not seen[c.kind] and filter(c.meta, c.kind) then
      seen[c.kind] = true
      rows[#rows + 1] = { kind = c.kind, r = rankFn(c.kind, c.meta) }
    end
  end
  table.sort(rows, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.kind < b.kind end)
  local kinds = {}; for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
  if hasC3 then kinds[#kinds + 1] = "COMBO_3" end               -- appended dead-last, only when includeC3 opted in
  return kinds
end
local ANY = function() return true end
-- OFFENSE: build biggest (ready-first, then size/depth). DANGER: the SAME set so it never goes empty, but READY
-- single-swap clears FIRST -- clear NOW; setups/chains fall back only when no ready clear exists. NEITHER contains
-- plain COMBO_3 (measured: allowing it mined break material, 10-seed median 22.0s -> 17.4s); POP-NOW opts in below.
local OFFENSE_PRIORITIES = extractByMeta(ANY, rankKind)
local dangerRank = function(kind, meta)
  local notReady = (meta and (meta.swaps or 1) == 1 and (meta.chain or 0) == 0) and 0 or 1
  return notReady * 1000000 + rankKind(kind, meta)
end
local DANGER_PRIORITIES = extractByMeta(ANY, dangerRank)
-- POP-NOW list: ready clears first AND the bare COMBO_3 available dead-last. Used ONLY by the sealed branch's
-- POP-NOW guard, where ANY immediate pop beats a still frame at stop_time 0 -- without COMBO_3 here the guard
-- could literally never fire on the boards it exists for (bot/tests/popNowVerify.lua).
local POPNOW_PRIORITIES = extractByMeta(ANY, dangerRank, true)
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
-- CROSS-COLUMN GUARD (2026-07, single-seed trace on seed 1010): when 2+ columns are open in the SAME reveal, tryCatch
-- serves only ONE per frame (highest column number first) -- so a lower column can sit "ALREADY-READY" (holding, per
-- the fix above) for many frames while a higher column's catchSlide/catchRoute keeps searching. Those searches scan
-- the WHOLE row for the target color, with no awareness of any OTHER column's finished pair -- traced exact cells:
-- col5 held a(row2)=4/b(row1)=4 ready for 2 frames, then col6's own catch action swapped row1 cols 3-4, which
-- happened to change row1-col5 from 4 to 3, silently breaking col5's pair (it had to redo the TOPOFF swap one frame
-- later). Fix: before resolving the served column, cheaply check EVERY OTHER open column for ready (findTopOff is
-- pure/cheap, no verify) and mark its 2 cells reserved; the served column's catalog/slide/route search then treats
-- those cells as not-touchable, so it can never pick a swap through a finished pair.
local function reservedCellsFrom(grid, rows, open, skipCol)
  local reserved = nil
  for cc = 1, BoardSim.WIDTH do
    if cc ~= skipCol and open[cc] then
      local t = catchPrimitive.topRow(grid, cc, rows)
      if t >= 2 then
        local ready = catchPrimitive.findTopOff(grid, cc, open[cc], 6, rows)
        if ready and ready.already then
          reserved = reserved or {}
          reserved[t] = reserved[t] or {}; reserved[t][cc] = true
          reserved[t-1] = reserved[t-1] or {}; reserved[t-1][cc] = true
        end
      end
    end
  end
  return reserved
end
local function guardTouchable(touchable, reserved)
  if not reserved then return touchable end
  return setmetatable({}, { __index = function(_, r)
    if not reserved[r] then return touchable and touchable[r] end
    local baseRow = touchable and touchable[r]
    return setmetatable({}, { __index = function(_, c)
      if reserved[r][c] then return false end
      return baseRow and baseRow[c]
    end })
  end })
end

function EnvelopeBrain:tryCatch(grid, rows, stack, priorities, verify, touchable)
  local open = garbageReveal.openColumns(stack)
  for c = BoardSim.WIDTH, 1, -1 do
    local color = open[c]
    if color then
      local reserved = reservedCellsFrom(grid, rows, open, c)
      local guarded = guardTouchable(touchable, reserved)
      if os.getenv("PA_GUARDDIAG") and reserved then
        local cells = {}
        for r, row in pairs(reserved) do for cc in pairs(row) do cells[#cells+1] = string.format("(%d,%d)", r, cc) end end
        print(string.format("  GUARDDIAG serving col=%d reserved=%s", c, table.concat(cells, " ")))
      end
      if os.getenv("PA_CATCHDIAG") then
        local t0 = 0; for r = rows, 1, -1 do local v = grid[r][c] or 0; if v ~= 0 and v ~= BoardSim.GARBAGE then t0 = r; break end end
        print(string.format("  CATCHDIAG col=%d color=%d topRow=%d a(row%d)=%s b(row%d)=%s clock=%s disp=%s stop=%s active=%s chaining=%s nap=%s",
          c, color, t0, t0, tostring(grid[t0] and grid[t0][c]), t0-1, tostring(grid[t0-1] and grid[t0-1][c]),
          tostring(stack and stack.clock), tostring(stack and stack.displacement), tostring(stack and stack.stop_time),
          tostring(stack and stack:hasActivePanels()), tostring(stack and stack:hasChainingPanels()), tostring(stack and stack.n_active_panels)))
        if os.getenv("PA_CATCHFULL") then
          for r = math.min(rows, 5), 1, -1 do
            local row = {}
            for cc = 1, 6 do local v = grid[r][cc] or 0; row[cc] = (v == BoardSim.GARBAGE) and "G" or tostring(v) end
            print("    r" .. r .. "  " .. table.concat(row, " "))
          end
        end
      end
      local dbgBefore = os.getenv("PA_CATALOGDBG") and (function() local d = require("bot.chips")._dbg; return d and { fits = d.fits or 0, notTouch = d.notTouch or 0, verRej = d.verRej or 0, accept = d.accept or 0 } or { fits = 0, notTouch = 0, verRej = 0, accept = 0 } end)() or nil
      local cat = catchPrimitive.findCatch(grid, rows, c, color, { priorities = CATCH_PRIORITIES, verify = verify, touchable = guarded })  -- CATCH_PRIORITIES keeps COMBO_3 -> credits a freed-drop 3+ (H or V) as a chain
      if dbgBefore then
        local d = require("bot.chips")._dbg or {}
        local df, dnt, dvr, dac = (d.fits or 0) - dbgBefore.fits, (d.notTouch or 0) - dbgBefore.notTouch, (d.verRej or 0) - dbgBefore.verRej, (d.accept or 0) - dbgBefore.accept
        if df > 0 or dac > 0 then
          print(string.format("  CATALOGDBG col=%d color=%d delta: fits=%d notTouch=%d verRej=%d accept=%d", c, color, df, dnt, dvr, dac))
        end
      end
      if cat and cat.kind ~= "TOPOFF" then
        if os.getenv("PA_CATCHDIAG") then print(string.format("  CATCHDIAG col=%d color=%d CATALOG kind=%s", c, color, cat.kind)) end
        return { swaps = cat.swaps, kind = "CATCH_" .. cat.kind }
      end       -- catalog combo/chain
      if cat and cat.kind == "TOPOFF" and cat.swap then
        if os.getenv("PA_CATCHDIAG") then print(string.format("  CATCHDIAG col=%d color=%d TOPOFF swap=(%d,%d)", c, color, cat.swap[1], cat.swap[2])) end
        return { swaps = { cat.swap }, kind = "CATCH_TOPOFF" }
      end -- 1-swap floor
      if cat and cat.kind == "TOPOFF" and cat.already then
        -- BUG FIX (2026-07, single-seed trace on seed 1010): "already ready" was silently DROPPED here -- neither
        -- branch above matches {kind=TOPOFF, already=true} (no .swap field) -- so tryCatch reported "nothing found"
        -- for a column that was FULLY SET UP, and decide()'s caller fell through to clearChip/flatten, which can
        -- disturb the very pair just finished (traced: 4 slides built a matching pair at col5, it broke again 1
        -- decision later once nothing signaled "hold, don't touch this column"). ready=true holds without disturbing it.
        if os.getenv("PA_CATCHDIAG") then print(string.format("  CATCHDIAG col=%d color=%d ALREADY-READY (holding)", c, color)) end
        return { ready = true, col = c }
      end
      if not os.getenv("PA_NOSLIDE") then
        local slide = catchPrimitive.catchSlide(grid, rows, c, color, guarded)  -- horizontal-slide: no height requirement, monotonic convergence
        if slide then
          if os.getenv("PA_CATCHDIAG") then print(string.format("  CATCHDIAG col=%d color=%d SLIDE swap=(%d,%d)", c, color, slide[1], slide[2])) end
          return { swaps = { slide }, kind = "CATCH_SLIDE" }
        end
      end
      local route = (not os.getenv("PA_NOROUTE")) and catchPrimitive.catchRoute(grid, rows, c, color, guarded) or nil  -- multi-swap stack; PA_NOROUTE isolates whether ONLY this disruptive path hurts vs the 1-swap topoff
      if route then
        if os.getenv("PA_CATCHDIAG") then print(string.format("  CATCHDIAG col=%d color=%d ROUTE swap=(%d,%d)", c, color, route[1], route[2])) end
        return { swaps = { route }, kind = "CATCH_ROUTE" }
      end
    end
  end
  return nil
end

-- LULL SHIELD (pure; extracted 2026-07-03 so bot/tests/lullShieldVerify.lua can prove it in isolation): copy
-- `touchable` with every intact top PAIR (X at t,t-1), that pair's one cocked-trigger cell (t-2, c+-1, first
-- match wins), AND the pair column's SUPPORT cells (rows 1..t-2 of the same column) masked NO-GO. Used by the
-- LULL branch only -- clear/plan/flatten must not mine the staged break material (measured: without it 9/10
-- seeds hit the first landing with cocked=0); staging mechanics keep the plain mask. Shielding the
-- sealed/breaking dig clears was measured 2s WORSE, so this never runs there.
-- SUPPORT-CELL SHIELD (2026-07-03, KNOB -- default OFF, PA_LULLSUPPORT=1 or the module flag to enable): the
-- cell-level shield leaves a hole -- lull PLANs legally clear panels UNDER a staged pair, riding the whole stage
-- down by gravity (proven live in lullShieldVerify PIECE 2). Seed 1001's first-landing death is the endpoint:
-- the lull delivered column heights 5,5,2,3,4,5 and an exhaustive whole-board search proves NO <=3-swap break
-- existed at landing. Masking the CONTACT column's support (rows 1..t-2 where t == board maxT) fixes exactly
-- that -- measured on dev seeds 1001-1010: zero-reveal seeds 4 -> 0, p10 11.5s -> 16.9s, mean 22.2 -> 25.7,
-- broken median 72 -> 141. BUT the holdout window 2001-2010 REGRESSED (mean 24.4 -> 18.4; seeds 2006/2008 with
-- healthy baseline lulls went to zero reveals), and every-pair scoping was worse still (holdout mean 16.9). Net
-- 20-seed mean is negative, so the default stays OFF until the 2006-regression is root-caused -- the mechanism
-- is proven, the interaction isn't understood. Modes (PA_LULLSUPPORT / LULL_SUPPORT_SHIELD): 0 = off (default,
-- baseline byte-identical), 1 = always lock the contact stage, 2 = TRANSIT-ONLY (lock only while a big block is
-- announced in transit, pendingBig >= 3 -- the early lull keeps full clear throughput, addressing the measured
-- "masked lull clears less, board rides higher" failure of mode 1 on the holdout window; measured a NO-OP: the
-- stage-sinking mining happens before the announcement), 3 = SOFT (2026-07-04): no hard support mask at all --
-- lull CLEAR tries the support-locked mask first but FALLS BACK to the plain pair shield (throughput never
-- lost), and lull PLAN scores stage-column sinking as a soft cost (PA_SINKW per dropped row, useChips.planMove
-- opts) instead of forbidding it. Attacks mode 1's holdout regression (starved clears -> board rides higher)
-- while keeping its dev win (stage survives to landing).
-- MODE 3 IS THE DEFAULT (2026-07-04): first variant measured to win dev WITHOUT a holdout regression --
-- dev median/mean 22.0/22.2 -> 25.5/26.9, holdout 20.5/24.4 -> 22.9/24.0, zero-reveal seeds 9/20 -> 7/20,
-- broken median 72/69 -> 105/105 (10-seed 600/3600 hard 6x12, PA_MECH). sinkW swept {60,120,250}: a plateau
-- (both windows within noise across the whole range), so the default weight is untuned-insensitive. PA_LULLSUPPORT=0
-- recovers the old baseline exactly.
EnvelopeBrain.LULL_SUPPORT_SHIELD = tonumber(os.getenv("PA_LULLSUPPORT")) or 3
EnvelopeBrain.SINK_W = tonumber(os.getenv("PA_SINKW")) or 120  -- mode 3 soft cost per row a lull PLAN sinks the stage's contact column (a plain 3-clear's immediate reward is ~500: 120*3=360 loses to a real clear, wins ties). Swept {60,120,250}: flat plateau
-- PER-COLUMN MATERIAL FLOOR (2026-07-04, handoff candidate c -- default-OFF knob pending sweeps): lull PLANs
-- pay PA_FLOORW per row any column of the candidate board sits below PA_LULLFLOOR rows. The avgH>=3 lull gates
-- can't see two hollow columns behind a fine average (seed-1001 landed on 5,5,2,3,4,5 with NO <=3-swap break;
-- zero-reveal seeds 1006/2001/2003/2010 all show the hollow/jagged injection posture under mode 3). Absolute
-- (not delta) so refilling a hollow column is rewarded, not just hollowing discouraged. Lull PLAN only -- the
-- dig branch MUST mine under the block.
EnvelopeBrain.LULL_FLOOR = tonumber(os.getenv("PA_LULLFLOOR")) or 0
EnvelopeBrain.FLOOR_W = tonumber(os.getenv("PA_FLOORW")) or 120
-- CLEAR-side floor PREFERENCE (2026-07-04, default-OFF knob): the PLAN-side floor above was measured a NO-GO
-- (floor=2 byte-identical no-op, floor=3 regressed BOTH windows -- taxing every clear near short columns
-- starves lull throughput exactly like the mode-1 hard mask did). But the hollow-column mining is mostly CLEAR
-- chips, and mode 3's win came from the CLEAR try-order trick: PREFER a clear that avoids the protected cells,
-- fall back to any clear -- zero throughput cost. PA_FLOORCLEAR=N masks all cells of columns at height <= N in
-- the lull CLEAR's FIRST attempt only; the fallback chain (stage-locked mask, then plain pair shield) is
-- unchanged behind it.
EnvelopeBrain.LULL_FLOOR_CLEAR = tonumber(os.getenv("PA_FLOORCLEAR")) or 0
-- pure (unit-tested in lullShieldVerify PIECE 6): copy `base`, additionally mask every cell of each column
-- whose top is 1..floor. Empty columns stay as-is (nothing there to mine; filling them must stay legal in the
-- masks that allow it).
function EnvelopeBrain.floorMask(grid, rows, base, floor)
  local out = {}
  for r = 1, rows do
    local src, dst = base[r], {}
    for c = 1, 6 do dst[c] = (src and src[c]) or false end
    out[r] = dst
  end
  for c = 1, 6 do
    local h = 0
    for r = rows, 1, -1 do local v = grid[r][c] or 0; if v ~= 0 then h = r; break end end
    if h > 0 and h <= floor then for r = 1, h do out[r][c] = false end end
  end
  return out
end
function EnvelopeBrain.lullShield(grid, rows, touchable, lockStage)
  -- direct callers (tests) omit lockStage: any non-zero mode means "exercise the support mask"; decide() passes
  -- the mode-resolved value explicitly (mode 2 folds in the transit gate).
  if lockStage == nil then lockStage = EnvelopeBrain.LULL_SUPPORT_SHIELD ~= 0 end
  local stageCols = nil                                            -- 2nd return: contact columns whose support got locked (mode 3 reads these as SOFT-cost columns)
  local shielded = {}
  for r = 1, rows do
    local src, dst = touchable[r], {}
    for c = 1, 6 do dst[c] = (src and src[c]) or false end
    shielded[r] = dst
  end
  local tops, maxT = {}, 0
  for c = 1, 6 do
    tops[c] = 0
    for r = rows, 1, -1 do local v = grid[r][c] or 0; if v ~= 0 and v ~= BoardSim.GARBAGE then tops[c] = r; break end end
    if tops[c] > maxT then maxT = tops[c] end
  end
  local second = 0
  for c = 1, 6 do if tops[c] < maxT and tops[c] > second then second = tops[c] end end
  if second == 0 then second = maxT end                            -- all columns tied
  for c = 1, 6 do
    local t = tops[c]
    if t >= 2 then
      local X = grid[t][c] or 0
      if X ~= 0 and X ~= BoardSim.GARBAGE and (grid[t-1][c] or 0) == X then
        -- SPREAD RELEASE (2026-07-03, root-caused on holdout seed 2006 with PA_LULLSUPPORT=1): pair mask +
        -- support mask together make the contact column COMPLETELY untouchable, so the rise grows it into a
        -- runaway tower (2006 died at first landing on heights 4,5,1,4,6,7 -- block resting on the lone c6 tip,
        -- provably unbreakable; OFF-baseline survives 48.2s there because mining was the tower relief valve).
        -- A stage 2+ rows above the rest can't brace a flat landing, so once the column is overheight RELEASE
        -- it entirely -- flatten/plan may level it -- and re-stage after. Gated inside the knob: OFF-mode
        -- behavior stays byte-identical to baseline.
        local overheight = lockStage and t == maxT and (maxT - second) >= 2
        if not overheight then
          shielded[t][c] = false; shielded[t-1][c] = false
          if t == maxT and lockStage then                          -- contact column: clearing under it sinks the stage the block lands on
            for r = 1, t - 2 do shielded[r][c] = false end
            stageCols = stageCols or {}; stageCols[c] = true
          end
          if t >= 3 then
            for _, nb in ipairs({ c - 1, c + 1 }) do
              if nb >= 1 and nb <= 6 and (grid[t-2][nb] or 0) == X then shielded[t-2][nb] = false; break end
            end
          end
        end
      end
    end
  end
  return shielded, stageCols
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
  -- TALL-BLOCK awareness: a block h>=3 must be shaved almost entirely (it always reaches the ceiling), so every row we
  -- raise underneath it is pure extra digging. Once one is seen (incoming or landed) this is a BIG-GARBAGE game: never
  -- raise again, hold the short/flat/staged posture between volleys (the queue is often empty between periodic volleys,
  -- so the flag is sticky, not per-frame).
  local pendingBig = 0
  for _, g in ipairs(state.incoming or {}) do
    if (g.h or 0) > pendingBig then pendingBig = g.h end
  end
  if pendingBig >= 3 then self._bigGarbageGame = true end
  -- Raise/build a base BEFORE a block lands; the MOMENT garbage is ON the board, STOP raising (Brian: the trigger is
  -- garbage LANDED, not incoming -- you keep playing while it's still in transit, and lock down once it's actually here).
  -- Exception: in a big-garbage game raising is never safe (see above).
  local safeToRaise = not state.lowestGarbageRow and not self._bigGarbageGame
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
    local function clearChip(req, allowC3, mask, prios, exactFallback)
      local o = { chipPriorities = prios or priorities, searchPriorities = search, verify = verify, touchable = mask or touchable, exactFallback = exactFallback }
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
    -- PA_PLANVERIFY (2026-07, root-causing whether planMove's predicted immediate clear actually lands on the REAL
    -- engine, not a standalone reproduction): stash the prediction when a PLAN swap commits with total>0, then on a
    -- LATER real decide() call (once the controller has had time to travel+execute+settle it) compare against the
    -- stack's own panels_cleared counter -- ground truth from the SAME live run, not a synthetic re-check.
    local function firePlan(mv, total, chain)
      fireSwap(mv, "PLAN")
      if os.getenv("PA_PLANVERIFY") and total and total > 0 and not self._planVerify then
        self._planVerify = { frame = stack.clock or 0, before = stack.panels_cleared or 0, r = mv[1], c = mv[2], total = total, chain = chain or 0 }
        if os.getenv("PA_PLANVERIFY2") then
          print(string.format("  PLANVERIFY2 commit swap=(%d,%d) clock=%s in_countdown=%s", mv[1], mv[2], tostring(stack.clock), tostring(stack.in_countdown)))
        end
        if os.getenv("PA_PLANSTATE") then    -- raw panel STATE codes (not just color) for the whole board, to check
          local parts = {}                    -- for stale matched(3)/popping(2) cells colorGrid doesn't filter out
          for r = math.min(rows, 12), 1, -1 do
            local rc = {}
            for c = 1, 6 do local p = state.board[r] and state.board[r][c]; rc[c] = p and tostring(p.s) or "?" end
            parts[#parts + 1] = "r" .. r .. ":" .. table.concat(rc, ",")
          end
          print("  PLANSTATE " .. table.concat(parts, " "))
        end
      end
    end
    -- FIXED (2026-07): a flat 90-frame-since-COMMIT window (before travel+reaction+fire even happen, let alone a
    -- multi-link chain's per-link FLASH/POP stagger) was too short to let a real chain fully resolve, so this
    -- reported "DID-NOT-MATERIALIZE" for predictions that just hadn't finished yet -- root-caused via
    -- bot/tests/boardSimVerify.lua and bot/tests/chainSimVerify.lua's own "phantom" residual, which turned out to
    -- be the SAME bug in the standalone test's wait loop (both fixed same session). Now waits for genuine
    -- quiescence (20 consecutive frames with no active/chaining panels AND panels_cleared unchanged), capped at
    -- 400 frames so a swap that never fires at all still reports eventually.
    if os.getenv("PA_PLANVERIFY") and self._planVerify then
      local pv = self._planVerify
      local nowCleared = stack.panels_cleared or 0
      local busyNow = stack:hasActivePanels() or stack:hasChainingPanels()
      if busyNow or nowCleared ~= (pv.lastCleared or pv.before) then pv.lastActive = (stack.clock or 0) - pv.frame end
      pv.lastCleared = nowCleared
      local waited = (stack.clock or 0) - pv.frame
      if waited - (pv.lastActive or 0) >= 20 or waited >= 400 then
        local actual = nowCleared - pv.before
        print(string.format("  PLANVERIFY swap=(%d,%d) predictedTotal=%d predictedChain=%d actualClearedByF%d=%d framesWaited=%d %s",
          pv.r, pv.c, pv.total, pv.chain, stack.clock or 0, actual, waited,
          (actual >= pv.total) and "MATCHED" or "DID-NOT-MATERIALIZE"))
        self._planVerify = nil
      end
    end
    -- the deepest chain a single swap fires on the LIVE board (exact facts, depth matches engine). Memoized per decision.
    -- Its height drop is the escape; in DANGER we fire the deepest available, in OFFENSE only a worthwhile (deep) one.
    local _cb
    local function chainBest(force)
      -- chains (firing the colored stack) are an ENDLESS thing. In GARBAGE the bot must BREAK/CATCH the block -- firing
      -- a chain steals those frames and breaking dies (broke -> 0). `force` (big-garbage dig, block ON the board) is the
      -- exception: there a chain converts one garbage row PER LINK and banks danger stop-time per link -- the only shave
      -- mechanism fast enough for a 6x12. (Without force the GARBAGE LINEUP gcb path below was dead code.)
      if not self._endless and not force then return false end
      if _cb == nil then _cb = chainSim.bestChain(chainSim.gridFromStack(stack)) or false
        if _cb and _cb.depth and _cb.depth > (self._peakBestChain or 0) then self._peakBestChain = _cb.depth end  -- diag: deepest potential the organize ever reaches (vs what we fire)
      end
      return _cb
    end
    -- last resort when nothing direct is playable: build toward a break/clear (NOT a competing path -- only runs after the
    -- situation's real options all returned nil). keepMaterial holds in OFFENSE-with-garbage (build to break), clears in DANGER.
    local function planFallback()
      local mv, total, chain = useChips.planMove(grid, rows, touchable, cursor, st == "DANGER", false)  -- keepMaterial=false: under a flood, CLEAR/drop height rather than hold (the catch+break already supply the breaking)
      if mv then firePlan(mv, total, chain) else wait() end
    end
    self._substate = nil
    if self._bigGarbageGame then
      -- ================= DIG-ONLY MODE (Brian 2026-07-02): only the large-garbage solve mechanics =================
      -- BREAK -> CATCH -> SETUP -> POSTURE, nothing else: no chain organize, no offense planning, no raise-to-build.
      -- Gated deliberately minimal while each mechanic is proven out (PA_MECH counters). Two mechanics the generic
      -- tree lacked: (1) when the block hangs on ONE tall column (jagged landing) no staged 3 can touch it -- CLEAR
      -- anything so the support drops and the block descends onto the braced flat surface; (2) the lull must HOLD a
      -- flat 3-4 high surface (clearing only against the rise), not strip the board bare (seed 1002/1003: braced to
      -- height ~2, zero possible breaks, 0 broken).
      if breaking then
        local catch = self:tryCatch(grid, rows, stack, priorities, verify, touchable)
        if catch and catch.ready then
          self._substate = "CATCH_READY"; move = { type = "WAIT" }  -- a column is fully set up -- HOLD. Falling through to clear/flatten here was the bug: it could disturb the pair before the drop lands.
        elseif catch then
          self._substate = "CATCH"; move = { type = "SWAP", pos = catch.swaps[1], swaps = catch.swaps, kind = catch.kind }
        else local cl = clearChip(false, true)
          if cl then fireChip(cl, "CLEAR")
          else local fl = catchPrimitive.flattenMove(grid, rows, touchable)
            if fl then fireSwap(fl, "FLATTEN") else wait() end
          end
        end
      elseif state.lowestGarbageRow then
        -- POP NOW when the clock is bare: with garbage over the top, health drains EVERY still frame once
        -- stop_time hits 0 (Stack:advancePassiveRaise) -- a multi-swap dig plan mid-assembly is death if nothing
        -- is popping (measured seed 1005: died ~50f after landing, 3 DIG_PLAN setup swaps deep, zero pops in
        -- flight). When no pops are active and the banked stop is thinner than one cursor trip, the next swap
        -- must ITSELF pop: take any immediate clear over the otherwise-preferred multi-swap setups.
        if (not busy) and (stack.stop_time or 0) <= 45 and (stack.shake_time or 0) == 0 then
          -- exactFallback=true: at stop 0 ANY pop beats a still frame, including the pull-into-empty 1-swap clears
          -- the catalog can't see (bot/useChips.lua exactOneSwap -- opt-in, engine-exact via simSwap).
          local pop = clearChip(true, true, nil, POPNOW_PRIORITIES, true) or clearChip(false, true, nil, POPNOW_PRIORITIES, true)
          if pop then fireChip(pop, "CLEAR") end
        end
        if move then -- POP-NOW fired above
        else
        local bc = clearChip(true, true)                                   -- a ready clear that pops the block
        if bc then fireChip(bc, "CLEAR")
        else local br = catchPrimitive.breakRoute(grid, rows, touchable)   -- finish a contact-column vertical-3
          if br then fireSwap(br, "BREAK_ROUTE")
          else
            -- DIG PLAN: beam-search a 1-3 swap sequence that BREAKS garbage (any match touching the block, not just
            -- the rigid contact-column vertical-3 / rowBreak shapes). This planner existed but was never wired into
            -- the dig-only tree -- exactly the tool for the first-landing boards where every contact column is a
            -- dead end (no in-row donor) yet a 2-swap setup break exists. Budget-bounded (1200 sims); only the
            -- first move is returned and it's re-planned each decision, so a shifting board self-corrects.
            local dp = BoardSim.digPlan(grid, rows, 3)
            if dp and touchable[dp[1]] and touchable[dp[1]][dp[2]] and touchable[dp[1]][dp[2] + 1] then
              fireSwap(dp, "DIG_PLAN")
            else local cl = clearChip(false, true)                         -- activity + SUPPORT CLEARING: the block falls as its supports go
              if cl then fireChip(cl, "CLEAR")
              else local tg = catchPrimitive.stageContact(grid, rows, touchable) or catchPrimitive.stageTrigger(grid, rows, touchable)  -- RE-COCK the contact column between breaks (cocked seeds got exactly ONE break then stalled)
                if tg then fireSwap(tg, "DIG_TRIGGER")
                else local mv, total, chain = useChips.planMove(grid, rows, touchable, cursor, true, false)  -- ASSEMBLE a clear via setup swaps (no ready clear + no finishable break = the only path to dropping the block's supports)
                  if mv then firePlan(mv, total, chain)
                  else local fl = catchPrimitive.flattenMove(grid, rows, touchable)
                    if fl then fireSwap(fl, "FLATTEN") else wait() end
                  end
                end
              end
            end
          end
        end
        end -- POP-NOW wrapper
      else
        -- LULL POSTURE: hold a FLAT, 3-4 high, trigger-cocked surface. Clear only to fight the rise (maxH>=5); below
        -- that HOLD material -- the staged 3s must be able to reach the landing block's bottom row.
        -- CONTACT FIRST: at L10 the lull clear rate can only match the rise (~one 3-clear per rise row), never beat it
        -- -- boards hover at height 4-7 no matter what, so "get short, then posture" means posture NEVER runs (measured:
        -- seed 1001's whole lull was PLAN, zero staging decisions, 0 breaks). The break mechanic doesn't need a short
        -- board -- it needs a cocked trigger in the CONTACT column at whatever height the board is. Stage that first,
        -- every time it degrades; fight the rise with the remaining frames.
        -- SHIELD the staged material from our own clears (LULL ONLY -- shielding the sealed/breaking dig clears was
        -- measured 2s WORSE on the 10-seed median: the digger needs those cells). Any intact top PAIR (and its
        -- cocked trigger cell) is off-limits to clear/plan/flatten here; staging mechanics see the plain mask.
        -- Measured: without this, staging was rebuilt and re-mined by PLAN/CLEAR all lull long and 9/10 seeds
        -- arrived at the first landing with cocked=0 (median 12.2s); with it, 6/10 arrive cocked (median 18.4s).
        local lullMode = EnvelopeBrain.LULL_SUPPORT_SHIELD
        local shielded = EnvelopeBrain.lullShield(grid, rows, touchable,
          lullMode == 1 or (lullMode == 2 and pendingBig >= 3))
        -- mode 3 SOFT: the pair shield above stays plain; a second, support-LOCKED mask is only the CLEAR
        -- first-preference (fallback keeps throughput), and its stage columns become planMove's soft sink cost.
        local hardShield, stageCols
        if lullMode == 3 then hardShield, stageCols = EnvelopeBrain.lullShield(grid, rows, touchable, true) end
        local floorPref = EnvelopeBrain.LULL_FLOOR_CLEAR > 0
          and EnvelopeBrain.floorMask(grid, rows, hardShield or shielded, EnvelopeBrain.LULL_FLOOR_CLEAR) or nil
        -- REBUILD MATERIAL FIRST on a stripped board: a finished dig consumes the board (measured seed 1008: block 1
        -- fully broken, then the lull arrived at avgH 2.3 with two EMPTY columns and block 2 was unbreakable). RAISE
        -- is by far the fastest material source (a full 6-panel row per commit); waiting for it as the last resort
        -- behind buildPair meant it never rebuilt in the short inter-block window. Hold it off while a block is in
        -- transit (pendingBig) and once the stack is tall enough that height itself is the risk.
        if avgH < 3.5 and pendingBig < 3 and totalHeight < top - 5 and not busy then
          self._substate = "RAISE"; move = { type = "RAISE" }
        else
        local ct = catchPrimitive.stageContact(grid, rows, touchable)
        if ct then fireSwap(ct, "BRACE_CONTACT")
        else local cl = (height >= 5 and avgH >= 3) and ((floorPref and clearChip(false, true, floorPref)) or (hardShield and clearChip(false, true, hardShield)) or clearChip(false, true, shielded)) or nil  -- avgH floor: keep enough material for a contact trio (a stripped board can't break anything -- seed 1001 got mined to avgH 1.3, 0 breaks). mode 3: prefer a clear that spares the stage support, fall back to any clear; PA_FLOORCLEAR adds a first preference that also spares short columns
          if cl then fireChip(cl, "CLEAR")
          else local mv, total, chain
            if height >= 5 and avgH >= 3 then
              local softOpts = nil
              if stageCols or EnvelopeBrain.LULL_FLOOR > 0 then
                softOpts = { sinkCols = stageCols, sinkW = EnvelopeBrain.SINK_W,
                             floorH = EnvelopeBrain.LULL_FLOOR, floorW = EnvelopeBrain.FLOOR_W }
              end
              mv, total, chain = useChips.planMove(grid, rows, shielded, cursor, true, false, softOpts)
            end
            if mv then firePlan(mv, total, chain)
            else local fl = catchPrimitive.flattenMove(grid, rows, shielded)
              if fl then fireSwap(fl, "FLATTEN")
              else local tg = catchPrimitive.stageTrigger(grid, rows, touchable)
                if tg then fireSwap(tg, "BRACE_TRIGGER")
                else local bp = catchPrimitive.buildPair(grid, rows, touchable)
                  if bp then fireSwap(bp, "BRACE_PAIR")
                  elseif avgH < 2.5 and not busy then self._substate = "RAISE"; move = { type = "RAISE" }  -- material floor: an empty board can't break anything
                  else wait() end
                end
              end
            end
          end
        end
        end
      end
    else
    -- GARBAGE LINEUP: while a block is breaking or sealed, if the freed/standing panels already set up a real CASCADE,
    -- FIRE it. In garbage we can't ride the board up to organize a deeper chain (no headroom), so we take the cascade the
    -- breaks handed us. depth>=3 = a genuine multi-link chain, strictly better than a topoff-3.
    local gcb = (breaking or state.lowestGarbageRow) and chainBest(self._bigGarbageGame)
    if gcb and gcb.depth >= 3 then fireSwap({ gcb.r, gcb.c }, "CHAIN")
    elseif breaking then
      -- A. BREAKING: my garbage is popping. Do NOT break/swap into the active cascade -- it steals panels the engine would
      -- have cascaded for free (breaking mid-pop measured WORSE: median 35.4->26.9). Let it run; the catch lines up freed
      -- panels (situational, net-positive), else clear, else flatten so the NEXT settled break lands flat.
      local catch = self:tryCatch(grid, rows, stack, priorities, verify, touchable)
      if catch and catch.ready then
        self._substate = "CATCH_READY"; move = { type = "WAIT" }  -- a column is fully set up -- HOLD, don't disturb it (see the dig-only branch for the traced bug this fixes)
      elseif catch then
        self._substate = "CATCH"; move = { type = "SWAP", pos = catch.swaps[1], swaps = catch.swaps, kind = catch.kind }
      else local cl = clearChip(false)
        if cl then fireChip(cl, "CLEAR")
        else local fl = catchPrimitive.flattenMove(grid, rows, touchable)
          if fl then fireSwap(fl, "FLATTEN") else planFallback() end
        end
      end
    elseif state.lowestGarbageRow then
      -- B. SEALED garbage: commit to removing the block -- break it, or flatten ONLY to enable the break.
      -- ORDER (L10 physics): while garbage is at the ceiling the drain pauses ONLY during activity (rise_lock: popping/
      -- falling/swapping) or banked stop time -- and stop time comes ONLY from 4+ combos and chains, never plain 3s.
      -- So any CLEAR beats FLATTEN here: a clear keeps the board active and may bank stop; a flatten swap followed by a
      -- still board is a death frame. Flatten is the last resort before plan, not the first fallback.
      local bc = clearChip(true, true)                                    -- a ready clear that pops the block (incl a COMBO_3 break+clear)
      if bc then fireChip(bc, "CLEAR")
      else local br = catchPrimitive.breakRoute(grid, rows, touchable)    -- route to complete the vertical-3 next to it
        if br then fireSwap(br, "BREAK_ROUTE")
        else local cl = clearChip(false, true)                            -- any clear: activity + height drop while we set up the break
          if cl then fireChip(cl, "CLEAR")
          else local fl = catchPrimitive.flattenMove(grid, rows, touchable) -- break unreachable -> flatten to ENABLE it
            if fl then fireSwap(fl, "FLATTEN") else planFallback() end
          end
        end
      end
    elseif self._bigGarbageGame and st ~= "DANGER" then
      -- B2. BRACE (big-garbage game, board currently clean): a tall block is inbound or will be. Get SHORT (every ready
      -- clear incl 3s drops height = margin), get FLAT (a level surface gives the block 6 contact columns instead of 1 --
      -- the jagged-landing death), keep a vertical pair staged at the surface (one swap completes a 3 touching the block
      -- the moment it lands). No raising, no chain organizing -- everything is posture for the next landing.
      -- st == "DANGER" falls through to C: the passive rise still climbs during BRACE (measured: a buildPair toggle rode
      -- the rise into a self-topout at 97s) -- near the ceiling, clearing outranks posture.
      local cl = clearChip(false, true)
      if cl then fireChip(cl, "CLEAR")
      else local fl = catchPrimitive.flattenMove(grid, rows, touchable)
        if fl then fireSwap(fl, "FLATTEN")
        elseif avgH >= 5 then
          -- TALL lull (no garbage yet, rise climbing): chase a clear BEFORE posture -- the plan-first order is what got
          -- the injection-off baseline to the 300s cap; unconditional it cost the landings, so it only runs when tall.
          local mv, total, chain = useChips.planMove(grid, rows, touchable, cursor, true, false)
          if mv then firePlan(mv, total, chain)
          else local tg = catchPrimitive.stageTrigger(grid, rows, touchable)
            if tg then fireSwap(tg, "BRACE_TRIGGER")
            else local bp = catchPrimitive.buildPair(grid, rows, touchable)
              if bp then fireSwap(bp, "BRACE_PAIR") else wait() end
            end
          end
        else local tg = catchPrimitive.stageTrigger(grid, rows, touchable)  -- cock a 1-slide break next to an existing pair (the guaranteed first break)
          if tg then fireSwap(tg, "BRACE_TRIGGER")
          else local bp = catchPrimitive.buildPair(grid, rows, touchable)
            if bp then fireSwap(bp, "BRACE_PAIR")
            else local mv, total, chain = useChips.planMove(grid, rows, touchable, cursor, true, false)
              if mv then firePlan(mv, total, chain) else wait() end
            end
          end
        end
      end
    else
      -- C. NO garbage: the height state decides.
      if st == "DANGER" then
        local cb = chainBest()
        if cb and cb.depth >= 2 then fireSwap({ cb.r, cb.c }, "CHAIN")   -- fire the DEEPEST chain: its height drop is the escape (deeper than a flat combo)
        else local cl = clearChip(false, true)                           -- no chain set up -> clear ANYTHING (incl 3s) to drop height
          if cl then fireChip(cl, "CLEAR") else planFallback() end
        end
      elseif st == "RAISE" and not busy then
        self._substate = "RAISE"; move = { type = "RAISE" }              -- low material: fill the stack
      else                                                               -- OFFENSE: build toward a deep CHAIN, then fire it
        local cb = chainBest()
        if cb and cb.depth >= 6 then fireSwap({ cb.r, cb.c }, "CHAIN")   -- a deep chain is set up -> FIRE it
        else
          local org = self._endless and chainSim.organizeSwap(grid) or nil  -- PACK toward a deeper chain (1-move greedy). ENDLESS only: in garbage the organize rides the board up but garbage interrupts (10s waves) before a chain is ready to fire -> topout. Garbage needs a different shape.
          if org then fireSwap({ org.r, org.c }, "ORGANIZE")
          elseif cb and cb.depth >= 2 then fireSwap({ cb.r, cb.c }, "CHAIN")  -- organize PLATEAUED -> FIRE the chain we built (don't abandon it to combos -- that was 45% wasted), then rebuild
          else local cl = clearChip(false, not self._endless)            -- ENDLESS: hold 3-clears (build a chain). GARBAGE: FIRE them -- clears the passive rise, keeps us low.
            if cl then fireChip(cl, "CLEAR")
            else local fl = (not self._endless) and catchPrimitive.flattenMove(grid, rows, touchable) or nil  -- GARBAGE: LEVEL during the lull (only fires on a step>=2) so the block lands FLAT across all columns -> 6 break points, not the lopsided 1-column landing that stalls the break ~6s.
              if fl then fireSwap(fl, "FLATTEN")
              else local mv, total, chain = useChips.planMove(grid, rows, touchable, cursor, false, true)
                if mv then firePlan(mv, total, chain)
                elseif not busy and safeToRaise then self._substate = "RAISE"; move = { type = "RAISE" }
                else local bp = catchPrimitive.buildPair(grid, rows, touchable)  -- idle last-resort lock pre-lay (secondary). buildPair AHEAD of clearing rides the rise up. Keep it last.
                  if bp then fireSwap(bp, "BUILDPAIR") else wait() end
                end
              end
            end
          end
        end
      end
    end
    end -- dig-only / generic tree split
    -- HEARTBEAT: the L10 death condition is ONE still frame while garbage is at the ceiling with stop_time 0
    -- (maxHealth=1). If the whole tree came up WAIT with garbage on the board, make a harmless DISTINCT swap instead:
    -- two different-colored settled panels in the same row -- a pure permutation (no gravity, no structure change).
    -- Distinct swaps are legal play (WigglePay only punishes repeating the exact same reversal to stall); every swap in
    -- flight keeps rise_lock up. The rotating anchor makes consecutive heartbeats hit different cells, never a reversal.
    if move and move.type == "WAIT" and (breaking or state.lowestGarbageRow) then
      local W = BoardSim.WIDTH
      local total = rows * (W - 1)
      local start = self._hbIdx or 0
      for k = 0, total - 1 do
        local idx = (start + k) % total
        local r = math.floor(idx / (W - 1)) + 1
        local c = (idx % (W - 1)) + 1
        local a = (grid[r] and grid[r][c]) or 0
        local b = (grid[r] and grid[r][c + 1]) or 0
        if a ~= 0 and b ~= 0 and a ~= b and a ~= BoardSim.GARBAGE and b ~= BoardSim.GARBAGE
          and touchable[r] and touchable[r][c] and touchable[r][c + 1] then
          self._hbIdx = idx + 1
          self._substate = "HEARTBEAT"
          move = { type = "SWAP", pos = { r, c }, swaps = { { r, c } }, kind = "HEARTBEAT" }
          break
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
