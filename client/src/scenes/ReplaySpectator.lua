-- Plays a 2+ player snapshot replay as a spectator with a variable-speed
-- scrubber. The tape is fed forward into the BattleRoom's applyDisplayEventBatch
-- (which resolves deltas in place, so each fed entry becomes a full board); a
-- cursor then parks every board on the frame it points at. Replay-only.
local GameBase = require("client.src.scenes.GameBase")
local class = require("common.lib.class")
local input = require("client.src.inputManager")
local consts = require("common.engine.consts")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local TeamUtils = require("common.data.TeamUtils")

-- frames/sec = speed * 60; negative = reverse, 0 = pause
local SPEEDS = {-32, -16, -8, -4, -2, -1, -0.5, 0, 0.5, 1, 2, 4, 8, 16, 32}
local PAUSE_INDEX = 1
for i, s in ipairs(SPEEDS) do if s == 0 then PAUSE_INDEX = i; break end end

local ReplaySpectator = class(function(self, sceneParams)
  self.replay = sceneParams.replay -- for the "play from here" fork (seed + garbage log)
  self.spectatorBattleRoom = GAME.battleRoom -- restore on return from a fork (it swaps GAME.battleRoom)
  self.tape = sceneParams.tape or {}
  -- sort by frame so the high-water gate is monotonic (same-sender frames are
  -- unique, so per-sender order is preserved regardless of sort stability)
  table.sort(self.tape, function(a, b)
    return (a.snapshot.f or 0) < (b.snapshot.f or 0)
  end)

  self.byStack = {}
  self.lastF = 0
  for _, batch in ipairs(self.tape) do
    local list = self.byStack[batch.from]
    if not list then list = {}; self.byStack[batch.from] = list end
    list[#list + 1] = batch
    self.lastF = math.max(self.lastF, batch.snapshot.f or 0)
  end

  self.playbackFrame = 0
  self.highWaterF    = -1
  self.feedIndex     = 1

  self.speedIndex = 7
  for i, s in ipairs(SPEEDS) do if s == 1 then self.speedIndex = i end end
  self.selectedRow = "speed"

  self:load(sceneParams)
end, GameBase)

ReplaySpectator.name = "ReplaySpectator"

-- largest index whose frame <= F (binary search; everything <= F is fed/resolved)
local function displayIndexFor(list, F)
  local lo, hi, best = 1, #list, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if (list[mid].snapshot.f or 0) <= F then best = mid; lo = mid + 1 else hi = mid - 1 end
  end
  return best
end

local function focusedPlayerName(match)
  local slot = match.spectatorFocus
  if slot then
    for _, stack in ipairs(match.stacks) do
      if stack.player and TeamUtils.slotOf(stack.player, stack.player_number) == slot then
        return stack.player.name or "Player"
      end
    end
  end
  local s = match.stacks and match.stacks[1]
  return (s and s.player and s.player.name) or "Player"
end

function ReplaySpectator:handleInput()
  -- Back/escape: first press pauses (speed -> 0); pressing it again while
  -- already paused exits. Edge-detected so a held key doesn't pause-then-exit.
  local backDown = input.allKeys.isDown["escape"] or input.isDown["MenuEsc"] or input.isDown["MenuBack"]
  local backEdge = backDown and not self._backWasDown
  self._backWasDown = backDown
  if backEdge then
    if SPEEDS[self.speedIndex] ~= 0 then
      self.speedIndex = PAUSE_INDEX
      GAME.theme:playMoveSfx()
    else
      GAME.theme:playCancelSfx()
      if self.match then self.match:abort() end
      GAME.navigationStack:pop()
    end
    return true
  end

  -- Available control rows. "play" (take over the focused board) only exists
  -- while paused — that's the gate for the "play from here" fork.
  local rows = { "speed", "player" }
  if SPEEDS[self.speedIndex] == 0 then rows[#rows + 1] = "play" end
  -- keep selection valid if the play row just vanished (un-paused)
  local curIdx = 1
  for i, name in ipairs(rows) do if name == self.selectedRow then curIdx = i end end
  if not rows[curIdx] or rows[curIdx] ~= self.selectedRow then self.selectedRow = rows[1]; curIdx = 1 end

  if input:isPressedWithRepeat("MenuUp") then
    self.selectedRow = rows[(curIdx - 2) % #rows + 1]
    GAME.theme:playMoveSfx()
  elseif input:isPressedWithRepeat("MenuDown") then
    self.selectedRow = rows[curIdx % #rows + 1]
    GAME.theme:playMoveSfx()
  end

  -- Confirm on the play row → take over.
  if self.selectedRow == "play" and (input.isDown["MenuSelect"] or input.isDown["Swap1"]) then
    self:_forkNow()
    return true
  end

  local left  = input:isPressedWithRepeat("MenuLeft")
  local right = input:isPressedWithRepeat("MenuRight")
  if self.selectedRow == "speed" then
    local speed = SPEEDS[self.speedIndex]
    local atStart = self.playbackFrame <= 0
    local atEnd   = self.playbackFrame >= self.lastF
    if left then
      -- at the end while playing forward, reversing direction snaps to pause
      if atEnd and speed > 0 then self.speedIndex = PAUSE_INDEX
      else self.speedIndex = math.max(1, self.speedIndex - 1) end
      GAME.theme:playMoveSfx()
    end
    if right then
      -- at the start while rewinding, reversing direction snaps to pause
      if atStart and speed < 0 then self.speedIndex = PAUSE_INDEX
      else self.speedIndex = math.min(#SPEEDS, self.speedIndex + 1) end
      GAME.theme:playMoveSfx()
    end
  elseif self.match then
    if left  then self.match:cycleSpectatorFocus(-1) end
    if right then self.match:cycleSpectatorFocus(1) end
  end
  return false
end

function ReplaySpectator:update(dt)
  -- A fork swaps GAME.battleRoom to its live room; on return here, restore ours
  -- so the spectator's boards render again.
  if self.spectatorBattleRoom and GAME.battleRoom ~= self.spectatorBattleRoom then
    GAME.battleRoom = self.spectatorBattleRoom
  end
  if self:handleInput() then return end
  if not self.match then return end

  local speed = SPEEDS[self.speedIndex]
  self.playbackFrame = math.min(self.lastF, math.max(0, self.playbackFrame + speed * dt * 60))
  local F = math.floor(self.playbackFrame)

  local br = GAME.battleRoom
  -- feed only genuinely new frames forward, so pops/sounds fire once
  if br and br.applyDisplayEventBatch and F > self.highWaterF then
    while self.feedIndex <= #self.tape and (self.tape[self.feedIndex].snapshot.f or 0) <= F do
      br:applyDisplayEventBatch(self.tape[self.feedIndex])
      self.feedIndex = self.feedIndex + 1
    end
    self.highWaterF = F
  end

  -- leading edge keeps the feed's interpolation; only rewind snaps to a frame
  if br and br._displayStacks and F < self.highWaterF then
    for from, list in pairs(self.byStack) do
      local ds = br._displayStacks[from]
      if ds then
        local k = displayIndexFor(list, F)
        if k then ds:showFrame(list[k].snapshot) end
      end
    end
  end

  self.uiRoot:update(dt)
end

-- Take over the focused board as a live solo game. Pause-only entry point.
function ReplaySpectator:_forkNow()
  local ReplayFork = require("client.src.ReplayFork")
  GAME.theme:playValidationSfx()
  local ok, err = xpcall(ReplayFork.startFromSpectator, debug.traceback, self.replay)
  if not ok then
    require("common.lib.logger").error("ReplaySpectator: play-from-here fork failed: " .. tostring(err))
    GAME.theme:playCancelSfx()
  end
end

-- Test/dev hook: jump straight to the paused "Play as" control (used by the
-- AutoReplay harness to screenshot the entry button).
function ReplaySpectator:_showPlayMenu()
  self.speedIndex = PAUSE_INDEX
  self.selectedRow = "play"
end

function ReplaySpectator:customDraw()
  local speed = SPEEDS[self.speedIndex]
  local rows = {}
  -- "Play as" sits on top (above the speed/playback control) and is an action,
  -- not a left/right adjustable value, so it gets no <  > arrows.
  if speed == 0 then
    rows[#rows + 1] = { text = "Play as " .. focusedPlayerName(self.match), on = self.selectedRow == "play", action = true }
  end
  rows[#rows + 1] = { text = "Speed  " .. ((speed == 0) and "Pause" or (tostring(speed) .. "x")), on = self.selectedRow == "speed" }
  rows[#rows + 1] = { text = focusedPlayerName(self.match), on = self.selectedRow == "player" }
  -- Bottom-anchored above the GameBase spectator hint zone so the extra "Play
  -- as" row (when paused) doesn't overlap the "Switch Player" hint.
  local y = consts.CANVAS_HEIGHT - 64 - #rows * 22
  for _, r in ipairs(rows) do
    -- selection shown by colour, not a pointer: white when active, grey when not
    local color = r.on and {1, 1, 1, 1} or {0.5, 0.5, 0.5, 1}
    local label = r.action and r.text or ("<  " .. r.text .. "  >")
    GraphicsUtil.printf(label, 0, y, consts.CANVAS_WIDTH, "center", color, 1, 10)
    y = y + 22
  end
end

return ReplaySpectator
