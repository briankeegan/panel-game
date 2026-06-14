-- ReplaySpectator — watches a 2+ player snapshot replay by BEING a spectator.
-- A live spectator's boards animate because the network delivers one snapshot
-- batch per frame and the receiver paints whatever it last got. A replay has
-- the whole tape at once, so this scene supplies the timing the wire used to:
-- it feeds the recorded batches into the (already-open) spectating BattleRoom's
-- existing applyDisplayEventBatch, one frame's worth per real-time frame.
--
-- No engine simulation and ZERO changes to BattleRoom — just the pacing.
local GameBase = require("client.src.scenes.GameBase")
local class = require("common.lib.class")
local input = require("client.src.inputManager")

local ReplaySpectator = class(function(self, sceneParams)
  -- The recorded display-history, sorted by frame (see ReplayBrowser).
  self.tape = sceneParams.tape or {}
  self.tapeIndex = 1
  self._startTime = nil
  self:load(sceneParams)
end, GameBase)

ReplaySpectator.name = "ReplaySpectator"

-- Feed every snapshot whose recorded frame the wall clock has reached. Snapshots
-- are stamped in 60fps engine frames, so a 60/sec cursor replays at record speed.
function ReplaySpectator:feedTape()
  local br = GAME.battleRoom
  if not br or not br.applyDisplayEventBatch then return end
  if not self._startTime then self._startTime = love.timer.getTime() end
  local cursor = (love.timer.getTime() - self._startTime) * 60
  while self.tapeIndex <= #self.tape do
    local batch = self.tape[self.tapeIndex]
    local f = (batch and batch.snapshot and batch.snapshot.f) or 0
    if f > cursor then break end
    br:applyDisplayEventBatch(batch)
    self.tapeIndex = self.tapeIndex + 1
  end
end

function ReplaySpectator:update(dt)
  self:feedTape()

  -- Leave the replay.
  if input.allKeys.isDown["escape"] or input.isDown["MenuEsc"] or input.isDown["MenuBack"] then
    GAME.theme:playCancelSfx()
    if self.match then self.match:abort() end
    GAME.navigationStack:pop()
    return
  end

  -- Everything else (spectator player-switch via < >, HUD, uiRoot) comes from
  -- GameBase unchanged. The engine is paused (pauseNonLocalSimulation) so its
  -- per-frame run is a no-op; the tape above is what drives the boards.
  GameBase.update(self, dt)
end

return ReplaySpectator
