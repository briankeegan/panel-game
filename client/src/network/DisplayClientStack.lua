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

---@class DisplayClientStack
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

---Phase C minimal render. Draws a debug overlay positioned over the
---corresponding view-stack's frame: cursor crosshair (read from
---visualState), event counter, dead overlay. Enough to prove events are
---flowing — Phase C iteration extends to full panel rendering.
---
---Positioning: called by BattleRoom:renderDisplayStacks (parallel render
---pass added in GameBase:draw). Receives the matching view-stack's
---frameOriginX/Y/gfxScale via the BattleRoom layer so it draws inside
---the same scissor region as the old view-stack.
---
---@param viewStack table|nil the matching existing ClientStack (for layout)
function DisplayClientStack:render(viewStack)
  if not viewStack then return end

  -- Pull frame coordinates from the existing view-stack so this overlay
  -- lands in the same scissor region the player already associates with
  -- this opponent.
  local scale = viewStack.gfxScale or 1
  local ox = (viewStack.frameOriginX or 0) * scale
  local oy = (viewStack.frameOriginY or 0) * scale
  local w  = (viewStack.baseWidth   or 0) * scale
  local h  = (viewStack.baseHeight  or 0) * scale

  if w <= 0 or h <= 0 then return end

  love.graphics.push("all")

  -- Black-out the existing render so the new viewer fully replaces it
  -- (per plan: binary choice, never side-by-side). Translucent so the
  -- user can still see roughly where they are during validation.
  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", ox, oy, w, h)

  -- Border indicating the new viewer is active for this stack.
  love.graphics.setColor(0.4, 1.0, 0.4, 0.9)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", ox, oy, w, h)

  -- Cursor crosshair from visualState. cur_row/cur_col are 1-indexed in
  -- the engine; project onto the stack's drawable region. We don't know
  -- the exact panel size at this layer; approximate at 6 columns wide.
  local vs = self.visualState
  local cols = 6
  local rowsVisible = 12
  local cellW = w / cols
  local cellH = h / rowsVisible
  local cx = ox + (vs.cursorCol - 1) * cellW
  -- Row 1 is bottom in the engine; flip to screen coords.
  local cy = oy + (rowsVisible - vs.cursorRow) * cellH
  love.graphics.setColor(1.0, 1.0, 0.4, 0.9)
  love.graphics.rectangle("fill", cx, cy, cellW * 2, cellH)

  -- Diagnostic readout in the top-left corner of the frame.
  love.graphics.setColor(1, 1, 1, 0.95)
  local font = love.graphics.getFont()
  local readout = string.format(
    "DISP id=%s evt=%d frame=%d rows=%d",
    tostring(self.playerID), self.eventsApplied, self.lastFrame, vs.rows)
  love.graphics.print(readout, ox + 4, oy + 4)

  if vs.dead then
    love.graphics.setColor(1, 0.2, 0.2, 0.8)
    love.graphics.print("DEAD", ox + 4, oy + (font and font:getHeight() or 12) + 6)
  end

  love.graphics.pop()
end

return DisplayClientStack
