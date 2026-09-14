-- "Play from here": fork a paused multiplayer replay into a live, ephemeral
-- solo game seeded from the focused board's current snapshot. Nothing persists.
--
-- Milestone 1: spawn a solo vsSelf match, rebuild the board (panels + health +
-- speed + level/raise + displacement) from the snapshot. Generator runs fresh
-- from the replay seed (position recovery + recorded garbage land in later
-- milestones). All new code — invoked only from the pause menu, so normal
-- replay viewing is untouched.

local BattleRoom = require("client.src.BattleRoom")
local GameModes = require("common.data.GameModes")
local GeneratorSource = require("common.engine.GeneratorSource")
local PanelStateCodes = require("client.src.network.PanelStateCodes")
local Player = require("client.src.Player")
local TeamUtils = require("common.data.TeamUtils")
local DisplaySnapshotFFI = require("client.src.network.DisplaySnapshotFFI")
local logger = require("common.lib.logger")

local ReplayFork = {}

-- Transient panel animation states settle to a resolved normal block; gone
-- states become empty. Keeps the forked board immediately playable.
local function settleState(code)
  local name = PanelStateCodes.toName(code)
  if name == "dead" or name == "popped" then return nil end -- empty
  return "normal"
end

-- Overwrite an already-built engine board with the snapshot grid.
-- idx = row*width + col, row 0..height+1, col 1..width (matches the capture).
local function injectBoard(engine, snap)
  local width  = snap.w or engine.width or 6
  local height = snap.h or engine.height or 12
  local p = snap.p or {}
  for row = 0, height + 1 do
    local erow = engine.panels and engine.panels[row]
    if erow then
      for col = 1, width do
        local panel = erow[col]
        if panel then
          local cell = p[row * width + col]
          local settled = cell and cell ~= false and cell.c and cell.c ~= 0 and not cell.g
            and settleState(cell.s)
          if settled then
            panel.color = cell.c
            panel.state = settled
            panel.timer = 0
          else
            -- empty / garbage (garbage dropped for milestone 1) / gone
            panel.color = 0
            panel.state = "normal"
            panel.timer = 0
          end
        end
      end
    end
  end
end

-- Pull HUD/raise scalars across so the board plays from the same position.
local function injectScalars(engine, snap)
  if snap.hp then engine.health = snap.hp end
  if snap.sp then engine.speed = snap.sp end
  if snap.d  then engine.displacement = snap.d end
  if snap.st then engine.stop_time = snap.st end
  if snap.ps then engine.pre_stop_time = snap.ps end
  if snap.cr then engine.cur_row = snap.cr end
  if snap.cc then engine.cur_col = snap.cc end
end

-- Locate the spectator's currently-focused board: returns viewStack, snapshot.
local function focusedBoard()
  local br = GAME and GAME.battleRoom
  local match = br and br.match
  if not match or not match.stacks then return nil end
  local focusSlot = match.spectatorFocus
  local chosen
  for _, stack in ipairs(match.stacks) do
    if focusSlot and stack.player and stack.player_number == focusSlot then chosen = stack end
  end
  chosen = chosen or match.stacks[1]
  if not chosen then return nil end
  local pid = chosen.player and (chosen.player.publicId or chosen.player.playerNumber)
  local ds = pid and br._displayStacks and br._displayStacks[pid]
  return chosen, ds and ds.snapshot
end

-- Current replay-frame playhead of the active spectator (the fork point).
local function currentForkFrame(snap)
  local scenes = GAME and GAME.navigationStack and GAME.navigationStack.scenes
  local spec = scenes and scenes[#scenes]
  if spec and spec.playbackFrame then return math.floor(spec.playbackFrame) end
  return (snap and snap.f) or 0
end

---Fork the paused replay into a live game: the focused board becomes a live,
---input-driven local stack; every other board keeps playing as a ghost, fed
---from the replay's remaining displayHistory. One-directional, ephemeral.
---@param replay table the loaded ReplayV3 (metadata.stacks + displayHistory + seed)
---@return boolean ok
function ReplayFork.startFromSpectator(replay)
  local srcStack, snap = focusedBoard()
  if not srcStack or not snap then
    logger.warn("ReplayFork: no focused board/snapshot to fork from")
    return false
  end
  if not (replay and replay.metadata and replay.metadata.stacks) then
    logger.warn("ReplayFork: replay metadata missing; cannot build ghosts")
    return false
  end
  local focusedPid = srcStack.player and (srcStack.player.publicId or srcStack.player.playerNumber)
  local forkFrame = currentForkFrame(snap)

  local meta = replay.metadata
  local modeId = GameModes.nameToGameModeId[meta.gameModeName]
  local mode = modeId and GameModes.getPreset(modeId)
  if not mode then
    logger.warn("ReplayFork: unknown gameMode " .. tostring(meta.gameModeName))
    return false
  end
  if not GAME.localPlayer then
    logger.warn("ReplayFork: GAME.localPlayer not initialized; cannot take over")
    return false
  end

  -- Build the hybrid room: focused = local (live + input), rest = remote ghosts.
  local ReplayForkGame = require("client.src.scenes.ReplayForkGame")
  local br = BattleRoom(mode, ReplayForkGame)
  br.displayHistoryEnabled = DisplaySnapshotFFI.FFI_SUPPORTED == true
  if replay.panelSource and replay.panelSource.seed then
    br.panelSource = GeneratorSource(replay.panelSource.seed, replay.panelSource.shockEnabled)
  end

  -- The taken-over board uses GAME.localPlayer — the existing, input-configured
  -- local player the normal game flow uses — so its already-claimed input feeds
  -- through (a fresh player has no device and freezes). Stamp the focused
  -- identity/level onto it for this match (cosmetic + raise rate).
  local focusedOrigIndex -- the taken-over board's index in the ORIGINAL match (for garbage routing)
  for _, sm in ipairs(meta.stacks) do
    if sm.publicId == focusedPid then
      focusedOrigIndex = sm.stackIndex
      local p = GAME.localPlayer
      p:setCharacter(sm.characterId)
      if sm.panelId then p:setPanels(sm.panelId) end
      if sm.level then p:setLevel(sm.level) end
      if sm.seatId then TeamUtils.assignSeatIdentity(p, sm.seatId) end
      br:addPlayer(p)
    else
      br:addPlayer(Player.createFromReplayMetadata(sm))
    end
  end

  -- Restore GAME.localPlayer's input device the same way the normal local-game
  -- flow does (it carries lastUsedInputConfiguration from prior play).
  br:restoreInputConfigurations()

  -- restoreInputConfigurations only re-binds a device the player used in a PRIOR
  -- local match this session. Forking straight from a replay (the usual path:
  -- boot -> browser -> spectate -> fork) means GAME.localPlayer never claimed one,
  -- so it'd have no input device and the live stack freezes (send_controls returns
  -- early on nil input). Claim the first free device explicitly in that case.
  if not GAME.localPlayer.inputConfiguration then
    for _, device in ipairs(GAME.input:getAssignableDevices()) do
      if not device.claimed then br:claimDeviceForPlayer(GAME.localPlayer, device); break end
    end
  end

  -- Ghost tape: every board except the taken-over one. The scene fast-forwards
  -- it from frame 0 to forkFrame, then plays at 1x.
  local ghostTape = {}
  for _, b in ipairs(replay.displayHistory or {}) do
    if b.from ~= focusedPid then ghostTape[#ghostTape + 1] = b end
  end

  -- Recorded garbage the ghosts threw AT the taken-over board, from the fork
  -- point on. Empty for old replays (no garbage log) → no incoming.
  local forkGarbage = {}
  local glog = replay.crossPlayerEvents and replay.crossPlayerEvents.garbage
  if glog and focusedOrigIndex then
    for _, ev in ipairs(glog) do
      if (ev.senderFrame or 0) >= forkFrame and type(ev.recipients) == "table" then
        for _, r in ipairs(ev.recipients) do
          if r == focusedOrigIndex then forkGarbage[#forkGarbage + 1] = ev; break end
        end
      end
    end
    table.sort(forkGarbage, function(a, b) return (a.senderFrame or 0) < (b.senderFrame or 0) end)
  end

  br.sceneParameters = { forkTape = ghostTape, forkFrame = forkFrame, forkGarbage = forkGarbage }

  GAME.battleRoom = br
  br:startMatch() -- builds hybrid match, starts, sets up ghost _displayStacks, pushes ReplayForkGame

  -- Inject the focused board into the live local stack (engine exists post-start).
  local match = br.match
  local localStack
  for _, st in ipairs(match.stacks) do if st.is_local then localStack = st; break end end
  if localStack and localStack.engine then
    injectBoard(localStack.engine, snap)
    injectScalars(localStack.engine, snap)
  else
    logger.warn("ReplayFork: no local stack to inject into")
  end
  logger.info(string.format("ReplayFork: hybrid fork at frame %d, %d ghost batches, %d incoming-garbage events, local=%s",
    forkFrame, #ghostTape, #forkGarbage, tostring(localStack and localStack.player and localStack.player.name)))
  return true
end

return ReplayFork
