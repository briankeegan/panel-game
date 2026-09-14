-- SnapshotRemoteStackView — RemoteStackView adapter for snapshot-driven
-- viewers. Renderer reads pull from the latest Y snapshot stored on
-- the DisplayClientStack.
--
-- Engine fields on the underlying view-stack ARE mirrored by the
-- snapshot pipeline (engine.clock, engine.shake_time, etc.) for legacy
-- HUD code that reads them directly, but the canonical source for
-- view-shaped questions is the snapshot table. This adapter answers
-- from the snapshot first, falls back to the engine when a field
-- isn't snapshot-shaped.

local class = require("common.lib.class")
local RemoteStackView = require("client.src.RemoteStackView")

---@class SnapshotRemoteStackView : RemoteStackView
---@field displayStack DisplayClientStack  the DisplayClientStack owning the snapshot
---@field stack table  the ClientStack the snapshot is paired with (for legacy fallback fields)
local SnapshotRemoteStackView = class(function(self, displayStack, stack)
  self.displayStack = displayStack
  self.stack = stack
end, RemoteStackView)

function SnapshotRemoteStackView:getFrame()
  local snap = self.displayStack and self.displayStack.snapshot
  if snap and snap.f then return snap.f end
  return (self.stack.engine and self.stack.engine.clock) or 0
end

function SnapshotRemoteStackView:isAlive()
  -- Snapshot ships go = game_over_clock. game_over_clock starts at -1
  -- (alive) and gets set to the death frame (>0) once recorded. The
  -- snapshot's go field rides that wire convention.
  local snap = self.displayStack and self.displayStack.snapshot
  if snap and snap.go ~= nil then return snap.go <= 0 end
  local e = self.stack.engine
  return not (e and (e.game_over_clock or -1) > 0)
end

function SnapshotRemoteStackView:getOutgoingTelegraph()
  -- Snapshot mirrors the staged outgoing-garbage list onto the engine
  -- so legacy Telegraph code reads it without modification. Prefer
  -- reading the snapshot directly when available for clarity.
  local snap = self.displayStack and self.displayStack.snapshot
  if snap and snap.og then return snap.og end
  local e = self.stack.engine
  if e and e.outgoingGarbage then return e.outgoingGarbage.stagedGarbage or {} end
  return {}
end

function SnapshotRemoteStackView:getDisplaySnapshot()
  return self.displayStack and self.displayStack.snapshot or nil
end

return SnapshotRemoteStackView
