local CharacterSelect = require("client.src.scenes.CharacterSelect")
local class = require("common.lib.class")
local ui = require("client.src.ui")

---@class CharacterSelect2p : CharacterSelect
local CharacterSelect2p = class(
  function (self, sceneParams)
  end,
  CharacterSelect
)

CharacterSelect2p.name = "CharacterSelect2p"

function CharacterSelect2p:customLoad(sceneParams)
  self:loadUserInterface()
end

function CharacterSelect2p:loadUserInterface()
  self.ui.grid = ui.Grid({unitSize = 100, gridWidth = 9, gridHeight = 6, unitMargin = 8, hAlign = "center", vAlign = "center"})
  self.uiRoot:addChild(self.ui.grid)

  self:createIconRow()

  self.ui.panelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.panelSelection:setTitle("panels")
  self.ui.stageSelection = ui.MultiPlayerSelectionWrapper({vFill = true, alignment = "left", hAlign = "center", vAlign = "center"})
  self.ui.stageSelection:setTitle("stage")
  self.ui.levelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.levelSelection:setTitle("level")

  self.ui.readyButton = self:createReadyButton()

  local characterButtons = self:getCharacterButtons()
  local characterGridWidth, characterGridHeight = self.ui.grid.gridWidth, 3
  self.ui.characterGrid = self:createCharacterGrid(characterButtons, self.ui.grid, characterGridWidth, characterGridHeight)

  self.ui.pageIndicator = self:createPageIndicator(self.ui.characterGrid)

  self.ui.leaveButton = self:createLeaveButton()
  self.ui.changeInputButton = self:createChangeInputButton()

  if self.battleRoom.online then
    self.ui.grid:createElementAt(1, 2, 2, 1, "panelSelection", self.ui.panelSelection, nil, true)
    self.ui.grid:createElementAt(5, 2, 2, 1, "stageSelection", self.ui.stageSelection, nil, true)
    self.ui.grid:createElementAt(7, 2, 2, 1, "levelSelection", self.ui.levelSelection, nil, true)
  else
    self.ui.grid:createElementAt(1, 2, 2, 1, "panelSelection", self.ui.panelSelection, nil, true)
    self.ui.grid:createElementAt(3, 2, 3, 1, "stageSelection", self.ui.stageSelection, nil, true)
    self.ui.grid:createElementAt(6, 2, 3, 1, "levelSelection", self.ui.levelSelection, nil, true)
  end

  self.ui.grid:createElementAt(9, 2, 1, 1, "readyButton", self.ui.readyButton)
  self.ui.grid:createElementAt(1, 3, characterGridWidth, characterGridHeight, "characterSelection", self.ui.characterGrid, true)
  self.ui.grid:createElementAt(5, 6, 1, 1, "pageIndicator", self.ui.pageIndicator)
  self.ui.grid:createElementAt(8, 6, 1, 1, "changeInputButton", self.ui.changeInputButton)
  self.ui.grid:createElementAt(9, 6, 1, 1, "leaveButton", self.ui.leaveButton)

  self:setupRoster()

  -- need to be created at the end after the character grid has been settled in
  -- otherwise the placement will be wrong
  self.ui.pageTurnButtons = self:createPageTurnButtons(self.ui.characterGrid)
end

-- Creates all per-player UI: panel/stage/level selectors, cursors, top-row
-- character icons and player info cards. Roster-dependent; called from
-- loadUserInterface and rebuilt by refreshRoster on drop-in/drop-out.
function CharacterSelect2p:setupRoster()
  -- Online play has exactly one local player whose selectors are interactive; remote
  -- players' selections come from the server. Size the carousel for one row.
  local rowsToShow
  if self.battleRoom.online then
    rowsToShow = 1
  else
    rowsToShow = math.max(1, #self.battleRoom.players)
  end
  local panelHeight = (self.ui.grid.unitSize - self.ui.grid.unitMargin * 2) / rowsToShow - self.ui.panelSelection.height
  local levelHeight, stageWidth
  if self.battleRoom.online then
    levelHeight = 12
    stageWidth = self.ui.grid.unitSize - self.ui.grid.unitMargin * 2
  else
    levelHeight = 20
    stageWidth = self.ui.grid.unitSize * 1.5 - self.ui.grid.unitMargin * 2
  end

  self.ui.characterIcons = {}
  self.ui.playerInfos = {}

  for i, player in ipairs(self.players) do
    -- Online: only add the local player's selectors. Stage was already
    -- local-only; panels and level now match.
    local showSelectors = (not self.battleRoom.online) or player.isLocal
    if showSelectors then
      local panelCarousel = self:createPanelCarousel(player, panelHeight)
      self.ui.panelSelection:addElement(panelCarousel, player)
    end

    if player.isLocal then
      local stageCarousel = self:createStageCarousel(player, stageWidth)
      self.ui.stageSelection:addElement(stageCarousel, player)
    end

    if showSelectors then
      local levelSlider = self:createLevelSlider(player, levelHeight, panelHeight)
      self.ui.levelSelection:addElement(levelSlider, player)
    end

    local cursor = self:createCursor(self.ui.grid, player)
    cursor.raise1Callback = function()
      self.ui.characterGrid:turnPage(-1)
    end
    cursor.raise2Callback = function()
      self.ui.characterGrid:turnPage(1)
    end
    -- Local host on an open room: widen the cursor's active area to include
    -- row 6 so they can arrow-key onto the Boot buttons that _setupHostBoot
    -- Buttons places there. Other row-6 widgets (pageIndicator/changeInput/
    -- leave) gain keyboard reach as a side effect — harmless, they already
    -- have onClick handlers.
    if player.isLocal and cursor.activeArea then
      local mode = self.battleRoom and self.battleRoom.mode
      local ownerId = self.battleRoom and self.battleRoom.ownerId
      local isOpenRoom = mode and (mode.openRoom == true
        or (mode.minPlayers and mode.maxPlayers and mode.minPlayers < mode.maxPlayers))
      local localPlayer = GAME and GAME.localPlayer
      if isOpenRoom and ownerId and localPlayer and localPlayer.publicId == ownerId then
        cursor.activeArea.y2 = 6
      end
    end
    self.ui.cursors[i] = cursor

    self.ui.characterIcons[i] = self:createPlayerIcon(player)
    self.ui.playerInfos[i] = self:createPlayerInfo(player, self:_labelXForIconRow())
  end

  for i, player in ipairs(self.players) do
    local iconX = (i - 1) * 2 + 1
    local infoX = iconX + 1
    self.ui.iconRow:createElementAt(iconX, 1, 1, 1, "p" .. i .. " icon", self.ui.characterIcons[i])
    self.ui.iconRow:createElementAt(infoX, 1, 1, 1, "player " .. i .. " info", self.ui.playerInfos[i])
  end

  self:_setupHostBootButtons()
end

-- Row-6 cells available for Boot buttons. Cells 5 (pageIndicator), 8
-- (changeInputButton), and 9 (leaveButton) are owned by other widgets.
-- 6 slots = open_ffa's maxPlayers (7) minus the host themselves.
local BOOT_BUTTON_COLUMNS = {1, 2, 3, 4, 6, 7}

---Tear down any boot buttons from a previous setupRoster pass so refreshRoster
---(open-FFA drop-in/out) doesn't leave stale widgets attached to the main grid.
---
---Must go through Grid:removeElementsIn — calling btn:detach() only detaches
---the button from its wrapping GridElement, leaving the GridElement itself in
---self.grid[row][col]. The next createElementAt then collides ("already
---element X at coordinate 6|1"). removeElementsIn detaches the GridElement
---AND clears the grid cells.
function CharacterSelect2p:_clearHostBootButtons()
  if self.ui.grid and self.ui.grid.removeElementsIn then
    for _, col in ipairs(BOOT_BUTTON_COLUMNS) do
      self.ui.grid:removeElementsIn(col, 6, 1, 1)
    end
  end
  self.ui.bootButtons = {}
end

---Add a Boot button to the main grid for each non-host non-local player when
---the local player is host on an open-room session. Buttons fill the
---available row-6 cells in BOOT_BUTTON_COLUMNS order. setupRoster widens the
---host cursor's activeArea.y2 to 6 so they're keyboard-reachable. Invite
---rooms have fixed slots — booting makes no sense there.
function CharacterSelect2p:_setupHostBootButtons()
  self:_clearHostBootButtons()
  if not self.battleRoom then return end
  local mode = self.battleRoom.mode
  -- Trust the explicit openRoom flag (set by server when the room was created
  -- with openRoom=true) first; fall back to the min<max heuristic for safety
  -- against payload drift.
  local isOpenRoom = mode and (mode.openRoom == true
    or (mode.minPlayers and mode.maxPlayers and mode.minPlayers < mode.maxPlayers))
  if not isOpenRoom then return end
  local ownerId = self.battleRoom.ownerId
  local localPlayer = GAME and GAME.localPlayer
  if not (ownerId and localPlayer and localPlayer.publicId == ownerId) then return end

  local slotIdx = 1
  for _, player in ipairs(self.battleRoom.players) do
    if slotIdx > #BOOT_BUTTON_COLUMNS then break end
    if player.publicId ~= ownerId and not player.isLocal then
      local col = BOOT_BUTTON_COLUMNS[slotIdx]
      local pubId = player.publicId
      local labelText = "Boot " .. ((player.name or "?"):sub(1, 8))
      local btn = ui.TextButton({
        label = ui.Label({text = labelText, translate = false}),
        backgroundColor = {0.4, 0.05, 0.05, 0.85},
        outlineColor = {1, 0.4, 0.4, 1},
        onClick = function()
          if GAME.theme and GAME.theme.playCancelSfx then GAME.theme:playCancelSfx() end
          if GAME.netClient and GAME.netClient.kickPlayer then
            GAME.netClient:kickPlayer(pubId)
          end
        end,
      })
      btn.onSelect = btn.onClick
      self.ui.bootButtons[col] = btn
      self.ui.grid:createElementAt(col, 6, 1, 1, "bootButton" .. col, btn)
      slotIdx = slotIdx + 1
    end
  end
end

function CharacterSelect2p:_labelXForIconRow()
  local unitSize = (self.ui.iconRow and self.ui.iconRow.unitSize) or 100
  return math.floor(4 - (100 - unitSize) / 2)
end

function CharacterSelect2p:createIconRow()
  if self.ui.iconRow then
    self.ui.iconRow:detach()
  end
  local cols = math.max(2, #self.players * 2)
  local unitSize = math.min(100, math.floor(1200 / cols))
  self.ui.iconRow = ui.Grid({unitSize = unitSize, gridWidth = cols, gridHeight = 1, unitMargin = 8, hAlign = "center", vAlign = "center", y = -250})
  self.uiRoot:addChild(self.ui.iconRow)
end

-- Drop-in / drop-out hook for open FFA. Tears down all per-player widgets and
-- rebuilds them from the current self.players list.
function CharacterSelect2p:refreshRoster()
  self:createIconRow()

  -- Clear the panel/stage/level wrappers and reset their stacking state. Using
  -- bare child:detach() leaves StackPanel.pixelsTaken/height stale (see the
  -- IMPORTANT note on StackPanel:remove) — next addElement positions children
  -- at the stale y offset, pushing carousels/sliders outside their cell. We
  -- nuke the children entirely (including the title), reset stack counters to
  -- zero, then re-add the title via StackPanel.addElement so its y/height
  -- bookkeeping starts fresh.
  for _, wrapper in ipairs({self.ui.panelSelection, self.ui.stageSelection, self.ui.levelSelection}) do
    if wrapper and wrapper.children then
      for i = #wrapper.children, 1, -1 do
        wrapper.children[i]:detach()
      end
      wrapper.pixelsTaken = 0
      wrapper.height = 0
      wrapper.width = 0
      wrapper.wrappedElements = {}
      if wrapper.title then
        wrapper.title.x = 0
        wrapper.title.y = 0
        wrapper:applyStackPanelSettings(wrapper.title)
        wrapper:addChild(wrapper.title)
      end
    end
  end

  -- Detach existing cursors from the grid.
  for _, cursor in pairs(self.ui.cursors or {}) do
    if cursor and cursor.detach then cursor:detach() end
  end
  self.ui.cursors = {}

  self:setupRoster()
end


return CharacterSelect2p
