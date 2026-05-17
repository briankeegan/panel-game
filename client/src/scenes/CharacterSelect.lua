local consts = require("common.engine.consts")
local input = require("client.src.inputManager")
local class = require("common.lib.class")
local logger = require("common.lib.logger")
local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local Scene = require("client.src.scenes.Scene")
local ui = require("client.src.ui")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local Character = require("client.src.mods.Character")
local TeamUtils = require("common.data.TeamUtils")
local LevelPresets = require("common.data.LevelPresets")
local InputDeviceOverlay = require("client.src.scenes.components.InputDeviceOverlay")

-- Flavor text shown under each player's name before they've played a match
-- this session, in place of the (still-empty) position / match-out rows.
-- Deterministic per player via a name-byte-sum hash so it doesn't flicker.
local FLAVOR_QUOTES = {
  -- general
  "Stack high, fall slow.",
  "When in doubt, swap it out.",
  "Every chain starts small.",
  "Patience builds combos.",
  "Garbage in, garbage out.",
  "Look before you swap.",
  "Slow is smooth. Smooth is chain.",
  "Don't take it for granite.",
  "Be the panel.",
  "Keep calm and clear on.",
  "Two panels, one match.",
  "Climb every column.",
  "Today's stack, tomorrow's combo.",
  "Even level 8 starts at 1.",
  "Mind the gap.",
  "Drop. Match. Repeat.",
  "Chains over matches.",
  "The early swap catches the combo.",
  "It's not the stack, it's the chain.",
  "Block by block.",
  "Find your chain.",
  "Swap fast, think faster.",
  "A combo a day.",
  "Stay grounded.",
  "Rome wasn't stacked in a day.",
  "Top out? More like top wow.",
  "Panel in haste, repent at topout.",
  "Behind every chain is a swap.",
  "Don't just clear — combo.",
  "The best time to swap was a frame ago.",
  -- catch
  "Always be catching.",
  "Catch you on the swap side.",
  "A good catch is half the chain.",
  "Catch flights, not feelings. Also catch panels.",
  -- chain
  "Mystery chains: when the game stops counting.",
  "Chains heavier than your stack.",
  "x13 or bust.",
  "Forge your chains. Drop them on others.",
  "Chain reactions. Zero regrets.",
  "Skill chains? More like skill thrills.",
  -- clear
  "Clear conscience, clear panels.",
  "The path is clear. (Mostly.)",
  "Clearance sale: everything must combo.",
  -- combo
  "Combo, ergo sum.",
  "Five combos and chill.",
  "Combo see, combo do.",
  "+5 makes the heart grow fonder.",
  -- combo storm
  "Forecast: combo storm. Pack a chain.",
  "Eye of the combo storm.",
  "When it storms, it combos.",
  -- DAS
  "Hold the direction, hold the dream.",
  "DAS-tardly fast.",
  "DAS-ing through the rows.",
  -- downstacking
  "What goes up must downstack.",
  "Downstack or down go you.",
  "Downstacking: gravity's wingman.",
  -- factory
  "Factory settings: full pressure.",
  "Open the factory. Close the lid on hope.",
  "The factory never sleeps.",
  -- frame trick
  "Frame-perfect, frame-perfectionist.",
  "One frame from glory.",
  "Live by the frame, die by the frame.",
  -- garbage
  "Garbage in, garbage chain out.",
  "Treasure your garbage. It chains.",
  "One player's garbage, another player's combo.",
  "Wasting garbage is just waste.",
  -- ghost
  "Believe in ghost matches.",
  "Who you gonna call? Ghost matches.",
  "Ghosts in the panel.",
  -- insert
  "Insert chain here.",
  "Insert coin, receive combo.",
  -- locked out
  "Locked out? Read the panels.",
  "No moves? Make some.",
  "Locked out of luck.",
  -- shake time
  "Shake it off. Shake time off.",
  "Shake, rattle, and clear.",
  "Shake what your garbage gave you.",
  "Shake time, fake time.",
  -- shogun
  "Shogun: chains with honor.",
  "Tier chain, never tear change.",
  -- slide
  "Slide into your opponent's garbage.",
  "Slide right, swap left.",
  "Slide to win.",
  -- stealth
  "Stealth swap, loud impact.",
  "Now you see the panel, now you don't.",
  "Stealth chain, no shame.",
  "Two spaces. One vibe.",
  -- stop time
  "Stop time, smell the panels.",
  "Stop time is god mode lite.",
  "Time stops for combos.",
  -- tier
  "Top tier, top fear.",
  "Build tiers, not fears.",
  "Tier and present danger.",
  "Tiers of joy.",
  -- time delay
  "Time delays favor the patient.",
  "Lag is just slow strategy.",
  "Time delay, chain replay.",
  -- topped out
  "Topped out? Top OFF first.",
  "Don't get topped out. Get topped in.",
  "Topped out is a state of mind.",
  -- tornado
  "Tornado warning: chains incoming.",
  "Eye of the tornado, peace in the panels.",
  "There's no place like combo.",
  -- tower
  "Towers fall. Stacks rise.",
  "A tower a day keeps the garbage away.",
  "Towers above, garbage beneath.",
  "The Tower of Panel.",
  -- transition
  "Mind the transition.",
  "Transition clear: the gentleman's chain.",
  -- general (puns)
  "Panel-mony in motion.",
  "Stack to the future.",
  "May the swaps be with you.",
  "Live, laugh, panel.",
  "Carpe panel.",
  "Stop and smell the chains.",
  "Speak softly, carry a big chain.",
  "Easy come, easy combo.",
  "Don't panel-ic.",
  "Keep your friends close, your garbage closer.",
  "Panel, set, match.",
  "Stack-tical genius.",
  "Better swap than sorry.",
  "Mind over panels.",
  "Chain of thought, chain of panels.",
  "Panel pals, garbage rivals.",
  "Panel up. Swap forward.",
  "Combo-pendium of wisdom.",
  "Practice makes panel.",
  "It's a panel-demic.",
}

local function pickFlavorQuote(name)
  local h = 0
  for i = 1, #name do
    h = h + string.byte(name, i)
  end
  return FLAVOR_QUOTES[(h % #FLAVOR_QUOTES) + 1]
end

-- The character select screen scene
---@class CharacterSelect : Scene
---@field backgroundImg table
---@field players Player[]
---@field battleRoom BattleRoom
---@field refreshRoster fun(self: CharacterSelect)? duck-typed in subclasses (open-FFA drop-in)
---@field lastScore any? set in CharacterSelectVsSelf to display the last-match score
---@field record any? set in CharacterSelectVsSelf to display the personal record
local CharacterSelect = class(
---@param self CharacterSelect
function(self, sceneParams)
  self.backgroundImg = themes[config.theme].images.bg_select_screen
  self.music = "select_screen"
  self.fallbackMusic = "main"
  self.battleRoom = sceneParams.battleRoom
  self.players = shallowcpy(self.battleRoom.players)
  self:load()
end, Scene)

-- begin abstract functions

-- Initalization specific to the child scene
function CharacterSelect:customLoad()
end

---@param playerIndex integer?
---@return love.Texture
local function getPlayerNumberIcon(playerIndex)
  playerIndex = playerIndex or 1
  local icon = themes[config.theme]:getPlayerNumberIcon(playerIndex)
  -- Fallback: if icon is nil or theme has no 3P icon, return player 1 icon
  if not icon and playerIndex > 1 then
    icon = themes[config.theme]:getPlayerNumberIcon(1)
  end
  return icon
end
-- updates specific to the child scene
function CharacterSelect:customUpdate(sceneParams)
  -- error("The function customUpdate needs to be implemented on the scene")
end

function CharacterSelect:customDraw()

end

function CharacterSelect:refresh()
end

-- end abstract functions

-- Re-sorts self.players to match battleRoom.players, putting the local player first.
-- Called once during load() and again whenever the roster changes (open FFA drop-in).
function CharacterSelect:syncPlayersFromBattleRoom()
  self.players = shallowcpy(self.battleRoom.players)
  table.sort(self.players, function(a, b)
    if a.isLocal == b.isLocal then
      return a.playerNumber < b.playerNumber
    else
      return a.isLocal
    end
  end)
end

function CharacterSelect:load()
  self:syncPlayersFromBattleRoom()

  self.ui = {}
  self.ui.cursors = {}
  self.ui.characterIcons = {}
  self.ui.playerInfos = {}
  self:customLoad()

  self:createInputDeviceOverlay()

  self:setChangeInputButtonVisibility(false)
  self:setChangeInputButtonVisibleIfNeeded()

  for _, player in ipairs(self.players) do
    if player:isHuman() then
      if player.isLocal then
        self:initializeFromLocalPlayerSettings(player)
      end
      player:connectSignal("levelDataChanged", self, self.onLevelDataChanged)
      self:onLevelDataChanged(player.settings.levelData, player)
    end
  end

  -- Open FFA / drop-in modes need to re-render when the roster changes.
  -- Child scenes implement refreshRoster() to rebuild their per-player widgets.
  if self.battleRoom and self.battleRoom.connectSignal then
    self.battleRoom:connectSignal("rosterChanged", self, self.onRosterChanged)
  end
end

function CharacterSelect:onRosterChanged()
  self:syncPlayersFromBattleRoom()

  -- Re-attach levelDataChanged on any newly added players so their styles stay in sync.
  for _, player in ipairs(self.players) do
    if player:isHuman() and not player._charSelectLevelHooked then
      player:connectSignal("levelDataChanged", self, self.onLevelDataChanged)
      player._charSelectLevelHooked = true
    end
  end

  if self.refreshRoster then
    self:refreshRoster()
  end
end

function CharacterSelect:onLevelDataChanged(levelData, player)
  local presetInfo = LevelPresets.getStyleAndPreset(levelData)

  if not presetInfo then
    -- Custom levelData, default to current settings
    return
  end

  if presetInfo.style == GameModes.Styles.MODERN then
    player:setStyle(GameModes.Styles.MODERN)
    if presetInfo.level then
      player:setLevel(presetInfo.level)
    end
  else
    player:setStyle(GameModes.Styles.CLASSIC)
    if presetInfo.difficulty then
      player:setDifficulty(presetInfo.difficulty)
    end
  end

  self:refresh()
end

function CharacterSelect:initializeFromLocalPlayerSettings(player)
  player:setStyle(GameModes.Styles.MODERN)
  player:setLevel(player.settings.level)
  player:setLevelData(LevelPresets.getModern(player.settings.level))
end

---@param player Player
---@return UiElement playerIcon
function CharacterSelect:createPlayerIcon(player)
  local playerIcon = ui.UiElement({hFill = true, vFill = true})

  local teamBorderColor = self:teamBorderColorForPlayer(player)
  local selectedCharacterIcon = ui.ImageContainer({
    hFill = true,
    vFill = true,
    image = characters[player.settings.selectedCharacterId].images.icon,
    drawBorders = true,
    outlineColor = teamBorderColor or {1, 1, 1, 1}
  })

  -- In shared team modes thicken the border so the team affiliation reads at a
  -- glance. ImageContainer normally paints a 1px line — replace its border
  -- pass with multiple stacked rectangles to get a 4px team-colored frame.
  if teamBorderColor then
    local BORDER_THICKNESS = 4
    selectedCharacterIcon.drawSelf = function(elem)
      if elem.image then
        GraphicsUtil.draw(elem.image, elem.x, elem.y, 0, elem.scale or 1, elem.scale or 1)
      end
      for w = 0, BORDER_THICKNESS - 1 do
        GraphicsUtil.drawRectangle("line",
          elem.x + w, elem.y + w,
          elem.width - 2 * w, elem.height - 2 * w,
          teamBorderColor[1], teamBorderColor[2], teamBorderColor[3], teamBorderColor[4] or 1)
      end
      GraphicsUtil.setColor(1, 1, 1, 1)
    end
  end

   -- character image
   selectedCharacterIcon.onCharacterChanged = function(selfElement, characterId)
    selfElement:setImage(characters[characterId].images.icon)
  end
  player:connectSignal("selectedCharacterIdChanged", selectedCharacterIcon, selectedCharacterIcon.onCharacterChanged)

  playerIcon:addChild(selectedCharacterIcon)

  -- level icon
  if player.settings.style == GameModes.Styles.MODERN and player.settings.level then
    local levelIcon = ui.ImageContainer({
      image = themes[config.theme].images.IMG_levels[player.settings.level],
      hAlign = "right",
      vAlign = "bottom",
      x = -2,
      y = -2
    })

    levelIcon.onLevelChanged = function(selfElement, level)
      selfElement:setImage(themes[config.theme].images.IMG_levels[level])
    end
    player:connectSignal("levelChanged", levelIcon, levelIcon.onLevelChanged)

    playerIcon:addChild(levelIcon)
  end

  -- player number icon
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    hAlign = "left",
    vAlign = "bottom",
    x = 2,
    y = -2,
    scale = 3
  })
  playerIcon:addChild(playerNumberIcon)

  -- player name above icon; wins shown via the adjacent info card (every
  -- player gets one in CharacterSelect2p, regardless of player count).
  local playerName = ui.Label({
    text = player.name,
    translate = false,
    hAlign = "center",
    vAlign = "top",
  })
  playerIcon:addChild(playerName)

  -- load icon
  local loadIcon = ui.ImageContainer({
    image = themes[config.theme].images.IMG_loading,
    hAlign = "center",
    vAlign = "center",
    hFill = true,
    vFill = true,
    isVisible = not player.hasLoaded
  })
  playerIcon:addChild(loadIcon)

  -- ready icon
  local readyIcon = ui.ImageContainer({
    image = themes[config.theme].images.IMG_ready,
    hAlign = "center",
    vAlign = "center",
    hFill = true,
    vFill = true,
    isVisible = player.settings.wantsReady and player.hasLoaded
  })
  playerIcon:addChild(readyIcon)

  loadIcon.onLoadedChanged = function(selfElement, loaded)
    selfElement:setVisibility(not loaded)
    readyIcon:setVisibility(loaded and player.settings.wantsReady)
  end
  player:connectSignal("hasLoadedChanged", loadIcon, loadIcon.onLoadedChanged)
  readyIcon.onReadyChanged = function(selfElement, wantsReady)
    selfElement:setVisibility(wantsReady and player.hasLoaded)
  end
  player:connectSignal("wantsReadyChanged", readyIcon, readyIcon.onReadyChanged)

  return playerIcon
end

---@return TextButton readyButton
function CharacterSelect:createReadyButton()
  local readyButton = ui.TextButton({
    hFill = true,
    vFill = true,
    label = ui.Label({text = "ready"}),
    backgroundColor = {1, 1, 1, 0},
    outlineColor = {1, 1, 1, 1}
  })

  local scene = self

  -- assign player generic callback
  readyButton.onClick = function(self, inputSource, holdTime)
    -- Dead local player came back to the waiting room while teammates are
    -- still fighting. The room's match is still alive on BattleRoom — clicking
    -- ready here means "take me back to watch", not "start a new match".
    -- Push a fresh game scene that renders the in-progress match; the dead
    -- player can use the spectator left/right arrows to cycle focus.
    if GAME.battleRoom and GAME.battleRoom.match then
      GAME.theme:playValidationSfx()
      local gameScene = scene.battleRoom:createScene(GAME.battleRoom.match)
      if gameScene then
        gameScene:load()
        GAME.navigationStack:push(gameScene)
      end
      return
    end

    -- Voided rooms (someone left mid-room) can't start a new match — server's
    -- Room:start_match refuses them. Swallow the click on the client side too so
    -- we don't send a pointless menu_state update.
    if GAME.battleRoom and GAME.battleRoom.isVoided and GAME.battleRoom:isVoided() then
      GAME.theme:playCancelSfx()
      return
    end
    local player
    if inputSource and inputSource.player then
      player = inputSource.player
    else
      player = GAME.localPlayer
    end
    player:setWantsReady(not player.settings.wantsReady)
    GAME.theme:playValidationSfx()
  end
  readyButton.onSelect = readyButton.onClick

  return readyButton
end

---@return TextButton leaveButton
function CharacterSelect:createLeaveButton()
  leaveButton = ui.TextButton({
    hFill = true,
    vFill = true,
    label = ui.Label({text = "leave"}),
    backgroundColor = {1, 1, 1, 0},
    outlineColor = {1, 1, 1, 1},
    onClick = function()
        GAME.theme:playCancelSfx()
        self:leave()
      end
  })
  leaveButton.onSelect = leaveButton.onClick

  return leaveButton
end

---@param player Player
---@param width number
---@return UiElement stageCarousel
function CharacterSelect:createStageCarousel(player, width)
  local stageCarousel = ui.StageCarousel({isEnabled = player.isLocal, hAlign = "center", vAlign = "center", width = width, vFill = true})
  stageCarousel:loadCurrentStages()

  -- stage carousel
  stageCarousel.onSelectCallback = function()
    -- Just update on every passenger change
  end

  stageCarousel.onBackCallback = function()
    -- Just update on every passenger change
  end

  stageCarousel.onPassengerUpdateCallback = function(carousel, selectedPassenger)
    player:setStage(selectedPassenger.id)
    player:refreshStage()
  end

  stageCarousel:setPassengerById(player.settings.selectedStageId)

  -- to update the UI if code gets changed from the backend (e.g. network messages)
  player:connectSignal("selectedStageIdChanged", stageCarousel, stageCarousel.setPassengerById)

  -- player number icon
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    scale = 2,
  })

  if #self.players > 1 then
    playerNumberIcon.hAlign = "center"
    playerNumberIcon.vAlign = "top"
    playerNumberIcon.y = 2
  else
    playerNumberIcon.hAlign = "left"
    playerNumberIcon.vAlign = "center"
    playerNumberIcon.x = (width - stageCarousel:getSelectedPassenger().image.width) / 2 - playerNumberIcon.width - 4
  end

  stageCarousel.playerNumberIcon = playerNumberIcon
  stageCarousel:addChild(stageCarousel.playerNumberIcon)

  return stageCarousel
end

function CharacterSelect:createInputDeviceOverlay()

  self.inputDeviceOverlay = InputDeviceOverlay({
    players = self.battleRoom.players,
    onClose = function()
      self:onInputDeviceOverlayClosed()
    end,
    onCancel = function()
      self:leave()
    end
  })
  self.uiRoot:addChild(self.inputDeviceOverlay)
end

function CharacterSelect:onInputDeviceOverlayClosed()
  self:setChangeInputButtonVisibleIfNeeded()
end

function CharacterSelect:setChangeInputButtonVisibleIfNeeded()
  if self.ui and self.ui.changeInputButton then
    if #self.battleRoom:getLocalHumanPlayers() > 0 then
      self.ui.changeInputButton:setVisibility(true)
    end
  end
end

function CharacterSelect:setChangeInputButtonVisibility(isVisible)
  if self.ui and self.ui.changeInputButton then
    self.ui.changeInputButton:setVisibility(isVisible)
  end
end

function CharacterSelect:createChangeInputButton()
  return ui.ChangeInputButton({
    hFill = true,
    vFill = true,
    players = self.battleRoom.players,
    openInputDeviceOverlay = function ()
      self.inputDeviceOverlay:open()
    end
  })
end

local super_select_pixelcode = [[
      uniform float percent;
      vec4 effect( vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords )
      {
          vec4 c = Texel(tex, texture_coords) * color;
          if( texture_coords.x < percent )
          {
            return c;
          }
          float ret = (c.x+c.y+c.z)/3.0;
          return vec4(ret, ret, ret, c.a);
      }
  ]]

---@return Button[] characterButtons
function CharacterSelect:getCharacterButtons()
  local characterButtons = {}
  local enableButtons = self.battleRoom:hasLocalPlayer()

  for i = 0, #visibleCharacters do
    local characterButton = ui.Button({
      hFill = true,
      vFill = true,
      isEnabled = enableButtons,
    })

    local character
    if i == 0 then
      character = Character.getRandom()
    else
      character = characters[visibleCharacters[i]]
    end

    characterButton.characterId = character.id
    characterButton.image = ui.ImageContainer({image = character.images.icon, hFill = true, vFill = true})
    characterButton:addChild(characterButton.image)
    characterButton.label = ui.Label({text = character.display_name, translate = character.id == consts.RANDOM_CHARACTER_SPECIAL_VALUE, vAlign = "top", hAlign = "center", wrap = true})
    characterButton:addChild(characterButton.label)

    if character.flag and themes[config.theme].images.flags[character.flag] then
      characterButton.flag = ui.ImageContainer({image = themes[config.theme].images.flags[character.flag], vAlign = "bottom", hAlign = "right", x = -2, y = -2, width = 16, height = 16})
      characterButton:addChild(characterButton.flag)
    end

    if character.stage and stages[character.stage] then
      -- draw the stage icon in the center
      characterButton.stageIcon = ui.ImageContainer({image = stages[character.stage].images.thumbnail, vAlign = "bottom", hAlign = "center", y = -2, width = 32, height = 16})
      characterButton:addChild(characterButton.stageIcon)
    end

    if character.panels and panels[character.panels] then
      local panels = panels[character.panels]
      local dpiscale = panels.sheets[1]:getDPIScale()
      local filterMin, filterMag = panels.sheets[1]:getFilter()

      local panelImage = GraphicsUtil.renderToTexture(
        panels.size,
        panels.size,
        function()
          panels:drawPanelFrame(1, "normal", 0, 0, panels.size)
        end,
        dpiscale,
        filterMin,
        filterMag
      )

      characterButton.panelIcon = ui.ImageContainer({image = panelImage, vAlign = "bottom", hAlign = "left", x = 2, y = -2, width = 16, height = 16})
      characterButton:addChild(characterButton.panelIcon)
    end

    characterButtons[#characterButtons + 1] = characterButton
  end

  -- assign player generic callbacks
  for i = 1, #characterButtons do
    local characterButton = characterButtons[i]
    characterButton.onClick = function(selfElement, inputSource, holdTime)
      local character = characters[selfElement.characterId]
      local player
      if inputSource and inputSource.player then
        player = inputSource.player
      elseif tableUtils.trueForAny(self.players, function(p) return p == GAME.localPlayer end) then
         player = GAME.localPlayer
      else
        return
      end

      if character then
        if character:canSuperSelect() and holdTime > consts.SUPER_SELECTION_START + consts.SUPER_SELECTION_DURATION then
          -- super select
          if character.panels and panels[character.panels] then
            player:setPanels(character.panels)
          end
          if character.stage and stages[character.stage] then
            player:setStage(character.stage)
          end
        end
        character:playSelectionSfx()
      else
        GAME.theme:playValidationSfx()
      end

      player:setCharacter(selfElement.characterId)
      player:refreshCharacter()
      player.cursor:updatePosition(9, 2, true)
    end

    if characters[characterButton.characterId] and characters[characterButton.characterId]:canSuperSelect() then
      self.applySuperSelectInteraction(characterButton)
    else
      characterButton.onSelect = characterButton.onClick
    end
  end

  return characterButtons
end

local function updateSuperSelectShader(image, timer)
  if timer > consts.SUPER_SELECTION_START then
    if image.isVisible == false then
      image:setVisibility(true)
    end
    local progress = (timer - consts.SUPER_SELECTION_START) / consts.SUPER_SELECTION_DURATION
    if progress <= 1 then
      image.shader:send("percent", progress)
    end
  else
    if image.isVisible then
      image:setVisibility(false)
    end
    image.shader:send("percent", 0)
  end
end

---@param characterButton Button
function CharacterSelect.applySuperSelectInteraction(characterButton)
  -- creating the super select image + shader
  local superSelectImage = ui.ImageContainer({image = themes[config.theme].images.IMG_super, hFill = true, vFill = true, hAlign = "center", vAlign = "center"})
  superSelectImage.shader = love.graphics.newShader(super_select_pixelcode)
  superSelectImage.drawSelf = function(self)
    GraphicsUtil.setShader(self.shader)
    GraphicsUtil.draw(self.image, self.x, self.y, 0, self.scale, self.scale)
    GraphicsUtil.setShader()
  end

  -- add it to the button
  characterButton.superSelectImage = superSelectImage
  characterButton:addChild(characterButton.superSelectImage)
  superSelectImage:setVisibility(false)

  -- set the generic update function
  characterButton.updateSuperSelectShader = updateSuperSelectShader

  -- touch interaction
  -- by implementing onHold we can provide updates to the shader
  characterButton.onHold = function(self, timer)
    self.updateSuperSelectShader(self.superSelectImage, timer)
  end

  -- we need to override the standard onRelease to reset the shader
  ---@diagnostic disable-next-line: duplicate-set-field
  characterButton.onRelease = function(self, x, y, timeHeld)
    self.updateSuperSelectShader(self.superSelectImage, 0)
    if self:inBounds(x, y) then
      self:onClick(input.mouse, timeHeld)
    end
  end

  -- keyboard / controller interaction
  -- by applying focusable we can turn it into an "on release" interaction rather than on press by taking control of input interpretation
  ui.Focusable(characterButton)
  characterButton.holdTime = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  characterButton.receiveInputs = function(self, inputs, dt)
    if inputs.isPressed["Swap1"] then
      -- measure the time the press is held for
      self.holdTime = self.holdTime + dt
    else
      self:yieldFocus()
      -- apply the actual click on release with the held time and reset it afterwards
      self:onClick(inputs, self.holdTime)
      self.holdTime = 0
    end
    self.updateSuperSelectShader(self.superSelectImage, self.holdTime)
  end
end

function CharacterSelect:createCharacterGrid(characterButtons, grid, width, height)
  local characterGrid = ui.PagedUniGrid({x = 0, y = 0, unitSize = grid.unitSize, gridWidth = width, gridHeight = height, unitMargin = grid.unitMargin})

  for i = 1, #characterButtons do
    characterGrid:addElement(characterButtons[i])
  end

  return characterGrid
end

function CharacterSelect:createPageIndicator(pagedUniGrid)
  local pageCounterLabel = ui.Label({
    text = loc("page") .. " " .. pagedUniGrid.currentPage .. "/" .. #pagedUniGrid.pages,
    hAlign = "center",
    vAlign = "top",
    translate = false
  })
  pageCounterLabel.onPageChanged = function(selfElement, grid, page)
    selfElement:setText(loc("page") .. " " .. page .. "/" .. #grid.pages)
  end
  pagedUniGrid:connectSignal("pageTurned", pageCounterLabel, pageCounterLabel.onPageChanged)
  return pageCounterLabel
end

function CharacterSelect:createPageTurnButtons(pagedUniGrid)
  local x, y = pagedUniGrid:getScreenPos()
  pagedUniGrid.pageTurnButtons.left.x = x - pagedUniGrid.unitSize
  pagedUniGrid.pageTurnButtons.right.x = x + pagedUniGrid.width + pagedUniGrid.unitSize / 2
  pagedUniGrid.pageTurnButtons.left.y = y + pagedUniGrid.height / 2 - pagedUniGrid.unitSize / 4
  pagedUniGrid.pageTurnButtons.right.y = y + pagedUniGrid.height / 2 - pagedUniGrid.unitSize / 4

  self.uiRoot:addChild(pagedUniGrid.pageTurnButtons.left)
  self.uiRoot:addChild(pagedUniGrid.pageTurnButtons.right)
  return pagedUniGrid.pageTurnButtons
end

function CharacterSelect:createCursor(grid, player)
  local cursor = ui.GridCursor({
    grid = grid,
    activeArea = {x1 = 1, y1 = 2, x2 = 9, y2 = 5},
    translateSubGrids = true,
    startPosition = {x = 9, y = 2},
    player = player,
    -- this needs to be index, not playerNumber, as playerNumber is a server prop
    frameImages = themes[config.theme]:getGridCursor(tableUtils.indexOf(self.players, player)),
  })

  player:connectSignal("wantsReadyChanged", cursor, cursor.setRapidBlinking)

  cursor.escapeCallback = function()
    GAME.theme:playCancelSfx()
    if cursor.selectedGridPos.x == 9 and cursor.selectedGridPos.y == 6 then
      self:leave()
    elseif player.settings.wantsReady then
      player:setWantsReady(false)
    else
      cursor:updatePosition(9, 6, false)
    end
  end

  player:connectSignal("wantsReadyChanged", cursor, cursor.trap)

  grid:addChild(cursor)

  return cursor
end

function CharacterSelect:createPanelCarousel(player, height)
  local panelCarousel = ui.PanelCarousel({isEnabled = player.isLocal, hAlign = "center", vAlign = "top", hFill = true, height = height})
  panelCarousel:setColorCount(player.settings.levelData.colors)
  panelCarousel:loadPanels()

  -- panel carousel
  panelCarousel.onSelectCallback = function()
    -- Just update on every passenger change
  end

  panelCarousel.onBackCallback = function()
    -- Just update on every passenger change
  end

  panelCarousel.onPassengerUpdateCallback = function(carousel, selectedPassenger)
    player:setPanels(selectedPassenger.id)
  end

  panelCarousel:setPassengerById(player.settings.panelId)

  local updateColor = function(carousel, levelData)
    carousel:setColorCount(levelData.colors)
  end

  local updatePanelSelection = function(carousel, panelId)
    carousel:setPassengerById(panelId)
  end

  -- to update the UI if code gets changed from the backend (e.g. network messages)
  player:connectSignal("levelDataChanged", panelCarousel, updateColor)
  player:connectSignal("panelIdChanged", panelCarousel, updatePanelSelection)

  -- player number icon
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    hAlign = "left",
    vAlign = "center",
    scale = 2,
    x = 2
  })

  panelCarousel.playerNumberIcon = playerNumberIcon
  panelCarousel:addChild(panelCarousel.playerNumberIcon)

  return panelCarousel
end

---@param player Player
---@param imageWidth number
---@param height number
---@return UiElement levelSliderContainer
function CharacterSelect:createLevelSlider(player, imageWidth, height)
  local levelSlider = ui.LevelSlider({
    isEnabled = player.isLocal,
    tickLength = imageWidth,
    value = player.settings.level,
    onValueChange = function(s)
      GAME.theme:playMoveSfx()
    end,
    hAlign = "center",
    vAlign = "center",
  })

  ui.Focusable(levelSlider)
  ---@diagnostic disable-next-line: duplicate-set-field
  levelSlider.receiveInputs = function(self, inputs)
    if inputs:isPressedWithRepeat("Left") then
      self:setValue(self.value - 1)
    end

    if inputs:isPressedWithRepeat("Right") then
      self:setValue(self.value + 1)
    end

    if inputs.isDown["Swap2"] then
      if self.onBackCallback then
        self:onBackCallback()
      end
      GAME.theme:playCancelSfx()
      self:yieldFocus()
    end

    if inputs.isDown["Swap1"] or inputs.isDown["Start"] then
      if self.onSelectCallback then
        self:onSelectCallback()
      end
      GAME.theme:playValidationSfx()
      self:yieldFocus()
    end
  end

  -- level slider
  levelSlider.onSelectCallback = function(self)
    player:setLevel(self.value)
    player:setLevelData(LevelPresets.getModern(self.value))
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  levelSlider.setValueFromPos = function(self, x)
    local screenX, screenY = self:getScreenPos()
    self:setValue(math.floor((x - screenX) / self.tickLength) + self.min)
    player:setLevel(self.value)
    player:setLevelData(LevelPresets.getModern(self.value))
  end

  levelSlider.onBackCallback = function(self)
    self:setValue(player.settings.level)
  end

  -- wrap in an extra element so we can offset properly as levelslider is fixed height + width
  local uiElement = ui.UiElement({height = height, hFill = true})
  ui.Focusable(uiElement)
  uiElement.levelSlider = levelSlider
  uiElement.levelSlider.yieldFocus = function()
    uiElement:yieldFocus()
  end
  uiElement:addChild(levelSlider)
  uiElement.receiveInputs = function(self, inputs)
    self.levelSlider:receiveInputs(inputs)
  end

  -- to update the UI if code gets changed from the backend (e.g. network messages)
  player:connectSignal("levelChanged", levelSlider, levelSlider.setValue)

  -- player number icon
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    hAlign = "left",
    vAlign = "center",
    scale = 2,
    x = 2
  })

  uiElement.playerNumberIcon = playerNumberIcon
  uiElement:addChild(uiElement.playerNumberIcon)

  return uiElement
end

---@param player Player
---@param width number
---@return StackPanel rankedSelectionContainer
function CharacterSelect:createRankedSelection(player, width)

  -- player number icon
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    scale = 2,
    vAlign = "center"
  })

  local rankedSelector = ui.BoolSelector({startValue = player.settings.wantsRanked, isEnabled = player.isLocal, vAlign = "center"})
  rankedSelector.onValueChange = function(boolSelector, value)
    GAME.theme:playValidationSfx()
    player:setWantsRanked(value)
  end

  ui.Focusable(rankedSelector)

  player:connectSignal("wantsRankedChanged", rankedSelector, rankedSelector.setValue)

  local container = ui.StackPanel(
    {
      alignment = "left",
      height = rankedSelector.height,
      hAlign = "center",
      vAlign = "center",
    }
  )
  container.playerNumberIcon = playerNumberIcon
  container.rankedSelector = rankedSelector
  container:addElement(playerNumberIcon)
  container:addElement(ui.UiElement({width = 8, height = 8}))
  container:addElement(rankedSelector)
  container:addElement(ui.UiElement({width = 8, height = 8}))

  return container
end

---@param player Player
---@param width number
---@return StackPanel styleSelectionContainer
---@return BoolSelector styleSelector
function CharacterSelect:createStyleSelection(player, width)
  -- player number icon
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    scale = 2,
    vAlign = "center"
  })

  local styleSelector = ui.BoolSelector({
    startValue = (player.settings.style == GameModes.Styles.MODERN),
    isEnabled = player.isLocal
  })

  -- onValueChange should get implemented by the caller
  -- as likely the UI needs to be altered to accomodate the style choice

  ui.Focusable(styleSelector)

  player:connectSignal("styleChanged", styleSelector, function(p, style)
      if style == GameModes.Styles.MODERN then
        styleSelector:setValue(true)
      else
        styleSelector:setValue(false)
      end
    end
  )

  local container = ui.StackPanel({
    alignment = "left",
    height = styleSelector.height,
    hAlign = "center",
    vAlign = "center",
  })
  container.playerNumberIcon = playerNumberIcon
  container.styleSelector = styleSelector
  container:addElement(playerNumberIcon)
  container:addElement(ui.UiElement({width = 8, height = 8}))
  container:addElement(styleSelector)
  container:addElement(ui.UiElement({width = 8, height = 8}))

  return container, styleSelector
end

---@param player Player
---@param width number
---@return StackPanel noRaiseSelectionContainer
---@return BoolSelector noRaiseSelector
function CharacterSelect:createNoRaiseSelection(player, width)
  local playerIndex = tableUtils.indexOf(self.players, player)
  local playerNumberIcon = ui.ImageContainer({
    image = getPlayerNumberIcon(playerIndex),
    scale = 2,
    vAlign = "center"
  })

  local noRaiseSelector = ui.BoolSelector({
    startValue = player.settings.endlessNoRaise == true,
    isEnabled = player.isLocal
  })

  ui.Focusable(noRaiseSelector)

  local container = ui.StackPanel({
    alignment = "left",
    height = noRaiseSelector.height,
    hAlign = "center",
    vAlign = "center",
  })
  container.playerNumberIcon = playerNumberIcon
  container.noRaiseSelector = noRaiseSelector
  container:addElement(playerNumberIcon)
  container:addElement(ui.UiElement({width = 8, height = 8}))
  container:addElement(noRaiseSelector)
  container:addElement(ui.UiElement({width = 8, height = 8}))

  return container, noRaiseSelector
end

function CharacterSelect:createRecordsBox(lastText)
  local stackPanel = ui.StackPanel({alignment = "top", hFill = true, vAlign = "center"})

  local lastLines = ui.UiElement({hFill = true})
  local lastLinesLabel = ui.PixelFontLabel({ text = lastText, xScale = 0.5, yScale = 1, hAlign = "left", x = 10})
  local lastLinesValue = ui.PixelFontLabel({ text = self.lastScore, xScale = 0.5, yScale = 1, hAlign = "right", x = -10})
  lastLines.height = lastLinesLabel.height + 4
  lastLines.label = lastLinesLabel
  lastLines.value = lastLinesValue
  lastLines:addChild(lastLinesLabel)
  lastLines:addChild(lastLinesValue)
  stackPanel.lastLines = lastLines
  stackPanel:addElement(lastLines)

  local record = ui.UiElement({hFill = true})
  local recordLabel = ui.PixelFontLabel({ text = "record", xScale = 0.5, yScale = 1, hAlign = "left", x = 10})
  local recordValue = ui.PixelFontLabel({ text = self.record, xScale = 0.5, yScale = 1, hAlign = "right", x = -10})
  record.height = recordLabel.height + 4
  record.label = recordLabel
  record.value = recordValue
  record:addChild(recordLabel)
  record:addChild(recordValue)
  stackPanel.record = record
  stackPanel:addElement(record)

  stackPanel.setLastResult = function(stackPanel, value)
    stackPanel.lastLines.value:setText(value)
  end

  stackPanel.setRecord = function(stackPanel, value)
    stackPanel.record.value:setText(value)
  end

  return stackPanel
end

function CharacterSelect:createPlayerInfo(player, labelX)
  labelX = labelX or 4
  local stackPanel = ui.StackPanel({alignment = "top", hFill = true, vAlign = "top"})

  -- Host marker: shown above all other player info so the room owner is
  -- immediately identifiable. Stays in place across roster changes — the
  -- ownerId is fixed for the lifetime of the room (set in addToRoom).
  local ownerId = self.battleRoom and self.battleRoom.ownerId
  local isHost = ownerId ~= nil and player.publicId == ownerId
  if isHost then
    stackPanel.hostLabel = ui.Label({
      x = labelX,
      text = "Host",
      translate = false
    })
    stackPanel:addElement(stackPanel.hostLabel)
  end

  stackPanel.nameLabel = ui.Label({
    x = labelX,
    text = player.name or "",
    translate = false
  })

  -- Mode flags drive every conditional below: rating is hidden in team / FFA
  -- (individual ELO doesn't track meaningfully there), wins/winrate are also
  -- hidden in shared-team mode, and ranked-only sub-rows gate on showExpected.
  local isTeamGame = TeamUtils.isSharedTeamMode(self.battleRoom.mode)
  local isFFA = TeamUtils.isFFA(self.battleRoom.mode)
  local showRating = not isTeamGame and not isFFA
  local showExpected = self.battleRoom.ranked and not isTeamGame

  if showRating then
    stackPanel.ratingLabel = ui.Label({
      x = labelX,
      text = player.rating or "",
      translate = false
    })
    stackPanel.ratingLabel.updateLabel = function(self, rating, ratingDiff)
      if ratingDiff > 0 then
        self:setText(tostring(rating) .. " (+" .. ratingDiff .. ")", nil, false)
      elseif ratingDiff < 0 then
        self:setText(tostring(rating) .. " (" .. ratingDiff .. ")", nil, false)
      else
        self:setText(tostring(rating), nil, false)
      end
    end
  end

  -- Wins / winrate per-room stats are unreliable for shared-team modes
  -- (team_win_counts isn't reflected back into player.wins), so hide them
  -- there. FFA and 1v1 still get the existing block.
  --
  -- Stat labels are built upfront so signal wiring stays simple, but they are
  -- NOT mounted to the panel until this participant's first match completes —
  -- otherwise their empty placeholder rows still claim StackPanel space and
  -- shove the quote down. The placementChanged callback inserts them above
  -- the placement row on the same frame the quote disappears.

  if not isTeamGame then
    stackPanel.winsLabel = ui.Label({
      x = labelX,
      text = loc("ss_wins") .. " " .. player:getWinCountForDisplay(),
      translate = false
    })
    stackPanel.winsLabel.updateLabel = function(self, winCount)
      self:setText(loc("ss_wins") .. " " .. winCount, nil, false)
    end

    if showExpected then
      stackPanel.winrateLabel = ui.Label({
        x = labelX,
        text = "ss_winrate"
      })

      stackPanel.winrateValueLabel = ui.Label({
        x = labelX,
        text = "  " .. loc("ss_current_rating") .. " " .. tostring(player.winrate) .. "%",
        translate = false
      })
      stackPanel.winrateValueLabel.updateLabel = function(self, winrate)
        self:setText("  " .. loc("ss_current_rating") .. tostring(winrate) .. "%", nil, false)
      end

      stackPanel.winrateExpectedLabel = ui.Label({
        x = labelX,
        text = loc("ss_expected_rating") .. " " .. player.expectedWinrate .. "%",
        translate = false
      })
      stackPanel.winrateExpectedLabel.updateLabel = function(self, expectedWinrate)
        self:setText("  " .. loc("ss_expected_rating") .. tostring(expectedWinrate) .. "%", nil, false)
      end
    else
      stackPanel.winrateValueLabel = ui.Label({
        x = labelX,
        text = loc("ss_winrate") .. " " .. tostring(player.winrate) .. "%",
        translate = false
      })
      stackPanel.winrateValueLabel.updateLabel = function(self, winrate)
        self:setText(loc("ss_winrate") .. " " .. tostring(winrate) .. "%", nil, false)
      end
    end
  end

  -- Previous-match summary. Labels are always created — their text is updated
  -- via placementChanged because CharacterSelect mounts BEFORE the first match
  -- (when lastPlacement is still nil), and the GameBase pop on match-end
  -- doesn't re-run :load(). Without the signal, the labels would stay blank
  -- forever.
  local function formatMatchOut(outClock)
    if not outClock or outClock <= 0 then return "" end
    local totalSeconds = math.floor(outClock / 60)
    return string.format("Match out: %d:%02d", math.floor(totalSeconds / 60), totalSeconds % 60)
  end
  -- Quotes are wrapped in literal " marks and wrap to fit the info-card column.
  -- iconRow.unitSize shrinks for high player counts (8p → 75, 12p → 50), so we
  -- pull the wrap width from there; the label auto-grows vertically to fit.
  local flavor = '"' .. pickFlavorQuote(player.name or "") .. '"'
  local cardWidth = (self.ui and self.ui.iconRow and self.ui.iconRow.unitSize) or 100
  local QUOTE_WRAP_PX = math.max(60, cardWidth - 8)
  local function placementText(placement)
    return placement and ("Position: " .. tostring(placement)) or flavor
  end

  stackPanel.placementLabel = ui.Label({
    x = labelX,
    text = placementText(player.lastPlacement),
    translate = false,
    wrapWidth = QUOTE_WRAP_PX,
  })
  stackPanel.matchOutLabel = ui.Label({
    x = labelX,
    text = formatMatchOut(player.lastMatchOutClock),
    translate = false
  })
  -- Lazy mount: insert each stat label just above placementLabel. Each
  -- insertion pushes placementLabel down by one, so we recompute its index
  -- each time. Guarded by _statsMounted so re-fires (next match's
  -- placementChanged) don't re-insert duplicates.
  local function mountStatsAbovePlacement()
    if stackPanel._statsMounted then return end
    stackPanel._statsMounted = true
    local function insertBeforePlacement(label)
      if not label then return end
      local idx = tableUtils.indexOf(stackPanel.children, stackPanel.placementLabel)
      stackPanel:insertElementAtIndex(label, idx)
    end
    insertBeforePlacement(stackPanel.winsLabel)
    insertBeforePlacement(stackPanel.winrateLabel)
    insertBeforePlacement(stackPanel.winrateValueLabel)
    insertBeforePlacement(stackPanel.winrateExpectedLabel)
  end

  -- Pre-first-match the nameLabel rides UNDER the quote as a "~ Name"
  -- attribution; once placement is known it slides back to its normal
  -- top-of-card slot. setText switches the prefix; we relocate via
  -- remove + insertElementAtIndex.
  local function setNameAttributed(attributed)
    local txt = player.name or ""
    stackPanel.nameLabel:setText(attributed and ("~ " .. txt) or txt, nil, false)
  end
  local function promoteNameToTop()
    if stackPanel._namePromoted then return end
    stackPanel._namePromoted = true
    stackPanel:remove(stackPanel.nameLabel)
    setNameAttributed(false)
    local topIdx = 1
    if stackPanel.hostLabel then topIdx = topIdx + 1 end
    if stackPanel.bootButton then topIdx = topIdx + 1 end
    stackPanel:insertElementAtIndex(stackPanel.nameLabel, topIdx)
  end

  stackPanel.placementLabel.updateLabel = function(self, placement, outClock)
    self:setText(placementText(placement), nil, false)
    stackPanel.matchOutLabel:setText(formatMatchOut(outClock), nil, false)
    if placement then
      promoteNameToTop()
      mountStatsAbovePlacement()
    end
  end

  if stackPanel.ratingLabel then
    player:connectSignal("ratingChanged", stackPanel.ratingLabel, stackPanel.ratingLabel.updateLabel)
  end
  if stackPanel.winsLabel then
    player:connectSignal("winsChanged", stackPanel.winsLabel, stackPanel.winsLabel.updateLabel)
  end
  if stackPanel.winrateValueLabel then
    player:connectSignal("winrateChanged", stackPanel.winrateValueLabel, stackPanel.winrateValueLabel.updateLabel)
  end
  if stackPanel.winrateExpectedLabel then
    player:connectSignal("expectedWinrateChanged", stackPanel.winrateExpectedLabel, stackPanel.winrateExpectedLabel.updateLabel)
  end
  player:connectSignal("placementChanged", stackPanel.placementLabel, stackPanel.placementLabel.updateLabel)

  if player.lastPlacement then
    -- Returning to a session where this player already has placement info:
    -- name at top (no tilde), stats above placement, position+match-out below.
    stackPanel._namePromoted = true
    stackPanel:addElement(stackPanel.nameLabel)
    if stackPanel.ratingLabel then
      stackPanel:addElement(stackPanel.ratingLabel)
    end
    stackPanel:addElement(stackPanel.placementLabel)
    stackPanel:addElement(stackPanel.matchOutLabel)
    mountStatsAbovePlacement()
  else
    -- Pre-first-match: rating, quote, "~ Name" as attribution, (empty matchOut).
    setNameAttributed(true)
    if stackPanel.ratingLabel then
      stackPanel:addElement(stackPanel.ratingLabel)
    end
    stackPanel:addElement(stackPanel.placementLabel)
    stackPanel:addElement(stackPanel.nameLabel)
    stackPanel:addElement(stackPanel.matchOutLabel)
  end

  return stackPanel
end

function CharacterSelect:createRankedStatusPanel()
  local rankedStatus = ui.StackPanel({
    alignment = "top",
    hAlign = "center",
    vAlign = "top",
    y = 40,
    width = 300
  })
  rankedStatus.rankedLabel = ui.Label({
    text = "",
    hAlign = "center",
    vAlign = "top"
  })
  if self.battleRoom.ranked then
    rankedStatus.rankedLabel:setText("ss_ranked")
  else
    rankedStatus.rankedLabel:setText("ss_casual")
  end
  rankedStatus.commentLabel = ui.Label({
    text = self.battleRoom.rankedComments or "",
    hAlign = "center",
    vAlign = "top",
    translate = false
  })
  rankedStatus:addElement(rankedStatus.rankedLabel)
  rankedStatus:addElement(rankedStatus.commentLabel)

  rankedStatus.updateFromRankedStatusChanged = function(selfElement, ranked, comments)
    if ranked then
      selfElement.rankedLabel:setText("ss_ranked")
    else
      selfElement.rankedLabel:setText("ss_casual")
    end
    selfElement.commentLabel:setText(comments, nil, false)
  end

  self.battleRoom:connectSignal("rankedStatusChanged", rankedStatus, rankedStatus.updateFromRankedStatusChanged)

  return rankedStatus
end

---@param player Player
---@param height number
---@param min integer?
---@return UiElement speedSliderContainer
function CharacterSelect:createSpeedSlider(player, height, min)
  local speedSlider = ui.Slider({
    min = min or 1,
    max = 99,
    value = player.settings.speed,
    onValueChange = function(slider)
      player:setSpeed(slider.value)
      GAME.theme:playMoveSfx()
    end,
    hAlign = "center",
    vAlign = "center",
  })
  ui.Focusable(speedSlider)

  player:connectSignal("startingSpeedChanged", speedSlider, speedSlider.setValue)

  -- wrap in an extra element so we can offset properly as speedSlider is fixed height + width
  local uiElement = ui.UiElement({height = height, hFill = true})
  ui.Focusable(uiElement)
  uiElement.speedSlider = speedSlider
  uiElement.speedSlider.yieldFocus = function()
    GAME.theme:playValidationSfx()
    uiElement:yieldFocus()
  end
  uiElement:addChild(speedSlider)
  uiElement.receiveInputs = function(self, inputs)
    self.speedSlider:receiveInputs(inputs)
  end

  return uiElement
end

function CharacterSelect:createDifficultyCarousel(player, height, getPresetFunc)
  local passengers = {
    { id = 1, uiElement = ui.Label({text = "easy", vAlign = "center", hAlign = "center"})},
    { id = 2, uiElement = ui.Label({text = "normal", vAlign = "center", hAlign = "center"})},
    { id = 3, uiElement = ui.Label({text = "hard", vAlign = "center", hAlign = "center"})},
    { id = 4, uiElement = ui.Label({text = "ss_ex_mode", vAlign = "center", hAlign = "center"})},
  }
  local difficultyCarousel = ui.Carousel({
    isEnabled = player.isLocal,
    hAlign = "center",
    vAlign = "top",
    hFill = true,
    height = height,
    passengers = passengers,
    selectedId = player.settings.difficulty
  })

  difficultyCarousel.onSelectCallback = function()
    -- Just update on every passenger change
  end

  difficultyCarousel.onBackCallback = function()
    -- Just update on every passenger change
  end

  difficultyCarousel.onPassengerUpdateCallback = function(carousel, selectedPassenger)
    player:setDifficulty(selectedPassenger.id)
    if getPresetFunc then
      player:setLevelData(getPresetFunc(selectedPassenger.id))
    end
    GAME.theme:playMoveSfx()
  end

  -- to update the UI if code gets changed from the backend (e.g. network messages)
  player:connectSignal("difficultyChanged", difficultyCarousel, difficultyCarousel.setPassengerById)

  return difficultyCarousel
end

function CharacterSelect:updateSelf(dt)
  self.inputDeviceOverlay:openInputDeviceOverlayIfNeeded()

  if self.inputDeviceOverlay:isActive() then
    return
  end

  for _, cursor in ipairs(self.ui.cursors) do
    if cursor.player.isLocal and cursor.player.human then
      if not cursor.player.inputConfiguration then
        cursor:receiveInputs(input, dt)
      elseif cursor.player.settings.inputMethod == "controller" then
        cursor:receiveInputs(cursor.player.inputConfiguration, dt)
      end
    end
  end
  if self.battleRoom and self.battleRoom.spectating then
    if input.isDown["MenuEsc"] then
      GAME.theme:playCancelSfx()
      GAME.netClient:leaveRoom()
      GAME.navigationStack:pop()
    end
  end
  if self:customUpdate() then
    return
  end
end

function CharacterSelect:drawSelf()
  self.backgroundImg:draw()
  self:drawTeamBannerHeader()
  self:customDraw()
  self:drawWaitingForPlayersBanner()
  self:drawVoidedRoomBanner()
  self:drawLeaveBlockedBanner()
end

-- Dynamic-roster modes (open FFA) need a hint that the match is gated on more
-- players showing up — otherwise readying up just silently does nothing.
function CharacterSelect:drawWaitingForPlayersBanner()
  local mode = self.battleRoom and self.battleRoom.mode
  if not (mode and mode.minPlayers) then return end
  local current = #self.battleRoom.players
  local minPlayers = mode.minPlayers
  if current >= minPlayers then return end

  local GraphicsUtil = require("client.src.graphics.graphics_util")
  local consts = require("common.engine.consts")
  local missing = minPlayers - current
  local text = string.format("Waiting for %d more %s to start (min %d)",
    missing, (missing == 1) and "player" or "players", minPlayers)
  local bannerY = 80
  GraphicsUtil.printf(text, 0, bannerY + 2, consts.CANVAS_WIDTH, "center", {0.1, 0.05, 0.15, 0.85}, nil, 24)
  GraphicsUtil.printf(text, 0, bannerY,     consts.CANVAS_WIDTH, "center", {1, 0.9, 0.5, 1},      nil, 24)
end

-- Draws a centered "<reason>" banner over CharacterSelect when the server has told
-- us a player left/disconnected. Voided rooms can't start a new match — this gives
-- remaining players a clear cue to leave when they're done looking around.
function CharacterSelect:drawVoidedRoomBanner()
  if not (self.battleRoom and self.battleRoom.isVoided and self.battleRoom:isVoided()) then
    return
  end
  local GraphicsUtil = require("client.src.graphics.graphics_util")
  local consts = require("common.engine.consts")
  local text = (self.battleRoom.voidReason or "A player left")
    .. " — game over. Press leave to return to lobby."
  local bannerY = math.floor(consts.CANVAS_HEIGHT / 2) - 18
  GraphicsUtil.drawRectangle("fill", 0, bannerY, consts.CANVAS_WIDTH, 36, 0, 0, 0, 0.7)
  GraphicsUtil.printf(text, 0, bannerY + 10, consts.CANVAS_WIDTH, "center", {1, 0.85, 0.4, 1})
end

-- Brief banner shown when leave is gated because the local player is dead
-- and teammates' match is still resolving server-side.
function CharacterSelect:drawLeaveBlockedBanner()
  if not self.leaveBlockedUntil then return end
  local now = love.timer.getTime()
  if now >= self.leaveBlockedUntil then
    self.leaveBlockedUntil = nil
    return
  end
  local GraphicsUtil = require("client.src.graphics.graphics_util")
  local consts = require("common.engine.consts")
  local text = "Wait for the match to end before leaving."
  local bannerY = math.floor(consts.CANVAS_HEIGHT / 2) + 24
  GraphicsUtil.drawRectangle("fill", 0, bannerY, consts.CANVAS_WIDTH, 36, 0, 0, 0, 0.7)
  GraphicsUtil.printf(text, 0, bannerY + 10, consts.CANVAS_WIDTH, "center", {1, 0.85, 0.4, 1})
end

-- Top-of-screen pink/purple banner pair (same component as in-game).
function CharacterSelect:drawTeamBannerHeader()
  if not (self.battleRoom and self.battleRoom.mode) then return end
  local TeamBannerHeader = require("client.src.graphics.TeamBannerHeader")
  local canvasWidth = GAME.globalCanvas:getWidth()
  TeamBannerHeader.draw(self.battleRoom.mode,
                        self.battleRoom.players,
                        self.battleRoom.teamWins,
                        canvasWidth)
  TeamBannerHeader.drawGarbageModeBelowBanner(self.battleRoom.mode, canvasWidth)
end

-- Per-player thick team-colored border is drawn from createPlayerIcon via
-- ImageContainer.drawSelf override. No canvas-wide bands here anymore.

-- Returns the RGBA color this player's character icon should be outlined in,
-- or nil for non-shared-team modes (FFA, solo, 2P VS — keep the default border).
function CharacterSelect:teamBorderColorForPlayer(player)
  if not (self.battleRoom and self.battleRoom.mode) then return nil end
  local TeamBannerHeader = require("client.src.graphics.TeamBannerHeader")
  if not TeamBannerHeader.isSharedTeamMode(self.battleRoom.mode) then return nil end

  -- Use canonical server slot (playerNumber) for team mapping. Dense list
  local teamIndex = TeamUtils.teamIndexForPlayer(self.battleRoom, player)
  return teamIndex and TeamBannerHeader.colors[teamIndex] or nil
end

function CharacterSelect:leave()
  -- Dead-local mid-match: server keeps the slot in pendingLeaverRemovals until
  -- match end, so the lobby keeps re-pinning us back in the room — the client
  -- pops to Lobby but the next lobbyStateV2 broadcast undoes that. Block the
  -- leave with a banner and let the match wrap up.
  if self.battleRoom and self.battleRoom.match
      and self.battleRoom.match.isLocalPlayerEliminated
      and self.battleRoom.match:isLocalPlayerEliminated() then
    self.leaveBlockedUntil = love.timer.getTime() + 3
    return
  end

  -- Explicit user-initiated leave: announce to the server first so the room
  -- knows we're gone, then tear down local match state on scene unmount.
  -- BattleRoom:shutdown is local-only; it doesn't talk to the server.
  if GAME.netClient and GAME.netClient:isConnected() then
    GAME.netClient:leaveRoom()
  end
  GAME.navigationStack:pop(nil,
    function()
      if self.battleRoom then
        self.battleRoom:shutdown()
      end
    end)
end

return CharacterSelect
