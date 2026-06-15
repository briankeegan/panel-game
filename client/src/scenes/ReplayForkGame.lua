-- Live game scene for a "play from here" fork. Same as a normal GameBase game
-- (the local board is live + input-driven), but the OTHER boards are ghosts:
-- remote snapshot stacks fed from the replay's remaining displayHistory instead
-- of the network. Snapshots are delta-encoded, so ghosts are fast-forwarded
-- from frame 0 up to the fork frame on the first tick, then play at 1x. When a
-- ghost's tape runs out it simply freezes; the live board keeps going.

local class = require("common.lib.class")
local GameBase = require("client.src.scenes.GameBase")

local ReplayForkGame = class(function(self, sceneParams)
  self._forkTape = sceneParams.forkTape or {}
  table.sort(self._forkTape, function(a, b)
    return (a.snapshot.f or 0) < (b.snapshot.f or 0)
  end)
  self._forkFeedIndex = 1
  self._forkCursor = sceneParams.forkFrame or 0 -- start caught up to the fork point
  self._forkPrimed = false
  self._forkGarbage = sceneParams.forkGarbage or {}
  self._forkGarbageIndex = 1
  self:load(sceneParams)
end, GameBase)

ReplayForkGame.name = "ReplayForkGame"

-- The live (taken-over) stack; located lazily, cached.
function ReplayForkGame:_localStack()
  if self._cachedLocal then return self._cachedLocal end
  if self.match and self.match.stacks then
    for _, st in ipairs(self.match.stacks) do
      if st.is_local then self._cachedLocal = st; return st end
    end
  end
  return nil
end

-- Feed ghost batches + recorded incoming garbage up to the cursor, then run the
-- live game as usual.
function ReplayForkGame:update(dt)
  local br = GAME.battleRoom
  if br and br.applyDisplayEventBatch and self._forkFeedIndex <= #self._forkTape then
    if self._forkPrimed then
      self._forkCursor = self._forkCursor + 1 -- advance ghosts ~1 frame/tick after the initial catch-up
    else
      self._forkPrimed = true -- first tick: drain everything up to the fork frame at once
    end
    local tape = self._forkTape
    while self._forkFeedIndex <= #tape and (tape[self._forkFeedIndex].snapshot.f or 0) <= self._forkCursor do
      pcall(br.applyDisplayEventBatch, br, tape[self._forkFeedIndex])
      self._forkFeedIndex = self._forkFeedIndex + 1
    end
  else
    -- tape exhausted (ghosts frozen) but the live board plays on — keep the
    -- cursor advancing so any remaining garbage still lands on schedule.
    if self._forkPrimed then self._forkCursor = self._forkCursor + 1 end
  end

  -- Deliver recorded garbage that targeted the taken-over board, on schedule.
  if self._forkGarbageIndex <= #self._forkGarbage then
    local stack = self:_localStack()
    local engine = stack and stack.engine
    local gl = self._forkGarbage
    while self._forkGarbageIndex <= #gl and (gl[self._forkGarbageIndex].senderFrame or 0) <= self._forkCursor do
      local ev = gl[self._forkGarbageIndex]
      if engine and engine.applyNetworkGarbage and type(ev.garbage) == "table" then
        -- Recorded frameEarned is in the ORIGINAL replay clock; the queue
        -- releases garbage when clock >= frameEarned + STAGING_DURATION, so on
        -- the forked stack's FRESH clock the original frame is thousands of
        -- frames in the future and never drops. Rebase each piece to "now" so
        -- it telegraphs + lands like freshly-arrived garbage.
        local rebased = {}
        for i, g in ipairs(ev.garbage) do
          local c = {}
          for k, v in pairs(g) do c[k] = v end
          c.frameEarned = engine.clock
          rebased[i] = c
        end
        pcall(engine.applyNetworkGarbage, engine, rebased, ev.sender)
      end
      self._forkGarbageIndex = self._forkGarbageIndex + 1
    end
  end

  -- Headless harness only: no input device exists, so send_controls produces
  -- no input and the live stack would starve at clock 0. Feed idle input when
  -- starved so the takeover actually simulates (rises, drops garbage) for
  -- screenshot verification. Real play has a bound device and never hits this.
  if os.getenv("PA_AUTO_FORK") then
    local st = self:_localStack()
    local e = st and st.engine
    if e and e.confirmedInput and e.receiveConfirmedInput and e.idleInput
        and #e.confirmedInput < (e.clock or 0) + 2 then
      e:receiveConfirmedInput(e:idleInput())
    end
  end

  GameBase.update(self, dt)
end

return ReplayForkGame
