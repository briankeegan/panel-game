-- getChainShapes.lua — CHAIN chips: ONE swap fires a pure combo-3 cascade that FULLY CLEARS the board.
-- These are built from one 2-color building block (STEP) stacked and alternating colors, feeding UP the board; the
-- tower variant is the same feed standing vertical (CONVERT). The whole grammar is in bot/CHAIN_GRAMMAR.md.
--   luajit bot/getChainShapes.lua
--
-- Why 2 colors: by the time link 3 fires, link 1's color is already gone, so it is free to reuse -> every chain is just
-- A,B,A,B... up the stack. Each match is exactly 3 (no combos). The swap is the only move; the rest is fallout feeding up.
require("bot.headlessBoot"); do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc = _G.loc or function(s) return tostring(s) end
local analyze = require("bot.chipAnalyze")
local M = {}
local H, W = 12, 6

-- Verified building-block chips. rows = TOP-row-first (last string is the bottom row r1). swap = {row,col} anchor
-- (swaps cells col & col+1 on that row). 2 colors only (1,2), alternating up the stack.
local DEFS = {
  { kind = "CHAIN_2",     rows = { "022000", "112100" },                              swap = { 1, 3 } },
  { kind = "CHAIN_3",     rows = { "001000", "022100", "112110" },                    swap = { 1, 3 } },
  { kind = "CHAIN_4",     rows = { "001200", "022120", "112112" },                    swap = { 1, 3 } },
  { kind = "CHAIN_5",     rows = { "001100", "001210", "022120", "112112" },          swap = { 1, 3 } },
  { kind = "CHAIN_6",     rows = { "002200", "001100", "021210", "022120", "112112" },swap = { 1, 3 } },
  { kind = "CHAIN_TOWER", rows = { "002000", "001000", "001000", "212000" },          swap = { 1, 2 } }, -- T->R atom: a tower feeds a row
}

local function gridFromRows(rows)
  local nr = #rows; local g = {}; for r = 1, H do g[r] = {}; for c = 1, W do g[r][c] = 0 end end
  for i, s in ipairs(rows) do local rr = nr - i + 1; for c = 1, W do g[rr][c] = tonumber(s:sub(c, c)) or 0 end end
  return g
end

-- verify each chip on the real engine: must fully clear (remaining==0) and reach the named chain depth.
local function enumerateRaw()
  local out, skipped = {}, {}
  for _, d in ipairs(DEFS) do
    local g = gridFromRows(d.rows)
    local f = analyze.fire(g, { d.swap })
    local want = tonumber(d.kind:match("_(%d+)$"))
    if f.remaining == 0 and (not want or f.chain == want) then
      out[#out+1] = { kind = d.kind, grid = g, swap = d.swap, sr = d.swap[1], sc = d.swap[2], chain = f.chain, total = f.total, rows = d.rows }
    else
      skipped[#skipped+1] = { kind = d.kind, reason = string.format("chain=%d remaining=%d (wanted %s)", f.chain, f.remaining, tostring(want)) }
    end
  end
  return { out = out, skipped = skipped }
end

function M.enumerate() return enumerateRaw() end

local function render(s)
  local out = {}
  for _, str in ipairs(s.rows) do local t = {}; for c = 1, W do local ch = str:sub(c, c); t[c] = (ch == "0") and "." or ch end
    out[#out+1] = "   " .. table.concat(t, " ") end
  return table.concat(out, "\n")
end

if arg and arg[0] and arg[0]:match("getChainShapes%.lua$") then
  local res = M.enumerate()
  print(string.format("CHAIN chips: %d verified  (pure combo-3, one swap, board fully clears; 2 colors alternating, feeding up)\n", #res.out))
  for _, s in ipairs(res.out) do
    print(string.format("%s  (chain %d, clears %d, swap c%d<->c%d @r%d):", s.kind, s.chain, s.total, s.sc, s.sc+1, s.sr))
    print(render(s)); print("")
  end
  if #res.skipped > 0 then print("---- skipped ----"); for _, sk in ipairs(res.skipped) do print("  " .. sk.kind .. " : " .. sk.reason) end end
end

local function produce()
  local out = {}
  for _, s in ipairs(M.enumerate().out) do
    out[#out+1] = { g = s.grid, sr = s.sr, sc = s.sc, kind = s.kind, absSwaps = { s.swap } }
  end
  return out
end
require("bot.chipRegistry").register{ name = "getChainShapes", produce = produce }

return M
