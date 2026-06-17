-- liveRecognize.lua — B-track. LIVE fire-site recognition for the timing FSM (chainReady/breakReady) and cache recall.
-- A bare live board has no solution, so we can't derive participating regions by replay (that's authoring). Instead
-- enumerate the swaps that actually FIRE — clear, chain, or break garbage — via BoardSim (cheap, no real engine).
-- This is the primitive A asked for (A2 + the breakReady the FSM currently stubs false). Two uses:
--   FSM gates: `chainReady` = a chain fires now; `breakReady` = a garbage break fires now; `comboReady` = any clear.
--   Cache recall: each site carries its (r,c) + what it cleared → the participating region (now known) to key the STORE.
-- Convention: BoardSim grid (row 1 = floor; real garbage = BoardSim.GARBAGE sentinel). simSwap returns
--   (newGrid, chain, total, firstClear, garbageCleared) — we read chain / total / garbageCleared.
local BoardSim = require("bot.BoardSim")

local M = {}

-- scan the active band for fire sites. opts.bandDepth = rows below the surface to consider (default 6).
-- returns { sites = {{r,c,chain,total,garbageCleared,kind}...}, chainReady, breakReady, comboReady, best=<site|nil> }
function M.scanFireSites(grid, rows, opts)
  opts = opts or {}
  local top = BoardSim.maxHeight(grid, rows)
  local lo = math.max(1, top - (opts.bandDepth or 6))
  local hi = math.min(top + 1, rows)
  local sites = {}
  local chainReady, breakReady, comboReady = false, false, false
  local best = nil
  for r = lo, hi do
    for c = 1, 5 do  -- a swap at col c swaps c,c+1 (cols 1..6) so c in 1..5
      local newg, chain, total, _, garbageCleared = BoardSim.simSwap(grid, rows, r, c)
      chain = chain or 0; total = total or 0; garbageCleared = garbageCleared or 0
      if total > 0 or chain > 0 or garbageCleared > 0 then
        local kind = (garbageCleared > 0) and "break" or (chain >= 2 and "chain" or "combo")
        -- participating cells for A2 cache keying: the swap pair + cells that emptied (estimate; includes some
        -- fall-vacated cells, but for small tactics the footprint is tight). A bbox+canonShapes this to match the STORE.
        local cells = { { r, c }, { r, c + 1 } }
        if newg then for rr = 1, rows do for cc = 1, 6 do if (grid[rr][cc] or 0) ~= 0 and (newg[rr] and (newg[rr][cc] or 0) == 0) then cells[#cells + 1] = { rr, cc } end end end end
        local site = { r = r, c = c, chain = chain, total = total, garbageCleared = garbageCleared, kind = kind, cells = cells }
        sites[#sites + 1] = site
        if chain >= 2 then chainReady = true end
        if garbageCleared > 0 then breakReady = true end
        if total > 0 then comboReady = true end
        -- "best" = deepest chain, then most garbage broken, then biggest clear (the FIRE/BREAK pick).
        if not best or chain > best.chain or (chain == best.chain and garbageCleared > best.garbageCleared)
           or (chain == best.chain and garbageCleared == best.garbageCleared and total > best.total) then
          best = site
        end
      end
    end
  end
  return { sites = sites, chainReady = chainReady, breakReady = breakReady, comboReady = comboReady, best = best }
end

-- convenience for the FSM: just the booleans (cheap if A only needs the gates).
function M.readiness(grid, rows, opts)
  local r = M.scanFireSites(grid, rows, opts)
  return r.chainReady, r.breakReady, r.comboReady, r.best
end

-- ---- CLI self-test: scan combo/chain puzzle boards, confirm fire sites are detected ----
if arg and arg[0] and arg[0]:find("liveRecognize") then
  require("bot.headlessBoot")
  do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
  _G.loc = _G.loc or function(s) return tostring(s) end
  local PuzzleSet = require("client.src.PuzzleSet")
  local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
  local flat = {}
  local function walk(s) if s.puzzles then for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end end for _, c in ipairs(s.puzzleSets or {}) do walk(c) end end
  for _, s in ipairs(sets) do walk(s) end
  local function stackToGrid(stack)
    if #stack < 72 then stack = string.rep("0", 72 - #stack) .. stack end
    local rows = 12; local g = {}
    for r = 1, rows do g[r] = {} for c = 1, 6 do g[r][c] = 0 end end
    for i = 1, #stack do local d = tonumber(stack:sub(i, i)) or 0; local idx = i - 1; local r = rows - math.floor(idx / 6); local c = (idx % 6) + 1
      if g[r] then g[r][c] = (d == 9) and BoardSim.GARBAGE or d end end
    return g, rows
  end
  local n, withSite = 0, 0
  for _, e in ipairs(flat) do
    if (e.set or ""):lower():find("combos", 1, true) and n < 14 then
      n = n + 1
      local g, rows = stackToGrid(e.puzzle.stack)
      local r = M.scanFireSites(g, rows)
      if #r.sites > 0 then withSite = withSite + 1 end
      print(string.format("  %-18s sites=%d chainReady=%s comboReady=%s breakReady=%s  best=%s",
        (e.set or ""):gsub("puzzle_set_name_", ""):sub(1, 18), #r.sites, tostring(r.chainReady), tostring(r.comboReady),
        tostring(r.breakReady), r.best and string.format("(%d,%d)%s", r.best.r, r.best.c, r.best.kind) or "none"))
    end
  end
  print(string.format("liveRecognize self-test: %d/%d combo boards have a detected fire site", withSite, n))
  os.exit(0)
end

return M
