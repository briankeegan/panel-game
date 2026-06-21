local CharacterSelect = require("client.src.scenes.CharacterSelect")
local class = require("common.lib.class")
local ui = require("client.src.ui")
local system = require("client.src.system")

-- The character select screen scene
local CharacterSelectVsSelf = class(
  function (self, sceneParams)
    self.lastScore = nil
    self.record = nil
  end,
  CharacterSelect
)

CharacterSelectVsSelf.name = "CharacterSelectVsSelf"

function CharacterSelectVsSelf:customLoad(sceneParams)
  self:loadUserInterface()
end

function CharacterSelectVsSelf:loadUserInterface()
  local player = self.battleRoom.players[1]

  self:addPortraitBackdrop()
  local pm = system.isPortraitMode()
  local unitSize, gridW, gridH = 100, 9, 6
  if pm then
    unitSize, gridW, gridH = 125, 4, 8
  end
  self.ui.grid = ui.Grid({unitSize = unitSize, gridWidth = gridW, gridHeight = gridH, unitMargin = 8, hAlign = "center", vAlign = pm and "bottom" or "center"})
  self.uiRoot:addChild(self.ui.grid)

  self.ui.characterIcons[1] = self:createPlayerIcon(player)
  self.ui.grid:createElementAt(1, 1, 1, 1, "selectedCharacter", self.ui.characterIcons[1])

  self.ui.recordBox = self:createRecordsBox("last lines")
  self:refresh()
  self.ui.grid:createElementAt(2, 1, pm and 3 or 2, 1, "recordBox", self.ui.recordBox)

  self.ui.panelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.panelSelection:setTitle("panels")
  local panelCarousel = self:createPanelCarousel(player, self.ui.grid.unitSize - self.ui.grid.unitMargin * 2 - self.ui.panelSelection.height)
  self.ui.panelSelection:addElement(panelCarousel, player)
  self.ui.grid:createElementAt(1, 2, pm and 4 or 2, 1, "panelSelection", self.ui.panelSelection)

  local stageCarousel = self:createStageCarousel(player, (pm and self.ui.grid.unitSize * 4 or self.ui.grid.unitSize * 2) - self.ui.grid.unitMargin * 2)
  self.ui.stageSelection = ui.MultiPlayerSelectionWrapper({vFill = true, alignment = "left", hAlign = "center", vAlign = "center"})
  self.ui.stageSelection:setTitle("stage")
  self.ui.stageSelection:addElement(stageCarousel, player)
  if pm then
    self.ui.grid:createElementAt(1, 3, 4, 1, "stageSelection", self.ui.stageSelection)
  else
    self.ui.grid:createElementAt(3, 2, 2, 1, "stageSelection", self.ui.stageSelection)
  end

  self.ui.noRaiseSelection = ui.MultiPlayerSelectionWrapper({vFill = true, alignment = "left", hAlign = "center", vAlign = "center"})
  self.ui.noRaiseSelection:setTitle("endless_no_raise")
  local noRaiseContainer, noRaiseSelector = self:createNoRaiseSelection(player, self.ui.grid.unitSize)
  self.ui.noRaiseSelection:addElement(noRaiseContainer, player)
  if pm then
    self.ui.grid:createElementAt(1, 4, 4, 1, "noRaiseSelection", self.ui.noRaiseSelection)
  else
    self.ui.grid:createElementAt(5, 2, 1, 1, "noRaiseSelection", self.ui.noRaiseSelection)
  end

  noRaiseSelector.onValueChange = function(boolSelector, value)
    GAME.theme:playValidationSfx()
    player:setEndlessNoRaise(value)
  end

  self.ui.levelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.levelSelection:setTitle("level")
  local levelSlider = self:createLevelSlider(player, 20, self.ui.grid.unitSize - self.ui.grid.unitMargin * 2 - self.ui.levelSelection.height)
  local oldOnValueChange = levelSlider.onValueChange
  levelSlider.onValueChange = function(ls)
    oldOnValueChange(ls)
    self.lastScore = GAME.scores:lastVsScoreForLevel(ls.value)
    self.record = GAME.scores:recordVsScoreForLevel(ls.value)
    self.ui.recordBox:setLastResult(self.lastScore)
    self.ui.recordBox:setRecord(self.record)
  end
  self.ui.levelSelection:addElement(levelSlider, player)
  if pm then
    self.ui.grid:createElementAt(1, 5, 4, 1, "levelSelection", self.ui.levelSelection)
  else
    self.ui.grid:createElementAt(6, 2, 3, 1, "levelSelection", self.ui.levelSelection)
  end

  self.ui.readyButton = self:createReadyButton()
  if pm then
    self.ui.grid:createElementAt(1, 8, 2, 1, "readyButton", self.ui.readyButton)
  else
    self.ui.grid:createElementAt(9, 2, 1, 1, "readyButton", self.ui.readyButton)
  end

  local characterButtons = self:getCharacterButtons()
  local characterGridWidth, characterGridHeight = 9, 3
  if pm then characterGridWidth, characterGridHeight = 4, 1 end
  self.ui.characterGrid = self:createCharacterGrid(characterButtons, self.ui.grid, characterGridWidth, characterGridHeight)
  if pm then
    self.ui.grid:createElementAt(1, 6, characterGridWidth, characterGridHeight, "characterSelection", self.ui.characterGrid, true)
  else
    self.ui.grid:createElementAt(1, 3, characterGridWidth, characterGridHeight, "characterSelection", self.ui.characterGrid, true)
  end

  self.ui.pageIndicator = self:createPageIndicator(self.ui.characterGrid)
  if pm then
    self.ui.grid:createElementAt(2, 7, 1, 1, "pageIndicator", self.ui.pageIndicator)
  else
    self.ui.grid:createElementAt(5, 6, 1, 1, "pageIndicator", self.ui.pageIndicator)
  end

  self.ui.pageTurnButtons = self:createPageTurnButtons(self.ui.characterGrid)

  self.ui.leaveButton = self:createLeaveButton()
  self.ui.changeInputButton = self:createChangeInputButton()
  if pm then
    self.ui.changeInputButton:setVisibility(false)
    self.ui.grid:createElementAt(3, 8, 2, 1, "leaveButton", self.ui.leaveButton)
  else
    self.ui.grid:createElementAt(8, 6, 1, 1, "changeInputButton", self.ui.changeInputButton)
    self.ui.grid:createElementAt(9, 6, 1, 1, "leaveButton", self.ui.leaveButton)
  end

  self.ui.cursors[1] = self:createCursor(self.ui.grid, player)
  self.ui.cursors[1].raise1Callback = function()
    self.ui.characterGrid:turnPage(-1)
  end
  self.ui.cursors[1].raise2Callback = function()
    self.ui.characterGrid:turnPage(1)
  end
end

function CharacterSelectVsSelf:refresh()
  local level
  if self.battleRoom and self.battleRoom.players[1] then
    level = self.battleRoom.players[1].settings.level
    self.lastScore = GAME.scores:lastVsScoreForLevel(level)
    self.record = GAME.scores:recordVsScoreForLevel(level)
    if self.ui.recordBox then
      self.ui.recordBox:setLastResult(self.lastScore)
      self.ui.recordBox:setRecord(self.record)
    end
  end
end

return CharacterSelectVsSelf
