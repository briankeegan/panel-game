-- SimulatedRemoteStackView — RemoteStackView adapter for engine-driven
-- view-stacks (the old input-replication path). Renderer reads pull
-- straight from stack.engine.* fields.

local class = require("common.lib.class")
local RemoteStackView = require("client.src.RemoteStackView")

---@class SimulatedRemoteStackView : RemoteStackView
---@field stack table  the ClientStack being wrapped
local SimulatedRemoteStackView = class(function(self, stack)
  self.stack = stack
end, RemoteStackView)

function SimulatedRemoteStackView:getFrame()
  return (self.stack.engine and self.stack.engine.clock) or 0
end

function SimulatedRemoteStackView:isAlive()
  local e = self.stack.engine
  return not (e and (e.game_over_clock or -1) > 0)
end

function SimulatedRemoteStackView:getOutgoingTelegraph()
  local e = self.stack.engine
  if not (e and e.outgoingGarbage) then return {} end
  return e.outgoingGarbage.stagedGarbage or {}
end

function SimulatedRemoteStackView:getDisplaySnapshot()
  -- Simulated view: no snapshot, the engine IS the source of truth.
  return nil
end

return SimulatedRemoteStackView
