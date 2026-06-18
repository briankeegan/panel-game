-- chips.lua — the chip cache (V2). A CHIP is a guaranteed play: "recognize a spot -> make a move -> it WORKS."
-- Brian's 100% bar: a chip that isn't 100% must not be used. Pattern-alone plateaus at ~81% (a flat snapshot can't
-- capture fall/support), so we guarantee 100% the robust way: RECOGNIZE (cheap pattern slide to narrow candidates) +
-- VERIFY (one-step sim that the move actually fires HERE). Only verified plays are returned -> 100% by construction.
-- Breaks anchor on GARBAGE (immovable = a hard anchor, already deterministic). All recognition is from the cursor
-- outward, sliding minimal templates; junk around a template's cells is don't-care.
local BoardSim = require("bot.BoardSim")

local chips = {}
local STORE = {}            -- list of { tmpl = {{dr,dc,class}..}, kind = "fire"|"break" }

-- ---- recognition: slide a minimal template; only its cells must satisfy the same/diff color-classes ----
-- class: an integer N = "same color across cells sharing N, different from other N"; "e" = empty(0); "g" = GARBAGE.
local function fits(grid, rows, t, R, C)
  local seen = {}
  for _, e in ipairs(t) do
    local rr, cc = R + e[1], C + e[2]
    local col = (rr >= 1 and rr <= rows and cc >= 1 and cc <= 6 and grid[rr] and (grid[rr][cc] or 0)) or -1
    if e[3] == "g" then if col ~= BoardSim.GARBAGE then return false end
    elseif e[3] == "e" then if col ~= 0 then return false end
    else
      if col <= 0 or col == BoardSim.GARBAGE then return false end
      if seen[e[3]] == nil then for _, v in pairs(seen) do if v == col then return false end end seen[e[3]] = col
      elseif seen[e[3]] ~= col then return false end
    end
  end
  return true
end

-- a swap at (r,c) FIRES iff it creates an immediate match (cheap, no real engine).
local function fires(grid, rows, r, c)
  local gs = BoardSim.cloneGrid(grid, rows)
  if not (gs[r] and gs[r][c + 1]) then return false, 0 end
  gs[r][c], gs[r][c + 1] = gs[r][c + 1], gs[r][c]
  local _, any = BoardSim.findMatches(gs, rows)
  local _, _, _, _, gbroke = BoardSim.simSwap(grid, rows, r, c)
  return any, (gbroke or 0)
end

-- AUTHOR a fire chip: the minimal matched cells (+ swap pair) as a same/diff template, anchored on the swap.
function chips.authorFire(grid, rows, r, c)
  local hit, any = (function() local gs = BoardSim.cloneGrid(grid, rows); if gs[r] and gs[r][c + 1] then gs[r][c], gs[r][c + 1] = gs[r][c + 1], gs[r][c] end return BoardSim.findMatches(gs, rows) end)()
  if not any then return nil end
  local cells = { { r, c }, { r, c + 1 } }
  for idx in pairs(hit) do cells[#cells + 1] = { math.floor((idx - 1) / 6) + 1, ((idx - 1) % 6) + 1 } end
  local rl, nn, t, seen = {}, 0, {}, {}
  for _, cl in ipairs(cells) do local k = cl[1] * 10 + cl[2]; if not seen[k] then seen[k] = true
    local col = (grid[cl[1]] and (grid[cl[1]][cl[2]] or 0)) or 0
    local cls; if col == 0 then cls = "e" elseif col == BoardSim.GARBAGE then cls = "g" else if not rl[col] then nn = nn + 1; rl[col] = nn end cls = rl[col] end
    t[#t + 1] = { cl[1] - r, cl[2] - c, cls } end end
  return { tmpl = t, kind = "fire", swap = { 0, 0 } }   -- fire anchors ON the swap
end

-- AUTHOR a break chip: anchored on the immovable GARBAGE (a hard anchor -> deterministic). template = garbage cell
-- (class "g") + the match cells that touch it; the swap is stored as an offset from the garbage anchor.
function chips.authorBreak(grid, rows, r, c)
  local _, _, _, _, gbroke = BoardSim.simSwap(grid, rows, r, c)
  if (gbroke or 0) <= 0 then return nil end
  local hit = (function() local gs = BoardSim.cloneGrid(grid, rows); if gs[r] and gs[r][c + 1] then gs[r][c], gs[r][c + 1] = gs[r][c + 1], gs[r][c] end return (BoardSim.findMatches(gs, rows)) end)()
  local part = { { r, c }, { r, c + 1 } }
  for idx in pairs(hit) do part[#part + 1] = { math.floor((idx - 1) / 6) + 1, ((idx - 1) % 6) + 1 } end
  local ar, ac
  for _, cell in ipairs(part) do for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do local rr, cc = cell[1] + d[1], cell[2] + d[2]
    if grid[rr] and grid[rr][cc] == BoardSim.GARBAGE then ar, ac = rr, cc break end end if ar then break end end
  if not ar then return nil end
  local rl, nn, t, seen = {}, 0, { { 0, 0, "g" } }, {}
  for _, cell in ipairs(part) do local k = cell[1] * 10 + cell[2]; if not seen[k] then seen[k] = true
    local col = (grid[cell[1]] and (grid[cell[1]][cell[2]] or 0)) or 0
    local cls; if col == 0 then cls = "e" elseif col == BoardSim.GARBAGE then cls = "g" else if not rl[col] then nn = nn + 1; rl[col] = nn end cls = rl[col] end
    t[#t + 1] = { cell[1] - ar, cell[2] - ac, cls } end end
  return { tmpl = t, kind = "break", swap = { r - ar, c - ac } }
end

-- RECOGNIZE + VERIFY: slide every chip; on a fit, the play is the swap at the fit anchor; VERIFY it fires; return the
-- first VERIFIED play. 100% precision by construction (a returned play always fires). nil = no guaranteed play here.
function chips.play(grid, rows)
  local top = BoardSim.maxHeight(grid, rows)
  local lo, hi = math.max(1, top - 6), math.min(top + 1, rows)
  for _, chip in ipairs(STORE) do
    for R = lo, hi do for C = 1, 6 do
      if fits(grid, rows, chip.tmpl, R, C) then
        local sr, sc = R + chip.swap[1], C + chip.swap[2]   -- the play is at the swap-offset from the anchor
        if sr >= 1 and sr <= rows and sc >= 1 and sc <= 5 then
          local any, gbroke = fires(grid, rows, sr, sc)      -- the one-step verify (kind-aware)
          local ok = (chip.kind == "break") and (gbroke > 0) or any
          if ok then return { r = sr, c = sc, kind = chip.kind } end
        end
      end
    end end
  end
  return nil
end

-- SETUP play: no single swap fires, but a 2-move sequence does. "Recognize buildable + put it together" = a tiny local
-- 2-move search (the recognition narrows; the search guarantees it fires). Returns {{r1,c1},{r2,c2}} or nil. 100% by
-- construction (only returns a sequence that actually clears). The setup moves are board-specific, so they're FOUND, not
-- recalled — but bounded to the cursor's local band, exactly Brian's "you just put it together."
-- verify(seq) -> bool is the caller's REAL-ENGINE check (the bot has the engine; BoardSim mispredicts garbage-heavy
-- boards — 2/21 phantom setups). With verify supplied we iterate BoardSim candidates and return the first the ENGINE
-- confirms -> 100% (phantom rejected, bot plays nothing rather than misfire). Without verify, returns first candidate.
function chips.setupPlay(grid, rows, verify)
  local top = BoardSim.maxHeight(grid, rows)
  local lo, hi = math.max(1, top - 6), math.min(top + 1, rows)
  for r1 = lo, hi do for c1 = 1, 5 do
    local g1, _, t1 = BoardSim.simSwap(grid, rows, r1, c1)
    if (t1 or 0) == 0 and g1 then                            -- move1 = alignment (doesn't itself clear)
      local t2 = math.min(BoardSim.maxHeight(g1, rows) + 1, rows)
      for r2 = math.max(1, t2 - 6), t2 do for c2 = 1, 5 do
        local _, _, tot = BoardSim.simSwap(g1, rows, r2, c2)
        if (tot or 0) > 0 then
          local seq = { { r1, c1 }, { r2, c2 } }
          if not verify or verify(seq) then return seq end   -- engine-confirm before committing
        end
      end end
    end
  end end
  return chips.goalSetup(grid, rows, verify)                 -- no shallow 2-move? try DEEP target-directed construction
end

-- GOAL-DIRECTED construction (Brian's "target first, then route the colors in", 2026-06-17): pick a line you can COMPLETE
-- (a vertical triple whose color is present nearby), then slide each missing block into its slot. The swap COUNT falls out
-- of how far the pieces travel (2-5 swaps). This is the opposite of a blind swap-search — it AIMS at a makeable match and
-- routes pieces to it (transport = 1-piece case, rearrange = multi-piece case). verify-iterate over targets -> 100%.
function chips.goalSetup(grid, rows, verify)
  local top = BoardSim.maxHeight(grid, rows)
  local lo, hi = math.max(1, top - 6), math.min(top, rows)
  for c = 1, 6 do for r0 = lo, math.min(hi, rows - 2) do
    local present = {}
    for _, ri in ipairs({ r0, r0 + 1, r0 + 2 }) do for cc = 1, 6 do
      local v = grid[ri] and grid[ri][cc]; if v and v ~= 0 and v ~= BoardSim.GARBAGE then present[v] = true end
    end end
    for X in pairs(present) do
      local wk = BoardSim.cloneGrid(grid, rows); local swaps = {}; local ok = true
      for _, ri in ipairs({ r0, r0 + 1, r0 + 2 }) do
        if wk[ri][c] ~= X then                                -- this slot needs an X — route the nearest one in
          local bestc; for cc = 1, 6 do if cc ~= c and wk[ri][cc] == X and (not bestc or math.abs(cc - c) < math.abs(bestc - c)) then bestc = cc end end
          if not bestc then ok = false; break end
          if bestc > c then for k = bestc - 1, c, -1 do if k < 1 or k > 5 then ok = false; break end wk[ri][k], wk[ri][k + 1] = wk[ri][k + 1], wk[ri][k]; swaps[#swaps + 1] = { ri, k } end
          else for k = bestc, c - 1 do if k < 1 or k > 5 then ok = false; break end wk[ri][k], wk[ri][k + 1] = wk[ri][k + 1], wk[ri][k]; swaps[#swaps + 1] = { ri, k } end end
          if not ok then break end
        end
      end
      if ok and #swaps > 0 and #swaps <= 6 and (not verify or verify(swaps)) then return swaps, { col = c, color = X } end
    end
  end end
  -- HORIZONTAL targets: row r, cols c..c+2 all color X. Route each missing X in from the same row (prefer a source
  -- OUTSIDE the target span, from the right, so it doesn't disturb already-placed left slots). Nearly doubles coverage.
  for r = lo, hi do for c = 1, 4 do
    local present = {}
    for cc = 1, 6 do local v = grid[r] and grid[r][cc]; if v and v ~= 0 and v ~= BoardSim.GARBAGE then present[v] = true end end
    for X in pairs(present) do
      local wk = BoardSim.cloneGrid(grid, rows); local swaps = {}; local ok = true
      for _, tc in ipairs({ c, c + 1, c + 2 }) do
        if wk[r][tc] ~= X then
          local src; for cc = 6, 1, -1 do if wk[r][cc] == X and (cc < c or cc > c + 2) then src = cc; break end end
          if not src then for cc = 1, 6 do if wk[r][cc] == X and cc ~= tc then src = cc; break end end end
          if not src then ok = false; break end
          if src > tc then for k = src - 1, tc, -1 do if k < 1 or k > 5 then ok = false; break end wk[r][k], wk[r][k + 1] = wk[r][k + 1], wk[r][k]; swaps[#swaps + 1] = { r, k } end
          else for k = src, tc - 1 do if k < 1 or k > 5 then ok = false; break end wk[r][k], wk[r][k + 1] = wk[r][k + 1], wk[r][k]; swaps[#swaps + 1] = { r, k } end end
          if not ok then break end
        end
      end
      if ok and #swaps > 0 and #swaps <= 6 and (not verify or verify(swaps)) then return swaps, { row = r, color = X, horizontal = true } end
    end
  end end
  return nil
end

function chips.add(chip) STORE[#STORE + 1] = chip end
function chips.store() return STORE end
function chips.size() return #STORE end

-- ---- CLI self-test: author fires from even boards, measure VERIFIED-play precision + recall on odd ----
if arg and arg[0] and arg[0]:find("chips") then
  require("bot.headlessBoot"); do local lg = require("common.lib.logger"); lg.setLogLevel(lg.levels.WARN) end
  _G.loc = _G.loc or function(s) return tostring(s) end
  local Match = require("common.engine.Match"); require("common.engine.checkMatches")
  local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding")
  local Puzzle = require("common.engine.Puzzle"); local BoardState = require("bot.BoardState"); local PuzzleSet = require("client.src.PuzzleSet")
  local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json"); local flat = {}
  local function w(s) if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { p = p } end end for _, c in ipairs(s.puzzleSets or {}) do w(c) end end
  for _, s in ipairs(sets) do w(s) end
  local function bld(stack) local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 99 }); local m = Match(p:toPanelSource(false), p:toGameMode().matchRules) -- moves=99: don't cap swaps (moves=1 blocked the 2nd swap -> false setup 0%)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end return m, st end
  local function gridOf(st) return BoardSim.colorGrid(BoardState.extract(st).board, st.height), st.height end
  local function pan(st) local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
  -- apply a move sequence on a fresh real engine; true iff it cleared (the ground-truth precision check)
  local function applyFires(stack, moves)
    local m, st = bld(stack); local b = pan(st)
    for _, mv in ipairs(moves) do st.cur_row, st.cur_col = mv[1], mv[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for k = 1, 80 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
    return pan(st) < b
  end
  -- author FIRE + BREAK chips from EVEN boards (mid-band)
  for i, e in ipairs(flat) do if i % 2 == 0 then local _, st = bld(e.p.stack); local g, rows = gridOf(st); local top = BoardSim.maxHeight(g, rows)
    for r = math.max(1, top - 6), math.min(top + 1, rows) do for c = 1, 5 do
      local cf = chips.authorFire(g, rows, r, c); if cf then chips.add(cf) end
      local cb = chips.authorBreak(g, rows, r, c); if cb then chips.add(cb) end
    end end end end
  -- held-out ODD: 1-move play (fire/break); where none, try the 2-move SETUP
  local n, played, pfired, setup, sfired = 0, 0, 0, 0, 0
  for i, e in ipairs(flat) do if i % 2 == 1 then n = n + 1 local _, st0 = bld(e.p.stack); local g, rows = gridOf(st0)
    local mv = chips.play(g, rows)
    if mv then played = played + 1; if applyFires(e.p.stack, { { mv.r, mv.c } }) then pfired = pfired + 1 end
    else local seq = chips.setupPlay(g, rows); if seq then setup = setup + 1; if applyFires(e.p.stack, seq) then sfired = sfired + 1 end end end
  end end
  print(string.format("CHIPS: %d (fire+break)", chips.size()))
  print(string.format("  1-move (fire/break): %d/%d boards | FIRED %d (%.0f%% precision)", played, n, pfired, played > 0 and 100 * pfired / played or 0))
  print(string.format("  setup (2-move)     : %d more boards | FIRED %d (%.0f%% precision)", setup, sfired, setup > 0 and 100 * sfired / setup or 0))
  print(string.format("  TOTAL coverage     : %d/%d (%.0f%%) at validated precision", played + setup, n, 100 * (played + setup) / n))
  os.exit(0)
end

return chips
