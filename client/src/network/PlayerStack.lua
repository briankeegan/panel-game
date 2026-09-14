local TouchDataEncoding = require("common.data.TouchDataEncoding")
---@class PlayerStack
local PlayerStack = require("client.src.PlayerStack")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local TraceWriter = require("client.src.network.TraceWriter")
local logger = require("common.lib.logger")

function PlayerStack.handle_input_taunt(self)
  if self.inputMethod ~= "touch" then
    local input = self.player.inputConfiguration
    if not input then return end
    if input.isDown["TauntUp"] and self:can_taunt() and self.character.sounds.taunt_up then
      self.taunt_up = math.random(#self.character.sounds.taunt_up.sources)
      GAME.netClient:sendTauntUp(self.taunt_up)
    elseif input.isDown["TauntDown"] and self:can_taunt() and self.character.sounds.taunt_down then
      self.taunt_down = math.random(#self.character.sounds.taunt_down.sources)
      GAME.netClient:sendTauntDown(self.taunt_down)
    end
  end
end

local touchIdleInput = TouchDataEncoding.touchDataToLatinString(false, 0, 0, 6)
function PlayerStack.idleInput(self)
  return (self.inputMethod == "touch" and touchIdleInput) or KeyDataEncoding.base64encode[1]
end

-- Override of the base PlayerStack stub. Tells the server our stack reached
-- game over so it can stop relaying our (now-absent) inputs and let the
-- surviving stacks finish the match. Other players get the death applied
-- authoritatively via the D-event relay.
function PlayerStack:notifyServerStackEliminated()
  if not self.is_local then
    return
  end
  if self._stackEliminationSent then
    return
  end
  if not GAME.netClient then
    -- No NetClient at all (offline-shaped match somehow live online). Nothing
    -- we can do; skip without the warn since this isn't a recoverable case.
    return
  end
  self._stackEliminationSent = true
  logger.info(string.format("Local stack topped out at frame %d; queueing D event", self.engine.game_over_clock))
  -- Always queue. NetClient.sendDeathEvent is now queue-then-flush — if the
  -- gameplay socket is mid-flap, the per-tick retry in NetClient:update will
  -- get the D through once the socket is healthy again. Don't lose the death.
  GAME.netClient:sendDeathEvent({
    senderFrame = self.engine.game_over_clock,
    stopWatch = self.engine.game_over_stopWatch,
    reason = "topOut",
  })
end

function PlayerStack:send_controls(isFreshFrame)
  if self.engine.game_over_clock and self.engine.game_over_clock > 0 then
    return
  end
  if isFreshFrame == nil then isFreshFrame = true end

  local to_send
  if self.inputMethod == "controller" then
    local input = self.player.inputConfiguration
    if not input then return end
    -- Edge-triggered bits (Swap, Raise's isDown) only encode on the first
    -- send per love.update. isDown stays truthy for the entire love.update,
    -- so without this filter catch-up iterations would duplicate a single
    -- tap into multiple input bytes. Held-state bits (isPressed for raise
    -- and movement) are NOT filtered — they correctly stay truthy across
    -- iterations, since the player IS holding the key on each engine tick
    -- represented by those iterations.
    local raiseEdge = isFreshFrame and (input.isDown["Raise1"] or input.isDown["Raise2"])
    local raiseHeld = input.isPressed["Raise1"] or input.isPressed["Raise2"]
    local swapEdge  = isFreshFrame and (input.isDown["Swap1"] or input.isDown["Swap2"])
    to_send = KeyDataEncoding.base64encode[
      ((raiseEdge or raiseHeld) and 32 or 0) +
      (swapEdge and 16 or 0) +
      ((input.isDown["Up"] or input.isPressed["Up"]) and 8 or 0) +
      ((input.isDown["Down"] or input.isPressed["Down"]) and 4 or 0) +
      ((input.isDown["Left"] or input.isPressed["Left"]) and 2 or 0) +
      ((input.isDown["Right"] or input.isPressed["Right"]) and 1 or 0) + 1
    ]
  elseif self.inputMethod == "touch" then
    to_send = self.touchInputDetector:encodedCharacterForCurrentTouchInput()
  end
  GAME.netClient:sendInput(to_send)

  if isFreshFrame then
    self:handle_input_taunt()
  end

  self.engine:receiveConfirmedInput(to_send)

  -- Trace capture: one JSONL line per local input frame. TraceWriter.input
  -- has its own state.disabled early-return + internal pcall, so we skip
  -- the outer closure allocation that would otherwise fire every tick.
  TraceWriter.input(to_send, self.engine.clock, self.engine.which)
end