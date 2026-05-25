-- RemoteStackView — read-only contract a renderer uses to draw a remote
-- player's board, without caring HOW the data got there.
--
-- Two concrete impls live alongside:
--   * SimulatedRemoteStackView — wraps an engine-driven view-stack (the
--     old input-replication path). Reads pull straight from
--     stack.engine.* fields.
--   * SnapshotRemoteStackView — wraps a DisplayClientStack's latest Y
--     snapshot. Reads pull from the snapshot table.
--
-- Renderer code (Telegraph, future remote-board paint) gets handed
-- whichever instance the room's viewer-mode dictates and never has to
-- branch on it. Swapping viewers is structurally a swap of the
-- adapter, not a change to the renderer.
--
-- This file defines the interface (a class that errors on every method
-- so subclasses must override). The behavior contract is documented
-- per-method.

local class = require("common.lib.class")

---@class RemoteStackView
local RemoteStackView = class(function(self) end)

-- Current engine clock for this remote stack. Used by Telegraph to
-- compute attack-animation progress (sender.clock - frameEarned).
-- Returns whatever frame value the renderer should treat as "now"
-- for time-sensitive draws.
---@return integer
function RemoteStackView:getFrame()
  error("RemoteStackView:getFrame must be overridden")
end

-- Whether this stack is alive (no recorded death). Renderers use this
-- to skip telegraph rendering for already-eliminated senders.
---@return boolean
function RemoteStackView:isAlive()
  error("RemoteStackView:isAlive must be overridden")
end

-- The staged outgoing-garbage array. Telegraph iterates this to draw
-- each in-flight piece. Same shape as Stack.outgoingGarbage.stagedGarbage
-- (Garbage records with frameEarned, width, height, etc.).
---@return table[]
function RemoteStackView:getOutgoingTelegraph()
  error("RemoteStackView:getOutgoingTelegraph must be overridden")
end

-- The full display snapshot table (for snapshot-driven viewers). Returns
-- nil for simulated viewers — render code that paints panels can fall
-- back to the engine-driven render path when nil. The Y wire format is
-- documented in DisplaySnapshotUtil.
---@return table?
function RemoteStackView:getDisplaySnapshot()
  return nil
end

return RemoteStackView
