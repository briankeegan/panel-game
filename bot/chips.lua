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
  return { tmpl = t, kind = "fire" }
end

-- RECOGNIZE + VERIFY: slide every chip; on a fit, the play is the swap at the fit anchor; VERIFY it fires; return the
-- first VERIFIED play. 100% precision by construction (a returned play always fires). nil = no guaranteed play here.
function chips.play(grid, rows)
  local top = BoardSim.maxHeight(grid, rows)
  local lo, hi = math.max(1, top - 6), math.min(top + 1, rows)
  for _, chip in ipairs(STORE) do
    for R = lo, hi do for C = 1, 5 do
      if fits(grid, rows, chip.tmpl, R, C) then
        local ok = fires(grid, rows, R, C)            -- the one-step verify
        if ok then return { r = R, c = C, kind = chip.kind } end
      end
    end end
  end
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
  local function bld(stack) local p = Puzzle({ puzzleType = "moves", stack = stack, moves = 1 }); local m = Match(p:toPanelSource(false), p:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    for i = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end return m, st end
  local function gridOf(st) return BoardSim.colorGrid(BoardState.extract(st).board, st.height), st.height end
  local function pan(st) local n = 0 for r = 1, st.height do for c = 1, 6 do local v = st.panels[r][c].color or 0; if v ~= 0 and v ~= 9 then n = n + 1 end end end return n end
  for i, e in ipairs(flat) do if i % 2 == 0 then local _, st = bld(e.p.stack); local g, rows = gridOf(st); local top = BoardSim.maxHeight(g, rows)
    for r = math.max(1, top - 6), math.min(top + 1, rows) do for c = 1, 5 do local ch = chips.authorFire(g, rows, r, c); if ch then chips.add(ch) end end end end end
  local n, played, fired = 0, 0, 0
  for i, e in ipairs(flat) do if i % 2 == 1 then n = n + 1 local _, st0 = bld(e.p.stack); local g, rows = gridOf(st0)
    local mv = chips.play(g, rows)
    if mv then played = played + 1 local _, st = bld(e.p.stack); local b = pan(st); st.cur_row, st.cur_col = mv.r, mv.c; st:receiveConfirmedInput(KDE.swap)
      local mm = select(1, bld(e.p.stack)) -- unused; keep match via st's own
      for k = 1, 200 do if st:game_ended() then break end st:receiveConfirmedInput("A") end
      -- re-run faithfully: rebuild and apply the move
      local m2, s2 = bld(e.p.stack); local bb = pan(s2); s2.cur_row, s2.cur_col = mv.r, mv.c; s2:receiveConfirmedInput(KDE.swap); m2:run()
      for k = 1, 200 do if s2:game_ended() then break end s2:receiveConfirmedInput("A"); m2:run() if k >= 5 and not s2:hasActivePanels() and not s2:hasChainingPanels() then break end end
      if pan(s2) < bb then fired = fired + 1 end end
  end end
  print(string.format("CHIPS (recognize+verify): %d chips | played on %d/%d boards | FIRED %d (%.0f%% precision)", chips.size(), played, n, fired, played > 0 and 100 * fired / played or 0))
  os.exit(0)
end

return chips
