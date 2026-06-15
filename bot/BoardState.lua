-- Engine Stack -> DATA_CONTRACT state struct.
--
-- Shared extractor (contract §12): the data track re-sims replays into the SAME
-- engine Stack, so one extractor serves both live play and replay parsing. Keep
-- it byte-faithful to the frozen schema.
--
-- Coords: 1-based [row, col]; row 1 = floor (matches engine panels[row][col] and
-- DATA_CONTRACT §1). board[r][c] = { c = colorInt(0-9), s = stateCode }.

local PanelStateCodes = require("client.src.network.PanelStateCodes")

local M = {}

-- A color is a normal, swappable/matchable panel color (1..6). 0 = empty,
-- 7=square, 8=metal, 9=garbage are not freely matchable.
function M.isPlayColor(c)
  return c and c >= 1 and c <= 6
end

-- Pending garbage aimed at this stack -> DATA_CONTRACT §6 incoming[] of
-- { w, h, metal, chain, eta(frames-until-land) }.
-- eta per §6 (shared with the data track's re-sim — must match exactly):
--   in transit: deliveryTime - clock (exact; deliveryTime is the queue key).
--   staged:     frameEarned + STAGING_DURATION + GARBAGE_DELAY_LAND_TIME - clock,
--               where STAGING_DURATION = GARBAGE_TRANSIT_TIME + GARBAGE_TELEGRAPH_TIME + 1.
function M.extractIncoming(stack)
  local out = {}
  local iq = stack.incomingGarbage
  if not iq then return out end
  local clock = stack.clock or 0
  local stagingDuration = GARBAGE_TRANSIT_TIME + GARBAGE_TELEGRAPH_TIME + 1

  for _, g in ipairs(iq.stagedGarbage or {}) do
    out[#out + 1] = {
      w = g.width, h = g.height,
      metal = g.isMetal or false, chain = g.isChain or false,
      eta = (g.frameEarned + stagingDuration + GARBAGE_DELAY_LAND_TIME) - clock,
    }
  end
  for deliveryTime, pieces in pairs(iq.garbageInTransit or {}) do
    for _, g in ipairs(pieces) do
      out[#out + 1] = {
        w = g.width, h = g.height,
        metal = g.isMetal or false, chain = g.isChain or false,
        eta = deliveryTime - clock,
      }
    end
  end
  return out
end

-- Per-garbage-cell reveal colors (the colors a block's bottom row becomes when
-- broken). The engine pops width-char rows from panelSource.garbagePanelBuffer in
-- pop order and assigns each converting cell the char at its own column. We can
-- predict this exactly for the common case — the bottom row of a single garbage
-- block — by assigning buffer rows to blocks bottom-to-top. Multi-block-same-frame
-- ordering isn't reproducible from a snapshot, so reveals beyond the first row per
-- block are left unknown (BoardSim then reveals empty, not a fabricated color).
-- Returns reveal[r][c] = color int, only for bottom-row garbage cells we resolved.
local function captureReveals(stack, rows, width)
  local src = stack.panelSource
  local buf = src and src.garbagePanelBuffer
  if not buf or buf == "" then return nil end
  local panels = stack.panels

  -- group garbage cells by garbageId, track each block's bottom row
  local blocks = {} -- id -> { minRow, cells = {{r,c},...} }
  local order = {}
  for r = 1, rows do
    local prow = panels[r]
    for c = 1, width do
      local p = prow and prow[c]
      if p and p.isGarbage and p.garbageId then
        local b = blocks[p.garbageId]
        if not b then b = { minRow = r, cells = {} }; blocks[p.garbageId] = b; order[#order + 1] = p.garbageId end
        if r < b.minRow then b.minRow = r end
        b.cells[#b.cells + 1] = { r, c }
      end
    end
  end
  -- assign bottom-to-top so the lowest block (likeliest to break first) gets the
  -- front of the buffer
  table.sort(order, function(a, b) return blocks[a].minRow < blocks[b].minRow end)

  local reveal, pos = {}, 1
  for _, id in ipairs(order) do
    local b = blocks[id]
    if pos + width - 1 > #buf then break end -- ran out of known buffer
    local rowStr = buf:sub(pos, pos + width - 1)
    pos = pos + width
    for _, cell in ipairs(b.cells) do
      local r, c = cell[1], cell[2]
      if r == b.minRow then
        local ch = rowStr:sub(c, c)
        local col = tonumber(ch)
        if col and col >= 1 and col <= 6 then
          reveal[r] = reveal[r] or {}
          reveal[r][c] = col
        end
      end
    end
  end
  return reveal
end

---@return table state { board, width, rows, cursor, displacement, height, danger, columnHeights, incoming }
function M.extract(stack)
  local width = stack.width
  local panels = stack.panels
  local rows = #panels

  local board = {}
  local columnHeights = {}
  for c = 1, width do columnHeights[c] = 0 end

  local reveal = captureReveals(stack, rows, width)

  for r = 1, rows do
    local prow = panels[r]
    local outRow = {}
    local revRow = reveal and reveal[r]
    for c = 1, width do
      local p = prow and prow[c]
      if p then
        local color = p.color or 0
        outRow[c] = { c = color, s = PanelStateCodes.toCode(p.state), reveal = revRow and revRow[c] }
        if color ~= 0 then columnHeights[c] = r end -- highest occupied row in this column
      else
        outRow[c] = { c = 0, s = 0 }
      end
    end
    board[r] = outRow
  end

  local maxColHeight = 0
  for c = 1, width do
    if columnHeights[c] > maxColHeight then maxColHeight = columnHeights[c] end
  end

  return {
    board = board,
    width = width,
    rows = rows,
    cursor = { stack.cur_row, stack.cur_col },
    displacement = stack.displacement,
    height = stack.height,            -- rows of play before top-out
    columnHeights = columnHeights,    -- highest occupied row per column
    maxColHeight = maxColHeight,
    danger = maxColHeight >= (stack.height - 1),
    incoming = M.extractIncoming(stack),
  }
end

return M
