-- MockScene: jump straight to a scene populated with fake data, for local layout
-- validation. DEBUG/TEST ONLY — never wired into user-facing navigation. Driven
-- from AppDriver (`mockroom <N> [host]`) so we can screenshot the multiplayer
-- waiting room at 2..7 players without a live server, bot, or second device.
--
-- The waiting room (CharacterSelect2p) only reads battleRoom.players (+ ownerId/
-- mode for the host boot affordance), so a minimal hand-built BattleRoom with N
-- players is enough to exercise the real portrait layout.

local BattleRoom = require("client.src.BattleRoom")
local Player = require("client.src.Player")
local GameModes = require("common.data.GameModes")
local GameBase = require("client.src.scenes.GameBase")
local fileUtils = require("client.src.FileUtils")

local MockScene = {}

local NAMES = {"You", "Komori", "Sasha", "Lee", "Maru", "Yui", "Tomohiro"}
-- realistic-looking stats so the mock roster doesn't read as empty
local RATINGS = {1487, 1605, 1342, 1521, 1198, 1733, 1410}
local WINS = {23, 41, 8, 17, 3, 55, 12}
local LOSSES = {12, 9, 19, 14, 22, 7, 16}

-- Shared: assign devices to local players (kills the device-claim overlay) and
-- push the waiting room.
local function launch(battleRoom)
  local devices = (GAME.input and GAME.input.getAssignableDevices and GAME.input:getAssignableDevices()) or {}
  local di = 1
  for _, p in ipairs(battleRoom:getLocalHumanPlayers()) do
    if devices[di] then
      pcall(function() battleRoom:claimDeviceForPlayer(p, devices[di]) end)
      di = di + 1
    end
  end
  GAME.battleRoom = battleRoom
  GAME.navigationStack:push(require("client.src.scenes.CharacterSelect2p")({battleRoom = battleRoom}))
end

-- Build a waiting room from REAL players in a recorded replay (names, characters,
-- panels, levels, wins from metadata.stacks — the data the engine actually wrote).
-- Picks the replay with the most players unless a path is given. Player 1 is
-- forced local so the editable "your settings" card renders.
---@param opts {path?: string, count?: integer, host?: boolean}?
function MockScene.waitingRoomFromReplay(opts)
  opts = opts or {}
  local data = opts.path and fileUtils.readJsonFileFresh(opts.path)
  if not data then
    -- scan for the replay with the most stacks (best roster to exercise)
    local bestN = 0
    for _, path in ipairs(fileUtils.getFilteredFilesRecursive("replays") or {}) do
      if path:match("%.json$") and not path:match("INCOMPLETE") then
        local d = fileUtils.readJsonFileFresh(path)
        local n = d and d.metadata and d.metadata.stacks and #d.metadata.stacks or 0
        if n > bestN then data, bestN = d, n end
      end
    end
  end
  assert(data and data.metadata and data.metadata.stacks, "no usable replay found")

  local stacks = data.metadata.stacks
  local modeId = GameModes.nameToGameModeId[data.metadata.gameModeName]
  local gameMode = (modeId and GameModes.getPreset(modeId)) or GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS)
  local battleRoom = BattleRoom(gameMode, GameBase)
  battleRoom.online = true

  local n = math.min(#stacks, opts.count or #stacks)
  for i = 1, n do
    local st = stacks[i]
    local player = Player.createLocalPlayerFromConfig()
    player.name = st.name or ("P" .. i)
    player.publicId = st.publicId or (1000 + i)
    player.isLocal = (i == 1)
    player.hasLoaded = true
    if st.characterId and characters[st.characterId] then player:setCharacter(st.characterId) end
    if st.panelId and panels and panels[st.panelId] then player:setPanels(st.panelId) end
    if st.level then player:setLevel(st.level) end
    player.wins = st.wins
    player:setWantsReady(i % 2 == 1)
    battleRoom:addPlayer(player)
  end

  if opts.host then
    battleRoom.ownerId = battleRoom.players[1].publicId
    local m = {}
    for k, v in pairs(gameMode) do m[k] = v end
    m.openRoom = true
    battleRoom.mode = m
  end

  launch(battleRoom)
end

---Build a fake multiplayer waiting room with `count` players and navigate to it.
---@param count integer 2..7
---@param opts {host?: boolean}? host=true makes the local user the room owner of
---  an open room so the per-card boot [x] affordance shows on the other players.
function MockScene.waitingRoom(count, opts)
  opts = opts or {}
  count = math.max(2, math.min(count or 4, 7))

  local gameMode = GameModes.getPreset(GameModes.IDs.TWO_PLAYER_VS)
  local battleRoom = BattleRoom(gameMode, GameBase)
  battleRoom.online = opts.host == true

  for i = 1, count do
    local player
    if i == 1 and opts.host then
      -- host variant: the real local player must be player 1 so the scene's
      -- GAME.localPlayer == ownerId host check passes
      player = GAME.localPlayer
    else
      player = Player.createLocalPlayerFromConfig()
      player.publicId = 1000 + i
      player.isLocal = (i == 1)
    end
    player.name = NAMES[i] or ("P" .. i)
    player.hasLoaded = true
    player.rating = RATINGS[i] or 1300
    player.wins = WINS[i] or 10
    player.losses = LOSSES[i] or 10
    -- alternate ready/not-ready so both badge states are visible at a glance
    player:setWantsReady(i % 3 ~= 0)
    battleRoom:addPlayer(player)
  end

  if opts.host then
    battleRoom.ownerId = GAME.localPlayer.publicId
    -- shallow-copy the mode so flipping openRoom doesn't mutate the shared preset
    local m = {}
    for k, v in pairs(gameMode) do m[k] = v end
    m.openRoom = true
    battleRoom.mode = m
  end

  -- Pre-assign input devices to the local player(s) so the device-claim overlay
  -- (which gates on hasInputConfiguration) never opens — keeps the mock screen
  -- clean for layout screenshots.
  local devices = (GAME.input and GAME.input.getAssignableDevices and GAME.input:getAssignableDevices()) or {}
  local di = 1
  for _, p in ipairs(battleRoom:getLocalHumanPlayers()) do
    if devices[di] then
      pcall(function() battleRoom:claimDeviceForPlayer(p, devices[di]) end)
      di = di + 1
    end
  end

  GAME.battleRoom = battleRoom
  local CharacterSelect2p = require("client.src.scenes.CharacterSelect2p")
  GAME.navigationStack:push(CharacterSelect2p({battleRoom = battleRoom}))
end

return MockScene
