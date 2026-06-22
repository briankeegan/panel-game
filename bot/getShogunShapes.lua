-- getShogunShapes.lua — SHOGUN chips: a single-color clearing run finished by a real colored panel that FALLS THROUGH
-- BREAKING GARBAGE into a gap, instead of being delivered by a swap. The garbage is the trapdoor; the FALLING state is
-- the trigger (not part of the shape). For every single-color RUN geometry and every cell a faller can reach, remove
-- that cell (the gap), put garbage over it, rest a faller of the run color on the garbage, make the gap 2-DEEP (so the
-- freed grey debris drops clear and the real colored faller lands on the run row), and add a dedicated break-match in
-- reserved columns off to the side (the chip's move is the swap that fires that break). Verify on the ENGINE: garbage
-- breaks -> faller drops in -> run fires as a chain. Render in catalog notation extended with G (garbage). Don't-care if
-- it makes a bigger run; only that it doesn't match before the drop lands.
--   luajit bot/getShogunShapes.lua            -- print every verified shogun shape
--
-- Geometry notes (engine-verified):
--  * HORIZONTAL runs work: the faller column is open all the way down to a 2-deep gap, so the grey debris falls clear
--    and the colored faller lands on the run row. Runs 3/4/5 fit (run cols + a 4-wide B-B-X-B break gadget in the row
--    above the full-width garbage, avoiding the faller column). A 6-wide run is SKIPPED — no room for the gadget.
--  * VERTICAL runs are INFEASIBLE by geometry: the run cells fill the faller's column below the gap, so the freed grey
--    debris has nowhere to drop clear (the 1-deep "G 1 1, no match" trap). Reported, not enumerated.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Puzzle = require("common.engine.Puzzle"); local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
local M = {}

local H, W = 12, 6
local COLOR = 1                  -- the run color (faller + run cells)
local BREAK = 2                  -- the dedicated break-gadget color (!= COLOR)
local OTHER = 3                  -- the break gadget's swap-in spacer color (!= COLOR, != BREAK)
local WALL = 9                   -- non-matching blocker (color-9 = puzzle blocker; supports the structure, never matches)
local LIFT = 2                   -- raise the structure so the run row sits high enough for a 2-deep gap beneath

------------------------------------------------------------------ engine board <-> stack string (with garbage splice)
-- Render the grid to a Puzzle stack string, splicing a 1-row garbage block spanning garbLo..garbHi at garbRow. A garbage
-- of columns lo..hi is the chars '[' + '='*(hi-lo-1) + ']' (each bracket char = one column; see PuzzleSource).
local function stackWithGarbage(g, garbRow, garbLo, garbHi)
  local maxR = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then maxR = math.max(maxR, r) end end end
  maxR = math.max(maxR, garbRow)
  local rows = {}
  for r = maxR, 1, -1 do
    local row, c = {}, 1
    while c <= W do
      if r == garbRow and c == garbLo then
        row[#row+1] = "[" .. string.rep("=", garbHi - garbLo - 1) .. "]"
        c = garbHi + 1
      else
        row[#row+1] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0"; c = c + 1
      end
    end
    rows[#rows+1] = table.concat(row)
  end
  return table.concat(rows)
end
local function cnt(st, col) local n = 0; for r = 1, st.height do for c = 1, W do if (st.panels[r][c].color or 0) == col then n = n + 1 end end end return n end

-- Verify on the ENGINE. runCount = COLOR cells present before the break (= run cells + 1 faller). Returns chain depth
-- (>0 = fired correctly), or 0 on any gate failure. breakSwap = {row,col}.
--   (a) no pre-match  (b) doesn't break before it touches (idle frames keep the run un-fired + faller present)
--   (c) after the break the run fires and ALL run-color cells (run + faller) clear.
local function verify(g, garbRow, garbLo, garbHi, breakSwap, runCount, buffer)
  local ok, res = pcall(function()
    local stack = stackWithGarbage(g, garbRow, garbLo, garbHi)
    local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 1, garbagePanelBuffer = buffer })
    local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    for i = 1, 4 do st:receiveConfirmedInput("A"); m:run() end             -- (a)+(b): settle idle, run must NOT fire
    if cnt(st, COLOR) ~= runCount then return 0 end
    st.cur_row, st.cur_col = breakSwap[1], breakSwap[2]; st:receiveConfirmedInput(KDE.swap); m:run()
    local maxch = 0
    for k = 1, 240 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if (st.chain_counter or 0) > maxch then maxch = st.chain_counter end end
    if cnt(st, COLOR) ~= 0 then return 0 end                               -- (c): the whole run cleared
    return maxch
  end)
  return ok and res or 0
end

-- A gap position is only a real shogun if the STANDING cells (run minus the gap) contain NO contiguous run of >= 3:
-- otherwise that sub-run fires on its own the moment the board activates (the faller is irrelevant), and its debris
-- buries the rest — violating "the run fires ONLY because of the delivered faller". For a horizontal run 1..L with the
-- gap at gapCol, the two arms are length gapCol-1 and L-gapCol; both must be <= 2.
local function gapSplitsRun(L, gapCol) return (gapCol - 1) <= 2 and (L - gapCol) <= 2 end

------------------------------------------------------------------ build one HORIZONTAL shogun (run width L, gap at col)
-- Returns grid, garbRow, garbLo, garbHi, breakSwap, runCount, gadget  — or nil, reason.
-- Layout (lifted by LIFT): the run row holds the standing run cells (COLOR) at cols 1..L except the gap; the gap column
-- is empty 2-deep. Garbage is one row above, FULL WIDTH (it covers the gap AND the gadget). The faller (COLOR) sits on
-- the garbage above the gap.
-- BREAK GADGET — a VERTICAL 3-stack of BREAK in a reserved column `gb`, whose TOP cell arrives via a horizontal swap
-- from the column to its left (`gb-1`). Pre-placed: BREAK at fallerRow & fallerRow+1 of `gb`; BREAK at fallerRow+2 of
-- `gb-1` with OTHER at fallerRow+2 of `gb`; the swap (fallerRow+2, gb-1) slides the BREAK over, completing a vertical
-- B/B/B in `gb` whose bottom cell sits on the garbage -> the match touches and breaks it. Needs only 2 columns
-- (`gb`,`gb-1`), both clear of the faller — so it fits even centre-gap runs the 4-wide gadget couldn't.
local function buildHorizontal(L, gapCol)
  if not gapSplitsRun(L, gapCol) then return nil, "standing cells form a >=3 run (fires without the faller)" end

  local runRow = 1 + LIFT
  local garbRow = runRow + 1
  local fallerRow = garbRow + 1

  -- reserve gadget column `gb` (rightmost free) + its swap-source `gb-1`, both != the faller (gap) column.
  local gb
  for c = W, 2, -1 do if c ~= gapCol and c - 1 ~= gapCol then gb = c; break end end
  if not gb then return nil, "no 2-col break gadget fits clear of the faller column" end
  local gs = gb - 1                                          -- swap-source column

  local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end

  -- run row: COLOR at every run column except the gap; gap column empty
  for c = 1, L do if c ~= gapCol then g[runRow][c] = COLOR end end

  -- walls below the run row across the whole width, EXCEPT the gap column which stays empty at runRow-1 (the 2nd deep
  -- cell) so the freed grey debris falls clear of the run.
  for c = 1, W do
    for r = 1, runRow - 1 do
      if not (c == gapCol and r == runRow - 1) then g[r][c] = WALL end
    end
  end

  -- faller: a real COLOR panel on the garbage, directly above the gap column
  g[fallerRow][gapCol] = COLOR

  -- vertical break gadget in column gb (bottom two pre-placed on the garbage) + the swap-in third from column gs
  g[fallerRow][gb]     = BREAK
  g[fallerRow + 1][gb] = BREAK
  g[fallerRow + 2][gb] = OTHER                               -- swapped OUT, replaced by the BREAK from gs
  g[fallerRow + 2][gs] = BREAK
  -- the swap-source column must be solid up to the swap row so its BREAK rests there (and doesn't fall through)
  for r = 1, fallerRow + 1 do if g[r][gs] == 0 then g[r][gs] = WALL end end
  local breakSwap = { fallerRow + 2, gs }                    -- swap (gs<->gb) at the top: vertical B/B/B forms in gb

  local runCount = (L - 1) + 1                               -- standing run cells + faller
  return g, garbRow, 1, W, breakSwap, runCount, { gb = gb, gs = gs }
end

------------------------------------------------------------------ build one VERTICAL shogun (COLOR-RELEASE)
-- A 2-stack of COLOR at column `col`; full-width garbage one row above that RELEASES COLOR at `col` (grey elsewhere).
-- Breaking the garbage drops a COLOR panel into the gap on top of the stack -> vertical 3. No faller — the freed panel
-- IS the run color (this is why vertical, called "infeasible" under grey debris, works here). It's the ONLY vertical
-- shape: 3 stacked would pre-match, and the freed panel can only land on TOP (it can't fill a middle gap).
-- Returns grid, garbRow, garbLo, garbHi, breakSwap, runCount, buffer.
local function buildVertical(col)
  local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
  g[1][col] = COLOR; g[2][col] = COLOR                        -- the 2-stack
  for c = 1, W do for r = 1, 2 do if c ~= col then g[r][c] = WALL end end end  -- support the full-width garbage above
  local garbRow = 3
  local fallerRow = garbRow + 1                               -- gadget bottom rests here, on the garbage
  local gb; for c = W, 2, -1 do if c ~= col and c - 1 ~= col then gb = c; break end end
  if not gb then return nil, "no break gadget fits clear of the stack column" end
  local gs = gb - 1
  g[fallerRow][gb] = BREAK; g[fallerRow + 1][gb] = BREAK
  g[fallerRow + 2][gb] = OTHER; g[fallerRow + 2][gs] = BREAK
  for r = 1, fallerRow + 1 do if g[r][gs] == 0 then g[r][gs] = WALL end end
  local breakSwap = { fallerRow + 2, gs }
  local buf = {}; for c = 1, W do buf[c] = (c == col) and tostring(COLOR) or "9" end  -- release COLOR at col, grey else
  return g, garbRow, 1, W, breakSwap, 2, table.concat(buf)
end

------------------------------------------------------------------ enumerate
-- All verified horizontal shogun shapes for runs in `sizes`. Each result: { L, gap, chain, grid, garbRow, garbLo,
-- garbHi, breakSwap, gadget, mirrorOf }. Gaps right of center are MIRRORS of a left gap (the board reflects), so we
-- enumerate only gap <= floor((L+1)/2) and tag the reflected partner. 6-wide runs are skipped (no gadget room) and
-- every rejected (L,gap) is logged in `skipped` — nothing is silently dropped.
local function enumerateRaw(sizes)
  local out, skipped, infeasible = {}, {}, {}
  for _, L in ipairs(sizes) do
    local half = math.floor((L + 1) / 2)
    for gap = 1, L do
      local mirror = (L - gap + 1)                           -- the reflected gap column
      if gap > half then
        skipped[#skipped+1] = { L = L, gap = gap, reason = "mirror of gap@col" .. mirror }
      else
        local g, garbRow, garbLo, garbHi, breakSwap, runCount, gadget = buildHorizontal(L, gap)
        if not g then
          skipped[#skipped+1] = { L = L, gap = gap, reason = garbRow }   -- garbRow holds the reason string here
        else
          local chain = verify(g, garbRow, garbLo, garbHi, breakSwap, runCount)
          if chain > 0 then
            out[#out+1] = { L = L, gap = gap, chain = chain, grid = g, garbRow = garbRow, garbLo = garbLo,
                            garbHi = garbHi, breakSwap = breakSwap, gadget = gadget, runCount = runCount,
                            orient = "H", mirrorGap = (mirror ~= gap) and mirror or nil }
          else
            skipped[#skipped+1] = { L = L, gap = gap, reason = "did not verify on engine" }
          end
        end
      end
    end
  end
  -- VERTICAL shogun (color-release): one shape — a 2-stack topped by the freed COLOR panel.
  do
    local g, garbRow, garbLo, garbHi, breakSwap, runCount, buffer = buildVertical(1)
    if g then
      local chain = verify(g, garbRow, garbLo, garbHi, breakSwap, runCount, buffer)
      if chain > 0 then
        out[#out+1] = { L = 2, gap = 1, chain = chain, grid = g, garbRow = garbRow, garbLo = garbLo,
                        garbHi = garbHi, breakSwap = breakSwap, runCount = runCount, orient = "V" }
      else
        skipped[#skipped+1] = { L = 2, reason = "vertical color-release did not verify on engine" }
      end
    end
  end
  return { out = out, skipped = skipped, infeasible = infeasible }
end

-- persistent cache (one compute ever per size-set, until the generator or engine match-core changes)
function M.enumerate(sizes)
  local key = table.concat(sizes, "_")
  return require("bot.chipStore").memoEnum("getShogunShapes", key, function() return enumerateRaw(sizes) end)
end

------------------------------------------------------------------ render (catalog notation + G for garbage)
-- A 4-row filmstrip cropped to the active columns: faller row (faller + break gadget), garbage row, run row (gap + run
-- cells), and the 2nd empty cell below the gap (the debris-catch). 1=color, .=gap/empty, *=don't-care/support, G=garbage,
-- and the gadget is shown literally (2/3 = its two colors) with [..] marking the break swap.
-- Generic (orientation-agnostic): render the whole structure from the break-swap row down to the floor, cropped to the
-- active columns. garbage row = G, COLOR=1, BREAK=2, OTHER=3, WALL=*(support/blocker), empty=., [..] marks the break swap.
local function render(s)
  local g = s.grid
  local swapR, swapC = s.breakSwap[1], s.breakSwap[2]
  local topRow = swapR
  local lo, hi = s.garbLo, s.garbHi
  for r = 1, topRow do for c = 1, W do if g[r] and g[r][c] ~= 0 then lo = math.min(lo, c); hi = math.max(hi, c) end end end
  local function sym(r, c)
    if r == s.garbRow and c >= s.garbLo and c <= s.garbHi then return "G" end
    local v = g[r] and g[r][c] or 0
    if v == COLOR then return "1" elseif v == BREAK then return "2" elseif v == OTHER then return "3"
    elseif v == WALL then return "*" else return "." end
  end
  local rows = {}
  for r = topRow, 1, -1 do
    local toks = {}
    for c = lo, hi do
      local ch = sym(r, c)
      if r == swapR and (c == swapC or c == swapC + 1) then
        toks[#toks+1] = (c == swapC) and ("[" .. ch) or (ch .. "]")
      else
        toks[#toks+1] = " " .. ch .. " "
      end
    end
    rows[#rows+1] = "     " .. table.concat(toks)
  end
  return table.concat(rows, "\n")
end

------------------------------------------------------------------ standalone
local SIZES = { 3, 4, 5, 6 }
if arg and arg[0] and arg[0]:match("getShogunShapes%.lua$") then
  local res = M.enumerate(SIZES)
  print(string.format("SHOGUN shapes: %d verified  (1=run color drop · 2/3=break gadget · G=garbage · .=gap it lands in · *=don't-care/support · [..]=break swap)\n", #res.out))
  for i, s in ipairs(res.out) do
    local label
    if s.orient == "V" then
      label = string.format("#%d  vertical 2-stack (color-release)   break swap (%d,%d)   (chain %d)", i, s.breakSwap[1], s.breakSwap[2], s.chain)
    else
      local mir = s.mirrorGap and ("  (mirror: gap@col" .. s.mirrorGap .. ")") or ""
      label = string.format("#%d  horizontal run-%d  gap@col%d   break swap (%d,%d)   (chain %d)%s", i, s.L, s.gap, s.breakSwap[1], s.breakSwap[2], s.chain, mir)
    end
    print(label); print(render(s)); print("")
  end
  -- summary
  local byL, nV = {}, 0
  for _, s in ipairs(res.out) do if s.orient == "V" then nV = nV + 1 else byL[s.L] = (byL[s.L] or 0) + 1 end end
  print("---- summary ----")
  for _, L in ipairs(SIZES) do print(string.format("  horizontal-%d : %d verified", L, byL[L] or 0)) end
  print(string.format("  vertical     : %d verified  (color-release: freed panel tops the stack)", nV))
  print("")
  if #res.skipped > 0 then
    print("---- skipped ----")
    for _, sk in ipairs(res.skipped) do
      print(string.format("  run-%s%s : %s", tostring(sk.L), sk.gap and (" gap@col"..sk.gap) or "", sk.reason))
    end
    print("")
  end
  if #res.infeasible > 0 then
    print("---- infeasible (not enumerated) ----")
    for _, inf in ipairs(res.infeasible) do print(string.format("  %s run-%d : %s", inf.orient, inf.L, inf.reason)) end
  end
end

------------------------------------------------------------------ registry
local function produce()
  local out = {}
  for _, s in ipairs(M.enumerate(SIZES).out) do
    -- fire anchor = the gap cell on the run row (where the drop completes the line)
    out[#out+1] = { g = s.grid, sr = s.garbRow - 1, sc = s.gap, kind = "SHOGUN_" .. s.L,
                    absSwaps = { s.breakSwap }, garbage = { row = s.garbRow, lo = s.garbLo, hi = s.garbHi } }
  end
  return out
end
require("bot.chipRegistry").register{ name = "getShogunShapes", produce = produce }

return M
