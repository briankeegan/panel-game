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

---@return table state { board, width, rows, cursor, displacement, height, danger, columnHeights, incoming }
function M.extract(stack)
  local width = stack.width
  local panels = stack.panels
  local rows = #panels

  local board = {}
  local columnHeights = {}
  for c = 1, width do columnHeights[c] = 0 end

  for r = 1, rows do
    local prow = panels[r]
    local outRow = {}
    for c = 1, width do
      local p = prow and prow[c]
      if p then
        local color = p.color or 0
        outRow[c] = { c = color, s = PanelStateCodes.toCode(p.state) }
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
    incoming = {},                    -- TODO(Phase 1 garbage pass): read stack.incomingGarbage
  }
end

return M
