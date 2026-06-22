-- chips.lua — the chip cache (V2). A CHIP is a guaranteed play: "recognize a spot -> make a move -> it WORKS."
-- Brian's 100% bar: a chip that isn't 100% must not be used. Pattern-alone plateaus at ~81% (a flat snapshot can't
-- capture fall/support), so we guarantee 100% the robust way: RECOGNIZE (cheap pattern slide to narrow candidates) +
-- VERIFY (one-step sim that the move actually fires HERE). Only verified plays are returned -> 100% by construction.
-- All recognition is from the cursor outward, sliding minimal templates; junk around a template's cells is don't-care.
local BoardSim = require("bot.BoardSim")

local chips = {}
local STORE = {}            -- list of { tmpl = {{dr,dc,class}..}, kind, swaps = {{dr,dc}..} } (swaps anchor-relative)
local STORE_BY_KIND = {}    -- kind -> {chips of that kind} -- recognize iterates ONLY this, not the whole store (~90x)

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

-- recognize a NAMED/SIZED chip from the store: slide every STORE chip of `kind` over the candidate cells (already
-- cursor-ordered by the caller); on a template fit, map its swap offsets to absolute cells and VERIFY the whole
-- sequence fires (caller's real-engine check) before returning. A chip carries `swaps` (a list of anchor-relative
-- offsets); a single-swap chip is just a 1-element list. Legacy `swap` (one pair) is still accepted. No BoardSim, no
-- prediction -- fits is a pure pattern-match, verify is engine-truth. nil = none here.
-- cheap pre-filter for BREAK candidates: any template cell orthogonally adjacent to a garbage cell on the board.
-- Narrows before the costly verify; the verify's garbageMatched signal is the actual confirmation.
local function nearGarbage(grid, rows, t, R, C)
  for _, e in ipairs(t) do
    local r, c = R + e[1], C + e[2]
    for _, d in ipairs({ { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local rr, cc = r + d[1], c + d[2]
      if rr >= 1 and rr <= rows and cc >= 1 and cc <= 6 and grid[rr] and grid[rr][cc] == BoardSim.GARBAGE then return true end
    end
  end
  return false
end

-- requireBreak: only accept a match that actually breaks garbage (cheap nearGarbage pre-filter, then garbageMatched).
function chips.recognize(grid, rows, cells, kind, verify, touchable, requireBreak)
  local list = STORE_BY_KIND[kind]; if not list then return nil end   -- O(1) kind lookup; iterate only its templates
  for _, cell in ipairs(cells) do local R, C = cell[1], cell[2]
    for _, chip in ipairs(list) do
      if fits(grid, rows, chip.tmpl, R, C) then
        local ok = true
        -- NO-GO zones: every MATCH cell the chip reads must be a settled, touchable panel. Cells the chip doesn't
        -- reference (the `*` don't-care space) aren't in the template, so they're exempt automatically.
        if touchable then
          for _, e in ipairs(chip.tmpl) do
            local tr, tc = R + e[1], C + e[2]
            if not (touchable[tr] and touchable[tr][tc]) then ok = false; break end
          end
        end
        local offsets = chip.swaps or { chip.swap }       -- back-compat: a single `swap` is a 1-element list
        local seq = {}
        if ok then
          for _, off in ipairs(offsets) do
            local sr, sc = R + off[1], C + off[2]
            if not (sr >= 1 and sr <= rows and sc >= 1 and sc <= 5) then ok = false; break end
            -- can't swap an unsettled panel: BOTH swapped cells (sc and sc+1) must be touchable
            if touchable and not (touchable[sr] and touchable[sr][sc] and touchable[sr][sc + 1]) then ok = false; break end
            seq[#seq + 1] = { sr, sc }
          end
        end
        if ok and (not requireBreak or nearGarbage(grid, rows, chip.tmpl, R, C)) then
          local fired, broke = true, false
          if verify then fired, broke = verify(seq, kind) end
          if fired and (not requireBreak or broke) then     -- requireBreak: only accept a match the engine confirms broke garbage
            chips._lastMatch = { R = R, C = C, tmpl = chip.tmpl, swaps = seq, kind = kind }  -- debug/viz: where it landed
            return { swaps = seq, kind = kind, brokeGarbage = broke or false }
          end
        end
      end
    end
  end
  return nil
end

-- horizontal mirror of a template: reflect columns around the swap's center (col 0.5), so cell dc -> 1-dc and a swap's
-- left cell dc -> -dc. The catalog is mirror-FOLDED (one of each mirror pair), so we must store both orientations or
-- every mirrored real combo is missed.
local function mirrorChip(c)
  local t = {}; for _, e in ipairs(c.tmpl) do t[#t + 1] = { e[1], 1 - e[2], e[3] } end
  local s = {}; for _, sw in ipairs(c.swaps) do s[#s + 1] = { sw[1], -sw[2] } end
  return { tmpl = t, kind = c.kind, swaps = s }
end
local function chipKey(c)   -- dedup key (symmetric shapes mirror to themselves)
  local ce = {}; for _, e in ipairs(c.tmpl) do ce[#ce + 1] = e[1] .. "," .. e[2] .. "," .. tostring(e[3]) end; table.sort(ce)
  local sw = {}; for _, s in ipairs(c.swaps) do sw[#sw + 1] = s[1] .. "," .. s[2] end
  return c.kind .. "|" .. table.concat(ce, ";") .. "|" .. table.concat(sw, ";")
end

-- load the autogenerated engine-verified combo templates (bot/chipCache.lua) into the store -- each template AND its
-- horizontal mirror. Safe if the file is absent. Auto-runs on require so the vocabulary is live without a build step.
function chips.loadCache()
  local ok, data = pcall(require, "bot.chipCache")
  if not ok or type(data) ~= "table" then return 0 end
  local seen, n = {}, 0
  local function add(c)
    local k = chipKey(c); if seen[k] then return end; seen[k] = true
    STORE[#STORE + 1] = c; n = n + 1
    local bk = STORE_BY_KIND[c.kind]; if not bk then bk = {}; STORE_BY_KIND[c.kind] = bk end; bk[#bk + 1] = c
  end
  for _, c in ipairs(data) do
    local chip = { tmpl = c.tmpl, kind = c.kind, swaps = c.swaps or { c.swap or { 0, 0 } } }
    add(chip); add(mirrorChip(chip))
  end
  return n
end
chips.loadCache()

return chips
