-- Single source of truth for turning a loaded ReplayV3 table into a running
-- scene. Used by ReplayBrowser (player picks a file) and the AutoReplay debug
-- harness (env-driven headless playback) so the two launch paths never drift.
local ClientMatch = require("client.src.ClientMatch")
local GameModes = require("common.data.GameModes")
local ReplayGame = require("client.src.scenes.ReplayGame")
local SoundController = require("client.src.music.SoundController")

local ReplayLauncher = {}

-- Push the scene appropriate to the replay and return the created match.
--   * 2+ player replays with snapshot history play through a spectating
--     BattleRoom (the live spectator render path; BattleRoom is not modified).
--   * solo / input replays re-simulate from inputs in ReplayGame.
---@param replay table a ReplayV3 (already setmetatable'd via createFromTable)
---@return table match
function ReplayLauncher.launch(replay)
  if SoundController then SoundController:stopMusic() end

  if replay.displayHistory and #replay.displayHistory > 0 then
    local BattleRoom = require("client.src.BattleRoom")
    local DisplayClientStack = require("client.src.network.DisplayClientStack")
    local ReplaySpectator = require("client.src.scenes.ReplaySpectator")
    local modeId = GameModes.nameToGameModeId[replay.metadata.gameModeName]
    local gameMode = modeId and GameModes.getPreset(modeId)

    local battleRoom = BattleRoom(gameMode)
    battleRoom.spectating = true
    battleRoom.displayHistoryEnabled = true

    -- hide displayHistory across the call so createFromReplay skips its own
    -- drain; we feed the room the tape ourselves
    local tape = replay.displayHistory
    replay.displayHistory = nil
    local match = ClientMatch.createFromReplay(replay, nil, gameMode)
    replay.displayHistory = tape

    for i = 1, #match.players do battleRoom:addPlayer(match.players[i]) end
    battleRoom.match = match
    battleRoom.state = BattleRoom.states.MatchInProgress
    if match.engine then match.engine.pauseNonLocalSimulation = true end

    battleRoom._displayStacks = {}
    for _, stack in ipairs(match.stacks) do
      local player = stack.player
      local pid = player and (player.publicId or player.playerNumber)
      if pid then
        battleRoom._displayStacks[pid] = DisplayClientStack.new(pid, player, stack)
        stack.canvas = nil
        stack.displayRendered = true
      end
    end

    match.renderDuringPause = true
    match.supportsPause = false
    match:start()
    match:moveStacks()
    GAME.battleRoom = battleRoom
    GAME.navigationStack:push(ReplaySpectator({ match = match, tape = tape, replay = replay }))
    return match
  end

  local match = ClientMatch.createFromReplay(replay)
  match.renderDuringPause = true
  match.supportsPause = true
  match:start()
  GAME.navigationStack:push(ReplayGame({ match = match }))
  return match
end

return ReplayLauncher
