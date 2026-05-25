---@class DisplayClientStack
---
--- Snapshot-based receiver for the parallel "Spectator View: New"
--- pipeline (see DISPLAY_HISTORY_PLAN.md). Holds the latest snapshot
--- shipped by a remote player's DisplayEventCapture; does NO simulation.
---
--- The receiver path is intentionally trivial:
---   applyBatch({from, snapshot}) → just stores the snapshot
---   render(viewStack)            → paints from the stored snapshot
---
--- No engine, no physics, no rollback, no event log. The snapshot IS the
--- state; we draw whatever the sender most recently said its board looks
--- like.

local logger = require("common.lib.logger")

---@class DisplayClientStackSnapshot
---@field f integer engine clock at snapshot time
---@field d integer displacement (0-15) smooth scroll offset
---@field cr integer cursor row
---@field cc integer cursor col
---@field w integer board width in panels
---@field h integer board height in panels
---@field sh integer shake_time
---@field psh integer prev_shake_time
---@field pkh integer peak_shake_time
---@field ic boolean in_countdown
---@field ct integer countdown_timer
---@field go integer game_over_clock (0 if alive)
---@field im string inputMethod ("controller" | "touch")
---@field cn integer chain_counter
---@field sc integer score
---@field sp integer speed
---@field lv integer level
---@field pc integer panels_cleared
---@field mp integer metalPanelsQueued
---@field hp integer health
---@field st integer stop_time
---@field ps integer pre_stop_time
---@field sw integer swap count
---@field rl boolean rise_lock
---@field og table outgoing garbage queue (staged)
---@field e table? one-shot trigger events (pop FX + score cards)
---@field p table flat panels array, indexed (row-1)*width + col; empty slots = nil

---@class DisplayClientStack
---@field playerID integer wire identifier of the remote player
---@field player Player? optional reference to the local Player object (for name / layout)
---@field viewStack table? matching ClientStack (for engine field mirroring + render layout)
---@field snapshot DisplayClientStackSnapshot? most recent snapshot received, nil until the first arrives
---@field prevSnapshot DisplayClientStackSnapshot? snapshot before `snapshot`, kept for interpolation
---@field snapshotsApplied integer running count of snapshots applied (diagnostic)
---@field latestRecvTime number love.timer.getTime() at last snapshot arrival
---@field prevRecvTime number love.timer.getTime() at prior snapshot arrival
local DisplayClientStack = {}
DisplayClientStack.__index = DisplayClientStack

-- Snapshot interval target. Sender ships at ~20Hz (50ms). Used as the
-- fallback denominator when interpolating before the second snapshot
-- arrives (avoids div-by-zero on the first frame after .new).
local EXPECTED_INTERVAL_S = 0.05

---@param playerID integer
---@param player Player?
---@param viewStack table? matching ClientStack for the remote player (engine field mirror target)
---@return DisplayClientStack
function DisplayClientStack.new(playerID, player, viewStack)
  local self = setmetatable({}, DisplayClientStack)
  self.playerID         = playerID
  self.player           = player
  self.viewStack        = viewStack
  self.snapshot         = nil
  self.prevSnapshot     = nil
  self.snapshotsApplied = 0
  self.latestRecvTime   = 0
  self.prevRecvTime     = 0
  return self
end

-- Mirror HUD scalars from the snapshot onto the engine fields the existing
-- drawScore / drawSpeed / drawLevel / drawMultibar / drawAnalyticData
-- methods read from. The engine isn't simulating for this stack (Match:
-- shouldRun returns false when displayHistoryActive is on), so writing
-- these fields is safe — nothing else is going to overwrite them.
--
-- engine.clock IS mirrored (Telegraph attack animation reads it). The
-- corresponding contamination of Match:updateClock is handled by an
-- explicit guard in Match.lua that skips non-local stacks when
-- displayHistoryActive is true.
--
-- engine.game_over_clock is NOT mirrored — the existing D-event path
-- already owns it. If we mirrored snapshot.go, a stale snapshot with
-- go=0 could "resurrect" a dead stack for hasEnded purposes, blocking
-- the match-end logic.
local function mirrorHudScalars(self, snapshot)
  local viewStack = self.viewStack
  if not viewStack or not viewStack.engine then return end
  local engine = viewStack.engine
  if snapshot.sc ~= nil then engine.score             = snapshot.sc end
  if snapshot.sp ~= nil then engine.speed             = snapshot.sp end
  if snapshot.lv ~= nil then engine.level             = snapshot.lv end
  if snapshot.pc ~= nil then engine.panels_cleared    = snapshot.pc end
  if snapshot.mp ~= nil then engine.metalPanelsQueued = snapshot.mp end
  if snapshot.hp ~= nil then engine.health            = snapshot.hp end
  if snapshot.st ~= nil then engine.stop_time         = snapshot.st end
  if snapshot.ps ~= nil then engine.pre_stop_time     = snapshot.ps end
  if snapshot.cn ~= nil then engine.chain_counter     = snapshot.cn end
  if snapshot.sw ~= nil then engine.swapCount         = snapshot.sw end
  if snapshot.sh ~= nil then engine.shake_time        = snapshot.sh end
  if snapshot.psh~= nil then engine.prev_shake_time   = snapshot.psh end
  if snapshot.pkh~= nil then engine.peak_shake_time   = snapshot.pkh end
  if snapshot.og ~= nil and engine.outgoingGarbage then
    engine.outgoingGarbage.stagedGarbage = snapshot.og
  end
  if snapshot.f  ~= nil then engine.clock             = snapshot.f end
end

---Apply an inbound batch. The batch is the JSON-decoded `Y` payload —
---{ from = playerID, snapshot = {...} }. We just store the snapshot;
---no per-field event handling.
---@param batch table
function DisplayClientStack:applyBatch(batch)
  if type(batch) ~= "table" then return end
  local snapshot = batch.snapshot
  if type(snapshot) ~= "table" then return end
  -- Match-boundary detection. A stale tail snapshot from the previous
  -- match can arrive after our DisplayClientStack has been rebuilt for
  -- the new match (flushDisplayEvents drains at startMatch, but the
  -- sender's stop()-final may still be in flight). When we detect the
  -- boundary, treat the incoming snapshot as the first of the new match:
  -- drop the stale snapshot we just stored, reset prev. Two signals:
  --   (a) Big clock regression: prev.f >> incoming.f (new match started
  --       at clock 0 or low).
  --   (b) Resurrection: prev had go>0 (dead) but incoming has go==0
  --       (alive). You can't un-die within a match.
  local cur = self.snapshot
  local isBoundary = false
  if cur then
    local prevF = cur.f or 0
    local nextF = snapshot.f or 0
    if (prevF - nextF) > 60 then isBoundary = true end
    if (cur.go or 0) > 0 and (snapshot.go or 0) == 0 then isBoundary = true end
  end
  if isBoundary then
    -- Drop the stale stored snapshot. prev gets cleared so interp doesn't
    -- lerp from a stale displacement into the fresh one.
    self.snapshot     = nil
    self.prevSnapshot = nil
    self.prevRecvTime = 0
  end
  -- Shift latest → prev for interpolation. Render uses both to lerp
  -- displacement (and cursor, if cheap) between frames.
  self.prevSnapshot   = self.snapshot
  self.prevRecvTime   = self.latestRecvTime
  self.snapshot       = snapshot
  self.latestRecvTime = love.timer.getTime()
  self.snapshotsApplied = self.snapshotsApplied + 1
  -- Push HUD scalars onto the matching engine so existing HUD render
  -- methods (drawScore etc.) display the correct values.
  mirrorHudScalars(self, snapshot)
  -- One-shot triggers: pop FX + score cards. Replay each by calling the
  -- existing PlayerStack helpers on the remote stack so its pop_q + cards
  -- queues fill exactly as if the panel had popped locally. The existing
  -- drawPopEffects / drawCards code paths then render them. Fire-and-
  -- forget — events are discarded after replay so they don't double-play
  -- on the next snapshot.
  if snapshot.e and self.viewStack and self.viewStack.enqueue_popfx then
    for _, ev in ipairs(snapshot.e) do
      if ev.k == "pop" then
        pcall(self.viewStack.enqueue_popfx, self.viewStack, ev.col, ev.row, ev.sz or 1)
      elseif ev.k == "card" and self.viewStack.enqueue_card then
        pcall(self.viewStack.enqueue_card, self.viewStack, ev.chain == true, ev.col, ev.row, ev.n or 1)
      end
    end
    snapshot.e = nil
  end
end

---Diagnostic snapshot for tests / debug overlays.
function DisplayClientStack:debugSnapshot()
  local s = self.snapshot or {}
  return {
    playerID         = self.playerID,
    snapshotsApplied = self.snapshotsApplied,
    frame            = s.f,
    cursorRow        = s.cr,
    cursorCol        = s.cc,
    gameOverClock    = s.go,
  }
end

-- Empty danger-column table reused per draw call (no per-column danger
-- visualization in the snapshot viewer yet — keep panels visually static
-- rather than animate danger).
local NO_DANGER = {}

-- Re-expand a wire-form cell into a Panel-shaped table the existing
-- Panels:addToDraw / drawGarbage helpers expect. Wire uses short keys
-- (c/s/t/g/m/...); this maps them back to the long names the renderer
-- reads. Returns nil for empty cells.
local function expandCell(cell, row, col, frameTimes)
  if not cell or not cell.c or cell.c == 0 then return nil end
  return {
    color              = cell.c,
    state              = cell.s or "normal",
    column             = col,
    row                = row,
    timer              = cell.t  or 0,
    isGarbage          = cell.g  or false,
    metal              = cell.m  or false,
    chaining           = cell.ch or false,
    garbageId          = cell.gi,
    x_offset           = cell.xo,
    y_offset           = cell.yo,
    width              = cell.gw,
    height             = cell.gh,
    pop_time           = cell.pt,
    initial_time       = cell.it,
    combo_size         = cell.cs,
    combo_index        = cell.ci,
    isSwappingFromLeft = cell.sl or false,
    -- frameTimes is per-match (level data); the receiver attaches the
    -- viewStack's engine's frameTimes when available so matched-state
    -- timing math in getDrawProps works.
    frameTimes         = frameTimes,
  }
end

-- Walk the snapshot grid, painting each non-empty cell as a panel sprite
-- or a multi-cell garbage block. Re-uses the same Panels:addToDraw batch
-- system PlayerStack:drawPanels uses, and the same garbage-draw helpers
-- on the character / metal panel set. Cells are passed through with
-- their real state so matched / swapping / popping animations render
-- correctly via the existing getDrawProps state machine.
---@param self DisplayClientStack
---@param viewStack table the matching ClientStack (for panels_dir + gfxScale + character)
---@param snapshot DisplayClientStackSnapshot
---@param shakeOffset number panel-coord vertical shake from mirrored shake_time
local function paintGridFromSnapshot(self, viewStack, snapshot, shakeOffset)
  local panelsDir = viewStack.panels_dir
  if not panelsDir then return end
  local panelSet = panels and panels[panelsDir]
  if not panelSet or not panelSet.addToDraw then return end

  panelSet:prepareDraw()

  local width  = snapshot.w or 6
  local height = snapshot.h or 12
  local displacement = snapshot.d or 0
  local grid = snapshot.p or {}

  -- frameTimes lives on the engine.levelData.frameConstants; needed by
  -- getDrawProps for the matched-state flash/face/pop timing. We pull
  -- it from the still-resident remote engine — it doesn't tick but its
  -- level data is set up at match start and is stable.
  local frameTimes
  if viewStack.engine
      and viewStack.engine.levelData
      and viewStack.engine.levelData.frameConstants then
    frameTimes = viewStack.engine.levelData.frameConstants
  end

  -- Garbage character + metal panel set come from the sender's stack;
  -- ClientStack already loaded them at match start. Match the lookup
  -- PlayerStack:drawPanels uses so multi-cell garbage renders with the
  -- right sprite atlas.
  local garbageCharacter = viewStack.garbageSource and viewStack.garbageSource.character
                       or viewStack.character
  local metalPanelSet    = viewStack.garbageSource and panels[viewStack.garbageSource.panels_dir]
                       or panelSet

  local metall_w, metall_h, metalr_w, metalr_h
  if metalPanelSet and metalPanelSet.images and metalPanelSet.images.metals then
    metall_w, metall_h = metalPanelSet.images.metals.left:getDimensions()
    metalr_w, metalr_h = metalPanelSet.images.metals.right:getDimensions()
  end

  -- Loop matches PlayerStack:drawPanels' iteration order (rows from
  -- bottom, columns right-to-left so swap animations layer correctly).
  for row = 0, height do
    for col = width, 1, -1 do
      local cell = grid[row * width + col]
      local panel = expandCell(cell, row, col, frameTimes)
      if panel and panel.state ~= "popped" then
        local draw_x = 4 + (col - 1) * 16
        local draw_y = 4 + (11 - row) * 16 + displacement - shakeOffset

        if panel.isGarbage then
          -- Only the bottom-right corner of a garbage block triggers the
          -- block draw (mirrors PlayerStack:drawPanels).
          if panel.x_offset == (panel.width or 1) - 1 and panel.y_offset == 0 then
            if panel.state ~= "matched"
                or (panel.timer and panel.pop_time and panel.timer <= panel.pop_time) then
              if panel.metal and metalPanelSet and metalPanelSet.drawMetalGarbage then
                metalPanelSet:drawMetalGarbage(draw_x, draw_y, panel.width, viewStack.gfxScale)
              elseif garbageCharacter and garbageCharacter.drawGarbage then
                local drawHeight = math.min(panel.height or 1,
                  28 + (panel.height or 1) % 4)
                local garbageX = draw_x - ((panel.width or 1) - 1) * 16
                local garbageY = draw_y - (drawHeight - 1) * 16
                garbageCharacter:drawGarbage(garbageX, garbageY, panel.width, drawHeight, viewStack.gfxScale)
              end
            end
          end
          -- Matched garbage panels also draw the per-cell "pop reveal"
          -- sprite. Reuse the panel set's batch for that.
          if panel.state == "matched" and frameTimes then
            panelSet:addToDraw(panel, draw_x, draw_y, viewStack.gfxScale,
              NO_DANGER, 0, snapshot.st or 0)
          end
        else
          panelSet:addToDraw(panel, draw_x, draw_y, viewStack.gfxScale,
            NO_DANGER, 0, snapshot.st or 0)
        end
      end
    end
  end

  panelSet:drawBatch()
end

-- Cursor sprite is fetched the same way PlayerStack:render_cursor does:
-- alternating frame indexed by snapshot.f / 16 % 2. Position in panel
-- coords matches the engine's (cur_col-1)*16, (11-cur_row)*16 +
-- displacement formula.
local function paintCursorFromSnapshot(self, viewStack, snapshot)
  local theme = viewStack.theme or (themes and themes[config and config.theme])
  if not theme or not theme.images or not theme.images.cursor then return end
  local frameIndex = (math.floor((snapshot.f or 0) / 16) % 2) + 1
  local cursor = theme.images.cursor[frameIndex]
  if not cursor or not cursor.image then return end

  -- During countdown the cursor blinks (alternating frames invisible);
  -- mirror PlayerStack:render_cursor's behavior.
  local countdown_timer = snapshot.ct or 0
  if countdown_timer > 0 and ((snapshot.f or 0) % 2 ~= 0) then return end

  local desiredCursorWidth = 40
  local panelWidth = 16
  local scale_x = desiredCursorWidth / cursor.image:getWidth()
  local scale_y = 24 / cursor.image:getHeight()
  local xPosition = ((snapshot.cc or 1) - 1) * panelWidth
  local yPosition = (11 - (snapshot.cr or 1)) * panelWidth + (snapshot.d or 0)

  -- Dim if the sender is dead.
  if (snapshot.go or 0) > 0 then
    love.graphics.setColor(1, 1, 1, 0.3)
  end

  love.graphics.draw(cursor.image,
    xPosition * viewStack.gfxScale,
    yPosition * viewStack.gfxScale,
    0,
    scale_x * viewStack.gfxScale,
    scale_y * viewStack.gfxScale)
  love.graphics.setColor(1, 1, 1, 1)
end

---Render this remote player's board from the stored snapshot. Uses the
---existing Panels:addToDraw batch system so panel sprites match the
---player's chosen panel mod. Drawn inside viewStack:setDrawArea so the
---transform / scissor match the old viewer's coordinate system.
---
---No engine work. The snapshot is the state; we paint from it directly.
---@param viewStack table the matching ClientStack (for layout)
-- Delayed interpolation: render ~one snapshot-interval behind real time,
-- lerping between the two most-recent known snapshots. This is the safe
-- form of interpolation — both endpoints are authoritative, no
-- overshoot, no snap-back. The trade-off is ~50ms of visual lag on
-- remote boards, which is invisible to the local player's gameplay
-- (their own engine is never interpolated).
--
-- Lerps displacement only (the main "feels janky" axis). Cursor uses
-- the latest snapshot's position directly — cursor jumps are
-- semantically significant and shouldn't be smoothed.
local function interpolatedDisplacement(self)
  local latest = self.snapshot
  local prev   = self.prevSnapshot
  if not latest then return nil end
  if not prev then return latest.d end
  local interval = self.latestRecvTime - self.prevRecvTime
  if interval <= 0 then return latest.d end
  -- "render time" sits one full interval behind the latest arrival.
  -- alpha 0 = render prev fully; alpha 1 = render latest fully.
  local elapsed = love.timer.getTime() - self.latestRecvTime
  local alpha   = math.max(0, math.min(1, elapsed / interval))
  local dPrev = prev.d   or 0
  local dCur  = latest.d or 0
  -- Skip the lerp across the mod-16 wrap (new row spawned) so we don't
  -- count down 15→14→...→0 instead of skipping to 0.
  if math.abs(dCur - dPrev) > 8 then return dCur end
  return dPrev + alpha * (dCur - dPrev)
end

function DisplayClientStack:render(viewStack)
  if not viewStack or not self.snapshot then return end
  if not viewStack.setDrawArea or not viewStack.resetDrawArea then return end

  -- Apply interpolated displacement for smooth scroll at 20Hz snapshot
  -- rate. Restore the authoritative value after rendering so subsequent
  -- applyBatch + mirrorHudScalars see the wire value, not the interp.
  local origD = self.snapshot.d
  local interp = interpolatedDisplacement(self)
  if interp then self.snapshot.d = interp end

  -- Match the old viewer's appearance: character portrait behind the
  -- stack, frame border around it, wall at the bottom of the panel area.
  -- These read fields off the viewStack itself (character, theme, frame
  -- assets) and from viewStack.engine for things like displacement, which
  -- mirrorHudScalars already keeps in sync with the snapshot.

  -- shakeOffset comes from the mirrored shake_time on engine. Wall + panels
  -- both displace by this same amount so the bottom row + grid shift together
  -- under garbage impact. Displacement (the smooth scroll) is intentionally
  -- NOT applied to the wall — that's the bug fix for "bottom red piece
  -- raising/lowering".
  local shakeOffset = 0
  if viewStack.currentShakeOffset and viewStack.gfxScale and viewStack.gfxScale ~= 0 then
    local ok, val = pcall(viewStack.currentShakeOffset, viewStack)
    if ok and type(val) == "number" then
      shakeOffset = val / viewStack.gfxScale
    end
  end

  viewStack:setDrawArea(0, 0)
  love.graphics.push("all")

  -- Character portrait + stack frame (matches old viewer's layered look).
  if viewStack.drawCharacter then pcall(viewStack.drawCharacter, viewStack) end

  -- Paint the grid + cursor inside the panel-coord transform.
  paintGridFromSnapshot(self, viewStack, self.snapshot, shakeOffset)

  -- Frame border + wall at the bottom row. Wall takes shakeOffset, NOT
  -- displacement — matches PlayerStack:render:985 (drawWall(shakeOffset, ...)).
  if viewStack.drawFrame then pcall(viewStack.drawFrame, viewStack) end
  if viewStack.drawWall and self.snapshot.h then
    pcall(viewStack.drawWall, viewStack, shakeOffset, self.snapshot.h)
  end

  paintCursorFromSnapshot(self, viewStack, self.snapshot)

  love.graphics.pop()
  viewStack:resetDrawArea()

  -- Restore the wire displacement so future applyBatch sees the
  -- authoritative shipped value, not our render-time interpolation.
  self.snapshot.d = origD
end

return DisplayClientStack
