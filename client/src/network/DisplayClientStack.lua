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
---@field ic boolean in_countdown
---@field ct integer countdown_timer
---@field go integer game_over_clock (0 if alive)
---@field im string inputMethod ("controller" | "touch")
---@field cn integer chain_counter
---@field p table flat panels array, indexed (row-1)*width + col; empty slots = nil

---@class DisplayClientStack
---@field playerID integer wire identifier of the remote player
---@field player Player? optional reference to the local Player object (for name / layout)
---@field snapshot DisplayClientStackSnapshot? most recent snapshot received, nil until the first arrives
---@field snapshotsApplied integer running count of snapshots applied (diagnostic)
local DisplayClientStack = {}
DisplayClientStack.__index = DisplayClientStack

---@param playerID integer
---@param player Player?
---@return DisplayClientStack
function DisplayClientStack.new(playerID, player)
  local self = setmetatable({}, DisplayClientStack)
  self.playerID         = playerID
  self.player           = player
  self.snapshot         = nil
  self.snapshotsApplied = 0
  return self
end

---Apply an inbound batch. The batch is the JSON-decoded `Y` payload —
---{ from = playerID, snapshot = {...} }. We just store the snapshot;
---no per-field event handling.
---@param batch table
function DisplayClientStack:applyBatch(batch)
  if type(batch) ~= "table" then return end
  local snapshot = batch.snapshot
  if type(snapshot) ~= "table" then return end
  self.snapshot = snapshot
  self.snapshotsApplied = self.snapshotsApplied + 1
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

-- Walk the snapshot grid, painting each non-empty cell as a panel sprite.
-- Re-uses the same Panels:addToDraw batch system PlayerStack:drawPanels
-- uses. Cells are drawn in their resting "normal" state regardless of
-- their actual engine state — this gives a correct board LAYOUT and
-- COLOR scheme without needing to ship matched/swapping/popping animation
-- timers. Garbage cells are drawn as a generic dark block; full garbage
-- rendering is a later iteration.
---@param self DisplayClientStack
---@param viewStack table the matching ClientStack (for panels_dir + gfxScale)
---@param snapshot DisplayClientStackSnapshot
local function paintGridFromSnapshot(self, viewStack, snapshot)
  local panelsDir = viewStack.panels_dir
  if not panelsDir then return end
  local panelSet = panels and panels[panelsDir]
  if not panelSet or not panelSet.addToDraw then return end

  panelSet:prepareDraw()

  local width  = snapshot.w or 6
  local height = snapshot.h or 12
  local displacement = snapshot.d or 0
  local grid = snapshot.p or {}

  -- Loop matches PlayerStack:drawPanels' iteration order (rows from
  -- bottom, columns right-to-left so swap animations layer correctly).
  for row = 0, height do
    for col = width, 1, -1 do
      local cell = grid[row * width + col]
      if cell and cell.c and cell.c ~= 0 and cell.s ~= "popped" then
        local draw_x = 4 + (col - 1) * 16
        local draw_y = 4 + (11 - row) * 16 + displacement

        if cell.g then
          -- Garbage placeholder: dark filled rect. Full garbage block
          -- rendering needs x_offset/y_offset/width/height in the
          -- snapshot; track for later iteration.
          love.graphics.push("all")
          love.graphics.setColor(0.25, 0.20, 0.15, 1.0)
          love.graphics.rectangle("fill",
            draw_x * viewStack.gfxScale, draw_y * viewStack.gfxScale,
            16 * viewStack.gfxScale, 16 * viewStack.gfxScale)
          love.graphics.pop()
        else
          -- Force state="normal" — non-resting states need fields we
          -- don't ship yet (frameTimes for matched, isSwappingFromLeft
          -- for swapping). Drawing as normal keeps panels visible and
          -- correctly positioned; missing animations are a known
          -- limitation of this first cut.
          local fakePanel = {
            color   = cell.c,
            state   = "normal",
            column  = col,
            timer   = 0,
          }
          panelSet:addToDraw(fakePanel, draw_x, draw_y, viewStack.gfxScale,
            NO_DANGER, 0, 0)
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
function DisplayClientStack:render(viewStack)
  if not viewStack or not self.snapshot then return end
  if not viewStack.setDrawArea or not viewStack.resetDrawArea then return end

  -- Solid background so the new viewer fully replaces the old (which is
  -- suppressed via stack.canvas = nil at match start).
  local scale = viewStack.gfxScale or 3
  local ox = (viewStack.frameOriginX or 0) * scale
  local oy = (viewStack.frameOriginY or 0) * scale
  local w  = (viewStack.baseWidth   or 0) * scale
  local h  = (viewStack.baseHeight  or 0) * scale
  if w > 0 and h > 0 then
    love.graphics.push("all")
    love.graphics.setColor(0.05, 0.05, 0.08, 1.0)
    love.graphics.rectangle("fill", ox, oy, w, h)
    love.graphics.pop()
  end

  viewStack:setDrawArea(0, 0)
  love.graphics.push("all")

  -- Paint the grid + cursor inside the panel-coord transform.
  paintGridFromSnapshot(self, viewStack, self.snapshot)
  paintCursorFromSnapshot(self, viewStack, self.snapshot)

  love.graphics.pop()
  viewStack:resetDrawArea()

  -- Dead overlay drawn outside setDrawArea so it sits on top of the grid.
  if (self.snapshot.go or 0) > 0 then
    love.graphics.push("all")
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", ox, oy, w, h)
    love.graphics.setColor(1, 0.3, 0.3, 0.9)
    love.graphics.print("DEAD", ox + 8, oy + 8)
    love.graphics.pop()
  end
end

return DisplayClientStack
