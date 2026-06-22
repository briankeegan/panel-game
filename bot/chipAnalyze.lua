-- chipAnalyze.lua — fire a chip in the real engine ONCE and read off everything the metadata + the `@` blocker
-- classification need: what cleared (per color), the garbage it sends (captured straight from the engine's own
-- pushGarbage), the chain depth, and the timing (first pop / settled). No formula re-derivation — the engine is truth.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local Match = require("common.engine.Match"); require("common.engine.checkMatches")
local LP = require("common.data.LevelPresets"); local KDE = require("common.data.KeyDataEncoding"); local Puzzle = require("common.engine.Puzzle")
local W, H = 6, 12
local SETTLE = 3000   -- runaway guard only; early-break stops at the real settle (see split-cascade note)
local M = {}

-- the engine's combo-size -> garbage-block-widths table (mirror of checkMatches.lua COMBO_GARBAGE)
local COMBO_GARBAGE = { {}, {}, {}, {3}, {4}, {5}, {6}, {3,4}, {4,4}, {5,5}, {5,6}, {6,6}, {6,6,6}, {6,6,6,6},
                        [20] = {6,6,6,6,6,6}, [27] = {6,6,6,6,6,6,6,6} }
for i = 1, 72 do COMBO_GARBAGE[i] = COMBO_GARBAGE[i] or COMBO_GARBAGE[i-1] end

local function stackString(g)
  local mr = 0; for r = 1, H do for c = 1, W do if g[r][c] ~= 0 then mr = math.max(mr, r) end end end
  local rows = {}; for r = mr, 1, -1 do local row = {}; for c = 1, 6 do row[c] = (g[r][c] ~= 0) and tostring(g[r][c]) or "0" end; rows[#rows+1] = table.concat(row) end
  return table.concat(rows)
end

-- fire(g, absSwaps): play the swaps in order, return:
--   clears = {[color]=count} cleared (colors 1..4), total
--   garbage = list of {width,height,kind="combo"|"metal"|"chain"} blocks the engine actually queued
--   chain = max chain length reached; start = frame of first pop after the LAST swap; finish = frame it fully settled
function M.fire(g, absSwaps)
  local ok, res = pcall(function()
    local pz = Puzzle({ puzzleType = "moves", stack = stackString(g), moves = 99 })
    local m = Match(pz:toPanelSource(false), pz:toGameMode().matchRules)
    local st = m:createStackWithSettings(LP.getModern(10), true, "controller", nil); st:setMaxRunsPerFrame(1); m:start()
    local function cnt(col) local n=0; for r=1,st.height do for c=1,6 do if (st.panels[r][c].color or 0)==col then n=n+1 end end end return n end
    local function panels() local n=0; for r=1,st.height do for c=1,6 do local v=st.panels[r][c].color or 0; if v~=0 and v~=9 then n=n+1 end end end return n end
    -- settle the initial board (gravity only; no swap yet)
    for i = 1, 160 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if i>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
    -- hook the engine's garbage producer to capture exactly what it sends
    local events = {}
    local orig = st.pushGarbage
    st.pushGarbage = function(self, coord, isChain, comboSize, metalCount)
      events[#events+1] = { isChain = isChain, comboSize = comboSize, metal = metalCount or 0 }
      return orig(self, coord, isChain, comboSize, metalCount)
    end
    local before = {}; for c = 1, 4 do before[c] = cnt(c) end
    local p0 = panels()
    -- play every swap in order; the LAST one is the "fire" we time from
    for i, s in ipairs(absSwaps) do
      st.cur_row, st.cur_col = s[1], s[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      if i < #absSwaps then  -- let earlier (setup) swaps settle before the next
        for k = 1, SETTLE do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run(); if k>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
      end
    end
    -- time the cascade from the final swap: first pop = first panel-count drop; finish = settled
    local pAfterFire = panels()
    local startF, finishF, chain, frame = nil, SETTLE, 0, 0
    for k = 1, SETTLE do
      if st:game_ended() then finishF = k; break end
      st:receiveConfirmedInput("A"); m:run(); frame = k
      if (st.chain_counter or 0) > chain then chain = st.chain_counter end
      if not startF and panels() < pAfterFire then startF = k end
      if k >= 2 and not st:hasActivePanels() and not st:hasChainingPanels() then finishF = k; break end
    end
    st.pushGarbage = orig
    local clears, total, remaining = {}, 0, 0
    for c = 1, 4 do clears[c] = before[c] - cnt(c); total = total + math.max(0, clears[c]); remaining = remaining + cnt(c) end
    -- expand the captured events into garbage blocks via the engine's own COMBO_GARBAGE table
    local garbage = {}
    for _, e in ipairs(events) do
      for i = 3, (e.metal or 0) do garbage[#garbage+1] = { width = 6, height = 1, kind = "metal" } end
      for _, w in ipairs(COMBO_GARBAGE[e.comboSize] or {}) do garbage[#garbage+1] = { width = w, height = 1, kind = "combo" } end
      if e.isChain then garbage[#garbage+1] = { width = 6, height = 1, kind = "chain" } end
    end
    return { clears = clears, total = total, garbage = garbage, chain = chain, start = startF or 0, finish = finishF, remaining = remaining }
  end)
  if ok then return res end
  return { clears = {}, total = 0, garbage = {}, chain = 0, start = 0, finish = 0, remaining = 0 }
end

local function clone(g) local n = {}; for r = 1, H do n[r] = {}; for c = 1, W do n[r][c] = g[r][c] end end; return n end
local function sameClears(a, b) for c = 1, 4 do if (a[c] or 0) ~= (b[c] or 0) then return false end end; return true end
local function filler(r, c) return ((r + c) % 2 == 0) and 5 or 6 end
local function settleCols(g) for c = 1, W do local s = {}; for r = 1, H do if g[r][c] ~= 0 then s[#s+1] = g[r][c] end end; for r = 1, H do g[r][c] = s[r] or 0 end end end
local function setCell(g, r, c, v) local n = clone(g); n[r][c] = v; return n end
-- a pre-existing match: settle, then any >=3 run of a real panel (1..8). FREE (no engine) — the cheap prefilter.
local function preMatch(g)
  local s = clone(g); settleCols(s)
  for r = 1, H do for c = 1, W do local v = s[r][c]
    if v >= 1 and v <= 8 then
      if c <= W-2 and s[r][c+1]==v and s[r][c+2]==v then return true end
      if r <= H-2 and s[r+1][c]==v and s[r+2][c]==v then return true end
    end end end
  return false
end
-- does SOME single horizontal swap clear exactly `target`? (the 1-swap-shortcut test for multi-swap chips)
local function anySingleSwapClears(g, target)
  for r = 1, H do for c = 1, W - 1 do
    if g[r][c] ~= g[r][c+1] then
      local s = clone(g); s[r][c], s[r][c+1] = s[r][c+1], s[r][c]; settleCols(s)
      local hit = false                                        -- cheap prefilter: only fire if a real 3-run appears
      for rr = 1, H do for cc = 1, W do local v = s[rr][cc]; if v >= 1 and v <= 4 then
        if cc <= W-2 and s[rr][cc+1]==v and s[rr][cc+2]==v then hit = true end
        if rr <= H-2 and s[rr+1][cc]==v and s[rr+2][cc]==v then hit = true end end end end
      if hit and sameClears(M.fire(g, { { r, c } }).clears, target) then return true end
    end
  end end
  return false
end
-- is `g` still a valid instance of this chip: no pre-match, the swaps clear exactly `target`, and (for 2+ swaps) no
-- single swap clears the whole target. Accurate; pre-match prefilter makes the common rejections free.
function M.validInstance(g, absSwaps, target)
  if preMatch(g) then return false end
  if not sameClears(M.fire(g, absSwaps).clears, target) then return false end
  if #absSwaps >= 2 and anySingleSwapClears(g, target) then return false end
  return true
end
-- classify every NON-color cell in the footprint: "." must-empty · "@" blocker(solid,not-solving) · (nil = don't-care).
-- For each cell try empty / a filler / each present solving color and keep only what leaves a valid instance.
-- opt (all optional, for cheap SETUP authoring off a base): target=known clears (skip the fire); baseGrid+baseCls let
-- cells whose column-neighborhood is byte-identical to the base inherit the base's class instead of being re-tested.
function M.classify(g, absSwaps, opt)
  opt = opt or {}
  local target = opt.target or M.fire(g, absSwaps).clears
  local changedCol
  if opt.baseGrid then
    changedCol = {}
    for c = 1, W do for r = 1, H do if (g[r][c] or 0) ~= (opt.baseGrid[r][c] or 0) then changedCol[c] = true; break end end end
  end
  local minr, maxr, minc, maxc, colors = H+1, 0, W+1, 0, {}
  for r = 1, H do for c = 1, W do local v = g[r][c]; if v and v >= 1 and v <= 4 then
    minr=math.min(minr,r); maxr=math.max(maxr,r); minc=math.min(minc,c); maxc=math.max(maxc,c); colors[v]=true end end end
  for _, s in ipairs(absSwaps) do minr=math.min(minr,s[1]); maxr=math.max(maxr,s[1]); minc=math.min(minc,s[2]); maxc=math.max(maxc,s[2]+1) end
  local out = {}
  for r = math.max(1,minr), math.min(H,maxr) do
    for c = math.max(1,minc), math.min(W,maxc) do
      local v = g[r][c] or 0
      if (v >= 1 and v <= 4) then                              -- color cells are handled by the author's color classes
      elseif changedCol and not (changedCol[c-2] or changedCol[c-1] or changedCol[c] or changedCol[c+1] or changedCol[c+2]) then
        local cl = opt.baseCls[r*100+c]; if cl then out[r*100+c] = cl end   -- structure unchanged here -> inherit base
      else
        local okEmpty  = M.validInstance(setCell(g, r, c, 0), absSwaps, target)
        local okFiller = M.validInstance(setCell(g, r, c, filler(r, c)), absSwaps, target)
        local okColor  = false; for col in pairs(colors) do if M.validInstance(setCell(g, r, c, col), absSwaps, target) then okColor = true; break end end
        if okEmpty and okFiller and okColor then               -- truly anything -> don't-care
        elseif not okColor and not okEmpty and okFiller then out[r*100+c] = "@"   -- must be solid, not a solving color
        elseif okEmpty and not okFiller and not okColor then out[r*100+c] = "."   -- must be empty
        elseif not okColor and not okEmpty then out[r*100+c] = "@"                -- must be solid + not solving -> @
        elseif not okFiller and not okColor and okEmpty then out[r*100+c] = "."   -- only empty works -> .
        end                                                                       -- anything else: leave don't-care
      end
    end
  end
  return out
end
local function dirTag(dr, dc)   -- net cursor movement (row up = +)
  local v = {}; if dr > 0 then v[#v+1] = "up" elseif dr < 0 then v[#v+1] = "down" end
  if dc > 0 then v[#v+1] = "right" elseif dc < 0 then v[#v+1] = "left" end
  return #v > 0 and table.concat(v, "-") or "none"
end

-- blockers(g, absSwaps): which filler cells are LOAD-BEARING `@` (emptying them changes the clear) vs incidental
-- support. Only tests filler cells in/near the colored footprint (background junk can't matter). Returns a key set.
function M.blockers(g, absSwaps, baseClears)
  local minr, maxr, minc, maxc = H+1, 0, W+1, 0
  for r = 1, H do for c = 1, W do if (g[r][c] or 0) >= 1 and g[r][c] <= 4 then
    minr=math.min(minr,r); maxr=math.max(maxr,r); minc=math.min(minc,c); maxc=math.max(maxc,c) end end end
  for _, s in ipairs(absSwaps) do minr=math.min(minr,s[1]); maxr=math.max(maxr,s[1]); minc=math.min(minc,s[2]); maxc=math.max(maxc,s[2]+1) end
  local set = {}
  for r = math.max(1,minr-1), math.min(H,maxr+1) do
    for c = math.max(1,minc-1), math.min(W,maxc+1) do
      if (g[r][c] or 0) >= 5 then                       -- a support/filler cell
        local g2 = clone(g); g2[r][c] = 0               -- try emptying it
        if not sameClears(M.fire(g2, absSwaps).clears, baseClears) then set[r*100+c] = true end
      end
    end
  end
  return set
end

-- measure(g, absSwaps): the full per-chip metadata, engine-measured + derived.
function M.measure(g, absSwaps)
  local f = M.fire(g, absSwaps)
  local minr, maxr, minc, maxc, cols = H+1, 0, W+1, 0, {}
  for r = 1, H do for c = 1, W do local v = g[r][c]; if v and v >= 1 and v <= 4 then
    minr=math.min(minr,r); maxr=math.max(maxr,r); minc=math.min(minc,c); maxc=math.max(maxc,c); cols[v]=true end end end
  local nColors = 0; for _ in pairs(cols) do nColors = nColors + 1 end
  local travel = 0; for i = 2, #absSwaps do travel = travel + math.abs(absSwaps[i][1]-absSwaps[i-1][1]) + math.abs(absSwaps[i][2]-absSwaps[i-1][2]) end
  local s1, sN = absSwaps[1], absSwaps[#absSwaps]
  local edr, edc = sN[1]-s1[1], sN[2]-s1[2]
  return {
    clears = f.clears, total = f.total, garbage = f.garbage, chain = f.chain,
    start = f.start, finish = f.finish, leftover = f.remaining,   -- solving-color panels NOT cleared (should be 0)
    swaps = #absSwaps, cursorMoves = travel,
    cursorEnd = { dr = edr, dc = edc, dir = dirTag(edr, edc) },
    footprint = { rows = (maxr >= minr) and (maxr-minr+1) or 0, cols = (maxc >= minc) and (maxc-minc+1) or 0 },
    colors = nColors,
  }
end

-- a SETUP fires the SAME combo as its base, so inherit what it DOES (clears/garbage/chain/timing) with NO engine call;
-- only the cost (extra swap + cursor travel) and geometry differ, and those are cheap to recompute from the grid+swaps.
function M.measureFromBase(g, absSwaps, baseMeta)
  local minr, maxr, minc, maxc, cols = H+1, 0, W+1, 0, {}
  for r = 1, H do for c = 1, W do local v = g[r][c]; if v and v >= 1 and v <= 4 then
    minr=math.min(minr,r); maxr=math.max(maxr,r); minc=math.min(minc,c); maxc=math.max(maxc,c); cols[v]=true end end end
  local nColors = 0; for _ in pairs(cols) do nColors = nColors + 1 end
  local travel = 0; for i = 2, #absSwaps do travel = travel + math.abs(absSwaps[i][1]-absSwaps[i-1][1]) + math.abs(absSwaps[i][2]-absSwaps[i-1][2]) end
  local s1, sN = absSwaps[1], absSwaps[#absSwaps]; local edr, edc = sN[1]-s1[1], sN[2]-s1[2]
  return {
    clears = baseMeta.clears, total = baseMeta.total, garbage = baseMeta.garbage, chain = baseMeta.chain,
    start = baseMeta.start, finish = baseMeta.finish, leftover = baseMeta.leftover,
    swaps = #absSwaps, cursorMoves = travel,
    cursorEnd = { dr = edr, dc = edc, dir = dirTag(edr, edc) },
    footprint = { rows = (maxr >= minr) and (maxr-minr+1) or 0, cols = (maxc >= minc) and (maxc-minc+1) or 0 },
    colors = nColors,
  }
end

return M
