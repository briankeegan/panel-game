local CharacterSelect = require("client.src.scenes.CharacterSelect")
local class = require("common.lib.class")
local ui = require("client.src.ui")
local system = require("client.src.system")
local consts = require("common.engine.consts")
local GraphicsUtil = require("client.src.graphics.graphics_util")

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
  -- portrait phones get a dedicated minimal waiting room (vertical roster +
  -- bottom-anchored character picker). Landscape/desktop is unchanged below.
  if system.isPortraitMode() then
    return self:loadPortraitUI()
  end

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

-- Portrait waiting room: a vertical roster of full-width player cards up top,
-- the character picker + dominant Ready / small Leave anchored to the bottom
-- (thumb reach). No panel/stage/level selectors. Per design review.
function CharacterSelect2p:loadPortraitUI()
  -- dim the busy game background so the roster/cards read clearly
  local dim = ui.UiElement({x = 0, y = 0, width = consts.CANVAS_WIDTH, height = consts.CANVAS_HEIGHT})
  dim.drawSelf = function(elem)
    GraphicsUtil.setColor(0, 0, 0, 0.55)
    GraphicsUtil.drawRectangle("fill", elem.x, elem.y, elem.width, elem.height)
    GraphicsUtil.setColor(1, 1, 1, 1)
  end
  self.uiRoot:addChild(dim)

  -- character picker = a single row of 4 with < > page arrows (the endless-style
  -- selector), NOT a multi-row block. createPageTurnButtons adds the arrows.
  local charRows = 1
  -- bottom-anchored picker grid: big character cells + page + action row
  self.ui.grid = ui.Grid({unitSize = 120, gridWidth = 4, gridHeight = charRows + 2, unitMargin = 8, hAlign = "center", vAlign = "bottom"})
  self.uiRoot:addChild(self.ui.grid)

  -- selectors are referenced by refreshRoster bookkeeping; create but never show
  self.ui.panelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.panelSelection:setTitle("panels")
  self.ui.stageSelection = ui.MultiPlayerSelectionWrapper({vFill = true, alignment = "left", hAlign = "center", vAlign = "center"})
  self.ui.stageSelection:setTitle("stage")
  self.ui.levelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.levelSelection:setTitle("level")

  self.ui.readyButton = self:createReadyButton()
  self.ui.leaveButton = self:createLeaveButton()
  self.ui.changeInputButton = self:createChangeInputButton()
  self.ui.changeInputButton:setVisibility(false)

  local characterButtons = self:getCharacterButtons()
  self.ui.characterGrid = self:createCharacterGrid(characterButtons, self.ui.grid, 4, charRows)
  self.ui.pageIndicator = self:createPageIndicator(self.ui.characterGrid)

  self.ui.grid:createElementAt(1, 1, 4, charRows, "characterSelection", self.ui.characterGrid, true)
  self.ui.grid:createElementAt(2, charRows + 1, 1, 1, "pageIndicator", self.ui.pageIndicator)
  -- Ready dominant (3 wide), Leave small (1 wide)
  self.ui.grid:createElementAt(1, charRows + 2, 3, 1, "readyButton", self.ui.readyButton)
  self.ui.grid:createElementAt(4, charRows + 2, 1, 1, "leaveButton", self.ui.leaveButton)

  self:createIconRow()
  self:setupRoster()
  self.ui.pageTurnButtons = self:createPageTurnButtons(self.ui.characterGrid)
end

-- a live ready/wait status label wired to the player's signals
function CharacterSelect2p:_readyBadge(player, x)
  local badge = ui.Label({hAlign = "right", vAlign = "center", x = x, text = "", translate = false})
  badge.refresh = function()
    if not player.hasLoaded then badge:setText("…", nil, false)
    elseif player.settings.wantsReady then badge:setText("READY", nil, false)
    else badge:setText("WAIT", nil, false) end
  end
  badge.refresh()
  badge.onChanged = function() badge.refresh() end
  player:connectSignal("wantsReadyChanged", badge, badge.onChanged)
  player:connectSignal("hasLoadedChanged", badge, badge.onChanged)
  return badge
end

-- rating · wins line; "unranked" when no data
local function statLine(player)
  local parts = {}
  if player.rating and tostring(player.rating) ~= "" then parts[#parts + 1] = tostring(player.rating) end
  if player.wins then parts[#parts + 1] = player.wins .. " wins" end
  return #parts > 0 and table.concat(parts, "  ·  ") or "unranked"
end

local function spine(elem, color)
  if color then
    GraphicsUtil.setColor(color[1], color[2], color[3], color[4] or 1)
    GraphicsUtil.drawRectangle("fill", elem.x, elem.y, 5, elem.height)
    GraphicsUtil.setColor(1, 1, 1, 1)
  end
end

-- LOCAL player's card == their editable settings panel (design: row 1 is special).
-- name + ready, then panels / level / stage controls the player can change.
function CharacterSelect2p:_createLocalCard(player, cardW, teamColor)
  -- Per design spec: header (name LEFT, stats RIGHT, ready badge RIGHT), then each
  -- control on its OWN line with a CENTERED label above a CENTERED full-width
  -- widget (so everything lines up on the card's center axis). Panels & Stage are
  -- carousels (big, with < > arrows); Level is a slider (no arrows).
  local headerH, labelH, gap = 60, 26, 14
  local ctrlW = cardW - 48
  local ctrlX = math.floor((cardW - ctrlW) / 2)
  local specs = {
    {label = "Panels", h = 96, make = function() return self:createPanelCarousel(player, 96) end},
    {label = "Level",  h = 72, make = function() return self:createLevelSlider(player, 44, 72) end},
    {label = "Stage",  h = 96, make = function()
      local sc = self:createStageCarousel(player, ctrlW)
      -- ensure a passenger is actually shown (setPassengerById(config.stage) is a
      -- no-op when that stage isn't in the loaded list -> empty carousel)
      if sc.passengers and sc.passengers[sc.selectedId or 1] then sc:setPassengerByIndex(sc.selectedId or 1) end
      return sc
    end},
  }

  local cardH = headerH + 8 + 16  -- extra bottom pad so Stage doesn't crowd next card
  for _, s in ipairs(specs) do cardH = cardH + labelH + s.h + gap end

  local card = ui.UiElement({width = cardW, height = cardH})
  card.drawSelf = function(elem)
    -- near-opaque so the busy game background doesn't bleed through (contrast)
    GraphicsUtil.setColor(0.07, 0.07, 0.10, 0.96)
    GraphicsUtil.drawRectangle("fill", elem.x, elem.y, elem.width, elem.height)
    GraphicsUtil.setColor(1, 1, 1, 0.05)
    GraphicsUtil.drawRectangle("fill", elem.x, elem.y, elem.width, elem.height)
    spine(elem, teamColor or {1, 0.8, 0.1, 0.9})
  end

  -- header
  card:addChild(ui.Label({x = 16, y = 12, text = (player.name or "You") .. " (you)", translate = false}))
  card:addChild(ui.Label({hAlign = "right", x = -16, y = 12, text = statLine(player), translate = false}))
  local badge = self:_readyBadge(player, -16)
  badge.vAlign = "top"
  badge.y = 36
  card:addChild(badge)

  local y = headerH
  for _, s in ipairs(specs) do
    card:addChild(ui.Label({hAlign = "center", y = y, text = s.label, translate = false}))
    -- Wrap the control in a sized row and let it FILL the row. Do NOT force
    -- vFill=false / height on the control after construction — StageCarousel is
    -- built vFill and breaks (renders far below) when that's overridden.
    local row = ui.UiElement({x = ctrlX, y = y + labelH, width = ctrlW, height = s.h})
    local control = s.make()
    -- the panel/stage carousels overlay a "1P" badge (for multi-player landscape);
    -- pointless here (single local player) — hide it.
    if control.playerNumberIcon then control.playerNumberIcon:setVisibility(false) end
    control.hFill = false
    control.x = 0
    control.width = ctrlW
    row:addChild(control)
    card:addChild(row)
    y = y + labelH + s.h + gap
  end

  return card, cardH
end

-- Collapsed read-only row for everyone else: solid dark card with icon, name,
-- rating·W/L, ready badge, and (host) a boot button.
function CharacterSelect2p:_createRemoteCard(player, cardW, cardH, canBoot, teamColor)
  local card = ui.UiElement({width = cardW, height = cardH})
  card.drawSelf = function(elem)
    GraphicsUtil.setColor(0.07, 0.07, 0.10, 0.96)
    GraphicsUtil.drawRectangle("fill", elem.x, elem.y, elem.width, elem.height)
    spine(elem, teamColor)
    GraphicsUtil.setColor(1, 1, 1, 1)
  end

  local iconBox = ui.UiElement({x = 12, y = 8, width = cardH - 16, height = cardH - 16})
  local icon = self:createPlayerIcon(player, {hideName = true, hideNumber = true})
  iconBox:addChild(icon)
  card:addChild(iconBox)
  self.ui.characterIcons[#self.ui.characterIcons + 1] = icon

  local name = player.name or "?"
  if #name > 14 then name = name:sub(1, 13) .. "…" end
  card:addChild(ui.Label({x = cardH + 4, y = 10, text = name, translate = false}))
  card:addChild(ui.Label({x = cardH + 4, y = math.floor(cardH / 2) + 4, text = statLine(player), translate = false}))

  local bootReserve = canBoot and cardH or 12
  card:addChild(self:_readyBadge(player, -(bootReserve + 8)))

  if canBoot then
    local pubId = player.publicId
    local bootBtn = ui.TextButton({
      hAlign = "right", vAlign = "center",
      width = cardH - 12, height = cardH - 12,
      label = ui.Label({text = "x", translate = false}),
      backgroundColor = {0.4, 0.05, 0.05, 0.85},
      outlineColor = {1, 0.4, 0.4, 1},
      onClick = function()
        if GAME.theme and GAME.theme.playCancelSfx then GAME.theme:playCancelSfx() end
        if GAME.netClient and GAME.netClient.kickPlayer then GAME.netClient:kickPlayer(pubId) end
      end,
    })
    bootBtn.onSelect = bootBtn.onClick
    card:addChild(bootBtn)
  end

  return card
end

-- Portrait roster: local player's editable card first, then a collapsed info row
-- per other player. Cursors drive the bottom character picker.
function CharacterSelect2p:setupPortraitRoster()
  self.ui.characterIcons = {}
  self.ui.playerInfos = {}

  local cardW = consts.CANVAS_WIDTH - 40
  local remoteH = 76
  local cardGap = 12

  local ownerId = self.battleRoom and self.battleRoom.ownerId
  local localPlayer = GAME and GAME.localPlayer
  local mode = self.battleRoom and self.battleRoom.mode
  local isOpenRoom = mode and (mode.openRoom == true
    or (mode.minPlayers and mode.maxPlayers and mode.minPlayers < mode.maxPlayers))
  local localIsHost = isOpenRoom and ownerId and localPlayer and localPlayer.publicId == ownerId

  for i, player in ipairs(self.players) do
    local cursor = self:createCursor(self.ui.grid, player)
    cursor.raise1Callback = function() self.ui.characterGrid:turnPage(-1) end
    cursor.raise2Callback = function() self.ui.characterGrid:turnPage(1) end
    self.ui.cursors[i] = cursor

    local teamColor = self:teamBorderColorForPlayer(player)
    if player.isLocal then
      self.ui.iconRow:addElement((self:_createLocalCard(player, cardW, teamColor)))
    else
      local canBoot = localIsHost and player.publicId ~= ownerId
      self.ui.iconRow:addElement(self:_createRemoteCard(player, cardW, remoteH, canBoot, teamColor))
    end
    -- breathing room between cards
    self.ui.iconRow:addElement(ui.UiElement({width = cardW, height = cardGap}))
  end
end

-- Creates all per-player UI: panel/stage/level selectors, cursors, top-row
-- character icons and player info cards. Roster-dependent; called from
-- loadUserInterface and rebuilt by refreshRoster on drop-in/drop-out.
function CharacterSelect2p:setupRoster()
  -- portrait uses a completely separate vertical-roster build
  if system.isPortraitMode() then
    return self:setupPortraitRoster()
  end
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

  -- portrait: selectors are intentionally hidden (minimal waiting room), so skip
  -- building the carousels/sliders entirely.
  local pm = system.isPortraitMode()

  for i, player in ipairs(self.players) do
    -- Online: only add the local player's selectors. Stage was already
    -- local-only; panels and level now match.
    local showSelectors = ((not self.battleRoom.online) or player.isLocal) and not pm
    if showSelectors then
      local panelCarousel = self:createPanelCarousel(player, panelHeight)
      self.ui.panelSelection:addElement(panelCarousel, player)
    end

    if player.isLocal and not pm then
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
        cursor.activeArea.y2 = pm and 7 or 6
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
-- portrait grid is only 4 wide (cols 6/7 don't exist) and row 6 is free there;
-- give the boot buttons their own row of 4. Capped at 4 visible on phones.
local BOOT_BUTTON_COLUMNS_PORTRAIT = {1, 2, 3, 4}
local BOOT_BUTTON_ROW_PORTRAIT = 7

local function bootButtonCells()
  if system.isPortraitMode() then
    return BOOT_BUTTON_COLUMNS_PORTRAIT, BOOT_BUTTON_ROW_PORTRAIT
  end
  return BOOT_BUTTON_COLUMNS, 6
end

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
    local cols, row = bootButtonCells()
    for _, col in ipairs(cols) do
      self.ui.grid:removeElementsIn(col, row, 1, 1)
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

  local cols, row = bootButtonCells()
  local slotIdx = 1
  for _, player in ipairs(self.battleRoom.players) do
    if slotIdx > #cols then break end
    if player.publicId ~= ownerId and not player.isLocal then
      local col = cols[slotIdx]
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
      self.ui.grid:createElementAt(col, row, 1, 1, "bootButton" .. col, btn)
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
  -- portrait: a VERTICAL stack of full-width player cards pinned to the top.
  -- setupPortraitRoster fills it; cards grow the screen DOWN instead of shrinking
  -- a horizontal strip.
  if system.isPortraitMode() then
    self.ui.iconRow = ui.StackPanel({alignment = "top", hAlign = "center", vAlign = "top", y = 18, width = consts.CANVAS_WIDTH - 40})
    self.uiRoot:addChild(self.ui.iconRow)
    return
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
