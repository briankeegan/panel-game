-- Engine Stack -> DATA_CONTRACT state struct.
--
-- Shared extractor (contract §12): the data track re-sims replays into the SAME
-- engine Stack, so one extractor serves both live play and replay parsing. Keep
-- it byte-faithful to the frozen schema.
--
-- Coords: 1-based [row, col]; row 1 = floor (matches engine panels[row][col] and
-- DATA_CONTRACT §1). board[r][c] = { c = colorInt(0-9), s = stateCode }.

local PanelStateCodes = require("client.src.network.PanelStateCodes")
local StackEventRecorder = require("bot.StackEventRecorder")

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

-- The bot's OWN outgoing attack queue (it was blind to its own pressure). Best-effort
-- summary: count + total area of pending/in-transit garbage we're sending. Defensive
-- (GarbageQueue internals vary); never throws.
function M.extractOutgoing(stack)
  local oq = stack.outgoingGarbage
  if type(oq) ~= "table" then return { count = 0, totalArea = 0 } end
  local count, area = 0, 0
  local function scan(list)
    if type(list) ~= "table" then return end
    for _, g in pairs(list) do
      if type(g) == "table" then
        if g.width and g.height then count = count + 1; area = area + g.width * g.height
        else scan(g) end
      end
    end
  end
  scan(oq.stagedGarbage); scan(oq.garbageInTransit); scan(oq.garbage)
  return { count = count, totalArea = area }
end

-- v1 CONTRACT (bot/STATE_CAPTURE_DESIGN.md): CAPTURE is dumb + COMPLETE. It dumps the full
-- decision-relevant engine state + RAW per-frame events + schemaVersion. NO derived features
-- live here — those go in derive() / FeatureEncoder / data's analyzers, so a new signal is a
-- re-DERIVE, never a corpus re-PARSE. One capture, live == replay (faithfulness preserved).
---@return table captured
function M.capture(stack)
  local width = stack.width
  local panels = stack.panels
  local rows = #panels
  local reveal = captureReveals(stack, rows, width)

  -- raw board: per cell { c(olor), s(tate code), isGarbage, garbageId, reveal }
  local board = {}
  for r = 1, rows do
    local prow = panels[r]
    local outRow = {}
    local revRow = reveal and reveal[r]
    for c = 1, width do
      local p = prow and prow[c]
      if p then
        outRow[c] = { c = p.color or 0, s = PanelStateCodes.toCode(p.state),
          isGarbage = p.isGarbage or false, garbageId = p.garbageId, reveal = revRow and revRow[c] }
      else
        outRow[c] = { c = 0, s = 0 }
      end
    end
    board[r] = outRow
  end

  return {
    schemaVersion = 1,
    board = board, width = width, rows = rows,
    -- cursor / geometry (raw)
    cur_row = stack.cur_row, cur_col = stack.cur_col, top_cur_row = stack.top_cur_row,
    height = stack.height,
    -- timers / invincibility (raw — derive does max/critical/etc.)
    displacement = stack.displacement,
    stop_time = stack.stop_time or 0, pre_stop_time = stack.pre_stop_time or 0,
    shake_time = stack.shake_time or 0, peak_shake_time = stack.peak_shake_time or 0,
    rise_timer = stack.rise_timer, health = stack.health,
    speed = stack.speed, nextSpeedIncreaseClock = stack.nextSpeedIncreaseClock,
    -- chain / active (raw)
    chain_counter = stack.chain_counter or 0,
    n_active_panels = stack.n_active_panels or 0, n_prev_active_panels = stack.n_prev_active_panels or 0,
    swapThisFrame = stack.swapThisFrame, swappingPanelCount = stack.swappingPanelCount,
    -- clock / top-out (raw)
    clock = stack.clock, stopWatch = stack.stopWatch,
    wasToppedOut = stack.wasToppedOut, has_risen = stack.has_risen,
    -- garbage: incoming queue, our OWN outgoing, what landed this frame
    incoming = M.extractIncoming(stack),
    outgoing = M.extractOutgoing(stack),
    garbageLandedThisFrame = stack.garbageLandedThisFrame,
    -- RAW per-frame events drained from the recorder (edges, not just levels)
    events = StackEventRecorder.drain(stack),
  }
end

-- DERIVE: compute the feature struct the live bot's eval consumes, FROM a captured struct.
-- This is the bot-side derive layer (data owns the corpus-side derive in FeatureEncoder /
-- fit_targets). Adding/changing a feature = edit here only; capture + corpus never move.
---@param cap table result of M.capture
---@return table state
function M.derive(cap)
  local board, width, rows = cap.board, cap.width, cap.rows
  local columnHeights = {}
  for c = 1, width do columnHeights[c] = 0 end
  for r = 1, rows do
    local row = board[r]
    for c = 1, width do
      if row[c].c ~= 0 then columnHeights[c] = r end -- highest occupied row per column
    end
  end
  local maxColHeight = 0
  for c = 1, width do if columnHeights[c] > maxColHeight then maxColHeight = columnHeights[c] end end
  local height = cap.height or 12

  return {
    board = board, width = width, rows = rows,
    cursor = { cap.cur_row, cap.cur_col },
    displacement = cap.displacement,
    height = height,
    columnHeights = columnHeights,
    maxColHeight = maxColHeight,
    danger = maxColHeight >= (height - 1),
    incoming = cap.incoming,
    -- INVINCIBILITY (derived from the raw timers; see bot/TIMING_L10.md): three sources of
    -- "can't rise / can't top out", do NOT stack (max-based). The bot must SEE its window.
    stopTime = cap.stop_time + cap.pre_stop_time,
    shakeTime = cap.shake_time,                          -- earned when garbage LANDS (≤76f @L10)
    frozenFrames = math.max(cap.stop_time, cap.pre_stop_time, cap.shake_time), -- window remaining
    critical = maxColHeight >= height,                   -- top row occupied -> BIGGEST stop time
    -- newly-surfaced signals the eval was blind to (retune consumes these):
    health = cap.health,                                 -- top-out grace (rise-ticks until death)
    riseTimer = cap.rise_timer,                           -- exact frames to next row commit
    peakShake = cap.peak_shake_time,
    outgoing = cap.outgoing,                              -- our own pressure
    events = cap.events,                                  -- edges: chainEnded ("fire now"), etc.
    chaining = cap.chain_counter > 0,
    chainCounter = cap.chain_counter,
    activePanels = cap.n_active_panels,
    riseSpeed = cap.speed,
  }
end

-- Live-bot entry point: capture (complete) then derive (features). Same shape consumers
-- already use, plus the newly-surfaced fields. The corpus parser calls M.capture directly.
---@return table state
function M.extract(stack)
  return M.derive(M.capture(stack))
end

return M
