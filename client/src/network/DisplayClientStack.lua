---@class DisplayClientStack
---
--- Phase B of the display-history replication plan
--- (see DISPLAY_HISTORY_PLAN.md). Lightweight stand-in for a remote
--- player's view-stack. Consumes display events from the wire and
--- mutates a visualState table. Has NO engine, NO physics, NO rollback,
--- NO input apply. Render is a stub until Phase C wires real drawing.
---
--- Built and routed by ClientMatch when the room flag
--- displayHistoryEnabled is true. When the flag is false, no DisplayClientStacks
--- are ever instantiated and this module is dormant.
---
--- Wire event tags (from DisplayEventCapture):
---   C  cursor moved      { r, c }
---   S  panels swapped    { r, c }
---   L  panel landed      { r, c }
---   P  panel pop         { r, c, color }
---   M  matched           { combo, chain, metal, garbage }
---   R  new row           { colors }
---   D  game over         {}
---
--- All event handlers are pure — they update visualState in place. The
--- renderer (Phase C) reads visualState directly.

local logger = require("common.lib.logger")

---@class DisplayClientStackVisualState
---@field cursorRow integer
---@field cursorCol integer
---@field swapPulse integer increments on each swap event; renderer uses for flash effects
---@field landings { r: integer, c: integer, f: integer? }[] recent panel landings ring
---@field pops { r: integer, c: integer, color: integer?, f: integer? }[] recent panel pops ring
---@field matches { combo: integer?, chain: boolean?, metal: integer?, garbage: integer?, f: integer? }[] recent match events
---@field rows integer count of new-row events received
---@field lastRowColors integer[]? colors of the most recent new row
---@field dead boolean true after a D (gameOver) event has been applied

---@class DisplayClientStack
---@field playerID integer wire identifier of the remote player this stack mirrors
---@field player Player? optional reference to the matching Player (for name / layout)
---@field lastFrame integer most recent frame stamp applied (engine clock of the sender)
---@field eventsApplied integer running total of events successfully applied (diagnostic)
---@field pendingEvents table[] reserved for playback-buffer use in future iterations
---@field visualState DisplayClientStackVisualState
local DisplayClientStack = {}
DisplayClientStack.__index = DisplayClientStack

---@param playerID integer wire identifier for the remote player
---@param player Player? optional reference to the local Player object (for layout / name lookup)
---@return DisplayClientStack
function DisplayClientStack.new(playerID, player)
  local self = setmetatable({}, DisplayClientStack)
  self.playerID = playerID
  self.player   = player
  -- Last-known frame stamp from an applied event. Lets the renderer (or
  -- diagnostics) know how current this stack's view is.
  self.lastFrame = 0
  -- Counter for diagnostics; lets us know if events are flowing without
  -- needing to attach a debugger.
  self.eventsApplied = 0
  -- Buffer of received-but-not-yet-applied events. Phase B applies
  -- immediately; Phase C may add a playback-buffer delay so visuals are
  -- smoothed against network jitter.
  self.pendingEvents = {}
  -- The visual state that the renderer reads. Phase B keeps this minimal;
  -- Phase C will extend as the renderer needs more.
  self.visualState = {
    cursorRow   = 1,
    cursorCol   = 1,
    swapPulse   = 0,    -- counter incremented on each S event; used by render to flash
    landings    = {},   -- recent panel landings (for animation hooks in Phase C)
    pops        = {},   -- recent panel pops
    matches     = {},   -- recent match events (combo / chain telemetry)
    rows        = 0,    -- count of new-row events; visualizable as a raise indicator
    dead        = false,
  }
  return self
end

---Apply a single decoded event to visualState. Pure: no network IO,
---no engine state mutation, no external side effects.
---@param ev table { f, t, ... }
function DisplayClientStack:applyEvent(ev)
  if type(ev) ~= "table" then return end
  local tag = ev.t
  if not tag then return end
  if ev.f then self.lastFrame = ev.f end
  self.eventsApplied = self.eventsApplied + 1

  local vs = self.visualState
  if tag == "C" then
    vs.cursorRow = ev.r or vs.cursorRow
    vs.cursorCol = ev.c or vs.cursorCol
  elseif tag == "S" then
    vs.cursorRow = ev.r or vs.cursorRow
    vs.cursorCol = ev.c or vs.cursorCol
    vs.swapPulse = vs.swapPulse + 1
  elseif tag == "L" then
    vs.landings[#vs.landings + 1] = { r = ev.r, c = ev.c, f = ev.f }
    -- Bound the landings ring to avoid unbounded growth between renders.
    if #vs.landings > 64 then table.remove(vs.landings, 1) end
  elseif tag == "P" then
    vs.pops[#vs.pops + 1] = { r = ev.r, c = ev.c, color = ev.color, f = ev.f }
    if #vs.pops > 64 then table.remove(vs.pops, 1) end
  elseif tag == "M" then
    vs.matches[#vs.matches + 1] = {
      combo = ev.combo, chain = ev.chain, metal = ev.metal, garbage = ev.garbage, f = ev.f,
    }
    if #vs.matches > 16 then table.remove(vs.matches, 1) end
  elseif tag == "R" then
    vs.rows = vs.rows + 1
    vs.lastRowColors = ev.colors
  elseif tag == "D" then
    vs.dead = true
  end
end

---Apply a whole batch (the wire shape is {from, events}). Convenience
---wrapper around applyEvent.
---@param batch table { from, events }
function DisplayClientStack:applyBatch(batch)
  if type(batch) ~= "table" or type(batch.events) ~= "table" then return end
  for _, ev in ipairs(batch.events) do
    self:applyEvent(ev)
  end
end

---Diagnostic snapshot. Useful from a debug overlay or test.
function DisplayClientStack:debugSnapshot()
  return {
    playerID      = self.playerID,
    lastFrame     = self.lastFrame,
    eventsApplied = self.eventsApplied,
    cursorRow     = self.visualState.cursorRow,
    cursorCol     = self.visualState.cursorCol,
    rows          = self.visualState.rows,
    dead          = self.visualState.dead,
  }
end

---Phase C render. With the per-room flag on, the old PlayerStack:render
---is suppressed (stack.canvas = nil) so this method is the ONLY source
---of visuals for the remote player. Until the event taxonomy covers
---full panel grid state, we draw a placeholder: solid background filling
---the view-stack region, the cursor position from visualState, a
---"NEW VIEWER" label, and a diagnostic line showing event flow.
---
---This is intentionally not a faithful reproduction of the old viewer
---— it's a "this works, the new pipeline is alive" indicator. The real
---faithful render needs events for panel landings, pops, rows, etc. to
---reconstruct the grid.
---
---@param viewStack table|nil the matching existing ClientStack (for layout)
function DisplayClientStack:render(viewStack)
  if not viewStack then return end

  local scale = viewStack.gfxScale or 3
  local ox = (viewStack.frameOriginX or 0) * scale
  local oy = (viewStack.frameOriginY or 0) * scale
  local w  = (viewStack.baseWidth   or 0) * scale
  local h  = (viewStack.baseHeight  or 0) * scale

  if w <= 0 or h <= 0 then return end

  love.graphics.push("all")

  -- Solid dark background so the new viewer fully replaces the area.
  love.graphics.setColor(0.08, 0.08, 0.12, 1.0)
  love.graphics.rectangle("fill", ox, oy, w, h)

  -- Subtle border so the player can see this is the new viewer.
  love.graphics.setColor(0.4, 1.0, 0.4, 0.7)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", ox, oy, w, h)

  -- Cursor: use the panel-coord math from PlayerStack:render_cursor.
  -- Cursor straddles two columns (panel widths) and sits one panel tall.
  if viewStack.setDrawArea and viewStack.resetDrawArea then
    viewStack:setDrawArea(0, 0)
    love.graphics.push("transform")
    love.graphics.scale(scale, scale)
    local panelWidth = 16
    local visibleRows = 11
    local vs = self.visualState
    local cx = (vs.cursorCol - 1) * panelWidth
    local cy = (visibleRows - vs.cursorRow) * panelWidth
    love.graphics.setColor(1.0, 0.95, 0.3, 0.95)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", cx, cy, panelWidth * 2, panelWidth)
    love.graphics.pop()
    viewStack:resetDrawArea()
  end

  -- Status text confirming the new viewer is active for this stack.
  love.graphics.setColor(0.7, 1.0, 0.7, 0.95)
  love.graphics.print("NEW VIEWER", ox + 8, oy + 8)
  love.graphics.setColor(0.6, 0.7, 0.85, 0.85)
  local readout = string.format("id=%s evt=%d frame=%d",
    tostring(self.playerID), self.eventsApplied, self.lastFrame)
  love.graphics.print(readout, ox + 8, oy + 24)

  if self.visualState.dead then
    love.graphics.setColor(1, 0.3, 0.3, 0.9)
    love.graphics.print("DEAD", ox + 8, oy + 42)
  end

  love.graphics.pop()
end

return DisplayClientStack
