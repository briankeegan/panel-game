local CharacterSelect = require("client.src.scenes.CharacterSelect")
local class = require("common.lib.class")
local ui = require("client.src.ui")
local system = require("client.src.system")

---@class CharacterSelectChallenge : CharacterSelect
local CharacterSelectChallenge = class(
  function (self, sceneParams)
  end,
  CharacterSelect
)

CharacterSelectChallenge.name = "CharacterSelectChallenge"

function CharacterSelectChallenge:customLoad(sceneParams)
  self:loadUserInterface()
end

function CharacterSelectChallenge:loadUserInterface()
  self:addPortraitBackdrop()
  local pm = system.isPortraitMode()
  local unitSize, gridW, gridH = 100, 9, 6
  if pm then
    -- 10-row grid (same unit size as the other screens) so the character carousel
    -- is the same size everywhere
    gridW, gridH = 4, 10
    unitSize = math.floor(1240 / gridH)
  end
  self.ui.grid = ui.Grid({unitSize = unitSize, gridWidth = gridW, gridHeight = gridH, unitMargin = 8, hAlign = "center", vAlign = "center"})
  self.uiRoot:addChild(self.ui.grid)

  self.ui.panelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.panelSelection:setTitle("panels")
  self.ui.stageSelection = ui.MultiPlayerSelectionWrapper({vFill = true, alignment = "left", hAlign = "center", vAlign = "center"})
  self.ui.stageSelection:setTitle("stage")
  self.ui.readyButton = self:createReadyButton()
  local characterButtons = self:getCharacterButtons()
  local characterGridWidth, characterGridHeight = self.ui.grid.gridWidth, 3
  -- same single-row character picker (4 wide, page < > arrows) as the other screens
  if pm then characterGridWidth, characterGridHeight = 4, 1 end
  self.ui.characterGrid = self:createCharacterGrid(characterButtons, self.ui.grid, characterGridWidth, characterGridHeight)
  self.ui.pageIndicator = self:createPageIndicator(self.ui.characterGrid)
  self.ui.leaveButton = self:createLeaveButton()
  self.ui.changeInputButton = self:createChangeInputButton()

  local panelHeight
  local stageWidth

  if pm then
    self.ui.grid:createElementAt(1, 2, 4, 1, "panelSelection", self.ui.panelSelection)
    self.ui.grid:createElementAt(1, 3, 4, 1, "stageSelection", self.ui.stageSelection)
  else
    self.ui.grid:createElementAt(1, 2, 3, 1, "panelSelection", self.ui.panelSelection)
    self.ui.grid:createElementAt(4, 2, 3, 1, "stageSelection", self.ui.stageSelection)
  end

  panelHeight = self.ui.grid.unitSize - self.ui.grid.unitMargin * 2- self.ui.panelSelection.height
  stageWidth = (pm and self.ui.grid.unitSize * 4 or self.ui.grid.unitSize * 1.5) - self.ui.grid.unitMargin * 2

  if pm then
    self.ui.changeInputButton:setVisibility(false)
    -- characters on row 8 (same as the other screens); page + actions below
    self.ui.grid:createElementAt(1, 8, characterGridWidth, characterGridHeight, "characterSelection", self.ui.characterGrid, true)
    self.ui.grid:createElementAt(2, 9, 1, 1, "pageIndicator", self.ui.pageIndicator)
    self.ui.grid:createElementAt(3, 10, 2, 1, "readyButton", self.ui.readyButton)
    self.ui.grid:createElementAt(1, 10, 2, 1, "leaveButton", self.ui.leaveButton)
  else
    self.ui.grid:createElementAt(9, 2, 1, 1, "readyButton", self.ui.readyButton)
    self.ui.grid:createElementAt(1, 3, characterGridWidth, characterGridHeight, "characterSelection", self.ui.characterGrid, true)
    self.ui.grid:createElementAt(5, 6, 1, 1, "pageIndicator", self.ui.pageIndicator)
    self.ui.grid:createElementAt(8, 6, 1, 1, "changeInputButton", self.ui.changeInputButton)
    self.ui.grid:createElementAt(9, 6, 1, 1, "leaveButton", self.ui.leaveButton)
  end

  self.ui.characterIcons = {}
  for i = 1, #self.battleRoom.players do
    local player = self.battleRoom.players[i]

    if player.human then
      local panelCarousel = self:createPanelCarousel(player, panelHeight)
      self.ui.panelSelection:addElement(panelCarousel, player)

      local cursor = self:createCursor(self.ui.grid, player)
      cursor.raise1Callback = function()
        self.ui.characterGrid:turnPage(-1)
      end
      cursor.raise2Callback = function()
        self.ui.characterGrid:turnPage(1)
      end
      self.ui.cursors[i] = cursor
    end

    -- portrait: only the human player's stage (cramming the AI's in too makes the
    -- card a messed-up double carousel). Landscape keeps both as before.
    if player.human or not pm then
      local stageCarousel = self:createStageCarousel(player, stageWidth)
      self.ui.stageSelection:addElement(stageCarousel, player)
    end

    self.ui.characterIcons[i] = self:createPlayerIcon(player)
  end

  self.ui.grid:createElementAt(1, 1, 1, 1, "p1 icon", self.ui.characterIcons[1])
  self.ui.grid:createElementAt(pm and 4 or 9, 1, 1, 1, "p2 icon", self.ui.characterIcons[2])

  -- need to be created at the end after the character grid has been settled in
  -- otherwise the placement will be wrong
  self.ui.pageTurnButtons = self:createPageTurnButtons(self.ui.characterGrid)
end

return CharacterSelectChallenge
