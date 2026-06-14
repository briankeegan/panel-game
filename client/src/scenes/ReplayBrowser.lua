local Scene = require("client.src.scenes.Scene")
local consts = require("common.engine.consts")
local input = require("client.src.inputManager")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local fileUtils = require("client.src.FileUtils")
local ReplayV3 = require("common.data.ReplayV3")
local class = require("common.lib.class")
local ReplayLauncher = require("client.src.ReplayLauncher")
local logger = require("common.lib.logger")

local ReplayBrowser = class(
  function (self, sceneParams)
    self.keepMusic = true
    self:load(sceneParams)
  end,
  Scene
)

ReplayBrowser.name = "ReplayBrowser"

local selection = nil
-- Player-scoped when multiple clients share one save dir (see FileUtils); plain
-- "replays" otherwise. Must match what fileUtils.saveReplay writes to.
local base_path = fileUtils.replayBasePath()
local current_path = "/"
local path_contents = {}
local filename = nil
local state = "browser"
-- technically this should start as nil but it drives the language server a bit crazy
---@type ReplayV3
local selectedReplay

local menu_x = 400
local menu_y = 280
local menu_h = 14
local menu_cursor_offset = 16

local cursor_pos = 0

local replay_id_top = 0

-- Cache for the hovered-folder win/loss panel; keyed by folder path so we only
-- recompute when the cursor moves to a different folder (see computeFolderStats).
local statsKey
local statsData

local function replayMenu()
  if (replay_id_top == 0) then
    if current_path ~= "/" then
      GraphicsUtil.print("< " .. loc("rp_browser_up") .. " >", menu_x, menu_y)
    else
      GraphicsUtil.print("< " .. loc("rp_browser_root") .. " >", menu_x, menu_y)
    end
  else
    GraphicsUtil.print("^ " .. loc("rp_browser_more") .. " ^", menu_x, menu_y)
  end

  for i, p in pairs(path_contents) do
    if (i > replay_id_top) and (i <= replay_id_top + 20) then
      GraphicsUtil.print(p, menu_x, menu_y + (i - replay_id_top) * menu_h)
    end
  end

  if #path_contents > replay_id_top + 20 then
    GraphicsUtil.print("v " .. loc("rp_browser_more") .. " v", menu_x, menu_y + 21 * menu_h)
  end

  GraphicsUtil.print(">", menu_x - menu_cursor_offset + math.sin(love.timer.getTime() * 8) * 5, menu_y + (cursor_pos - replay_id_top) * menu_h)
end

local function moveCursor(dir)
  cursor_pos = wrap(0, cursor_pos + dir, #path_contents)
  if cursor_pos <= replay_id_top then
    replay_id_top = math.max(cursor_pos, 1) - 1
  end
  if replay_id_top < cursor_pos - 20 then
    replay_id_top = cursor_pos - 20
  end
end

local function updateBrowsingPath(new_path)
  statsKey = nil -- listing changed; force the stats panel to recompute on next hover
  if new_path then
    cursor_pos = 0
    replay_id_top = 0
    if new_path == "" then
      new_path = "/"
    end
    current_path = new_path
  end
  path_contents = fileUtils.freshDirectoryItems(base_path .. current_path)
  logger.info(string.format("ReplayBrowser: saveDir=%s  listing=[%s]  -> %d items: %s",
    love.filesystem.getSaveDirectory(), base_path .. current_path,
    #path_contents, table.concat(path_contents, ", ")))
  if not path_contents[cursor_pos] then
    cursor_pos = replay_id_top
  end
end
  
local function setPathToParentDir()
  updateBrowsingPath(current_path:gsub("(.*/).*/$", "%1"))
end

local function selectMenuItem()
  if cursor_pos == 0 then
    setPathToParentDir()
  else
    local item = path_contents[cursor_pos]
    selection = base_path .. current_path .. item
    -- Replay files are .json; everything else is a folder. Avoids
    -- love.filesystem.getInfo, which is as unreliable as getDirectoryItems on
    -- this love build. Read fresh from the OS too (see fileUtils).
    if item:sub(-5) == ".json" then
      filename = selection
      local data = fileUtils.readJsonFileFresh(selection)
      local replay = data and ReplayV3.createFromTable(data, true)
      if replay then
        selectedReplay = replay
      else
        GAME.theme:playCancelSfx()
      end
      return not not replay
    else
      updateBrowsingPath(current_path .. item .. "/")
    end
  end
end

-- Drill version/year/month/day, preferring today's folder at each level and
-- otherwise the most recent (greatest-named) one present, so the browser opens
-- on today's replays (or the latest day) instead of the bare version-folder
-- root. Stops early if a level is empty. Folder names are fixed-width
-- (v049, 2026, 06, 13), so plain string comparison orders them correctly.
local function latestDatePath()
  local today = {"v" .. consts.ENGINE_VERSION, os.date("%Y"), os.date("%m"), os.date("%d")}
  local path = "/"
  for _, prefer in ipairs(today) do
    local items = fileUtils.freshDirectoryItems(base_path .. path)
    if #items == 0 then
      break
    end
    local pick
    for _, item in ipairs(items) do
      if item == prefer then
        pick = prefer
        break
      elseif pick == nil or item > pick then
        pick = item
      end
    end
    path = path .. pick .. "/"
  end
  return path
end

function ReplayBrowser:load()
  if GAME.lastReplayPath then
    current_path = string.sub(GAME.lastReplayPath, (string.len(base_path) + 1)) .. "/"
  elseif current_path == "/" then
    -- First open with nothing saved this session: jump to today's replays
    -- instead of the bare root. A later reopen keeps wherever you browsed to.
    current_path = latestDatePath()
  end

  state = "browser"
  updateBrowsingPath(current_path)
end

-- 2+ human players = a multiplayer match (VS/FFA/Team). Challenge mode has a
-- single human stack, so it stays on the info screen like the other solo modes.
local function isMultiplayerReplay(replay)
  local humans = 0
  for _, stack in ipairs(replay.stacks) do
    if stack.stackType == ReplayV3.stackTypes.Stack then
      humans = humans + 1
    end
  end
  return humans >= 2
end

function ReplayBrowser:update()
  if state == "browser" then
    if input.isDown["MenuEsc"] then
      GAME.theme:playCancelSfx()
      GAME.navigationStack:pop()
    end
    if input.isDown["MenuSelect"] then
      GAME.theme:playValidationSfx()
      if selectMenuItem() then
        -- Multiplayer replays launch on a single click; solo show the info screen first.
        if isMultiplayerReplay(selectedReplay) and ReplayV3.replayCanBeViewed(selectedReplay) then
          ReplayLauncher.launch(selectedReplay)
        else
          state = "info"
        end
      end
    end
    if input.isDown["MenuBack"] then
      if current_path == "/" then
        GAME.theme:playCancelSfx()
      else
        GAME.theme:playValidationSfx()
        setPathToParentDir()
      end
    end
    if input:isPressedWithRepeat("MenuUp") then
      GAME.theme:playMoveSfx()
      moveCursor(-1)
    end
    if input:isPressedWithRepeat("MenuDown") then
      GAME.theme:playMoveSfx()
      moveCursor(1)
    end
  elseif state == "info" then
    if input.isDown["MenuEsc"] or input.isDown["MenuBack"] then
      GAME.theme:playValidationSfx()
      state = "browser"
    end
    if input.isDown["MenuSelect"] then
      if ReplayV3.replayCanBeViewed(selectedReplay) then
        GAME.theme:playValidationSfx()
        ReplayLauncher.launch(selectedReplay)
      else
        GAME.theme:playCancelSfx()
      end
    end
  end
end

-- Roster folders are the leaf match folders: VS_/FFA_/Team_ + sorted names.
local function isRosterFolder(name)
  return name:find("^VS_") or name:find("^FFA_") or name:find("^Team_")
end

local function rosterOf(folderName)
  local roster = folderName:gsub("^VS_", ""):gsub("^FFA_", ""):gsub("^Team_", "")
  local names = {}
  -- Names are joined with _vs_; the trailing append lets the last name match too.
  for n in (roster .. "_vs_"):gmatch("(.-)_vs_") do
    names[#names + 1] = n
  end
  return names
end

-- Both mean "no winner" in a multiplayer filename (game_<n>_winner_<X>_HH-MM-SS).
local DRAW_LABELS = {draw = true, INCOMPLETE = true}

-- Win tally for a roster folder, derived purely from the replay filenames — no
-- JSON is read or parsed. VS/FFA name their winner by player, so we seed the
-- roster from the folder name and show every player (including 0 wins). Team
-- folders name their winner by team COLOR (Pink/Purple), which the folder name
-- doesn't carry, so we discover those tokens from the files instead.
local function computeFolderStats(folderPath, folderName)
  local isTeam = folderName:find("^Team_") ~= nil
  local wins, order = {}, {}
  if not isTeam then
    for _, name in ipairs(rosterOf(folderName)) do
      wins[name] = 0
      order[#order + 1] = name
    end
  end
  local total, draws, other = 0, 0, 0
  for _, item in ipairs(fileUtils.freshDirectoryItems(folderPath)) do
    if item:sub(-5) == ".json" then
      total = total + 1
      local winner = item:match("winner_(.-)_%d%d%-%d%d%-%d%d")
      if winner == nil or DRAW_LABELS[winner] then
        draws = draws + 1
      elseif wins[winner] ~= nil then
        wins[winner] = wins[winner] + 1
      elseif isTeam then
        wins[winner] = 1
        order[#order + 1] = winner -- newly seen team color
      else
        other = other + 1 -- name we couldn't map to the roster (e.g. _vs_ in a name)
      end
    end
  end
  if isTeam then table.sort(order) end -- stable color ordering across hovers
  return {total = total, order = order, wins = wins, draws = draws, other = other}
end

function ReplayBrowser:draw()
  themes[config.theme].images.bg_main:draw()
  GraphicsUtil.drawRectangle("fill", 0, 0, consts.CANVAS_WIDTH, consts.CANVAS_HEIGHT, 0, 0, 0, 0.55)

  if state == "browser" then
    GraphicsUtil.print(loc("rp_browser_header"), menu_x + 170, menu_y - 40)
    GraphicsUtil.print(loc("rp_browser_current_dir", base_path .. current_path), menu_x, menu_y - 40 + menu_h)
    replayMenu()

    -- Win/loss panel on the right: while hovering a match folder, or while
    -- browsing inside one (current folder is the roster folder).
    local statsFolder, statsDir
    local hovered = cursor_pos > 0 and path_contents[cursor_pos] or nil
    if hovered and isRosterFolder(hovered) then
      statsFolder, statsDir = hovered, current_path .. hovered .. "/"
    else
      local cur = current_path:match("([^/]+)/$")
      if cur and isRosterFolder(cur) then
        statsFolder, statsDir = cur, current_path
      end
    end

    if statsFolder then
      if statsKey ~= statsDir then
        statsKey = statsDir
        statsData = computeFolderStats(base_path .. statsDir, statsFolder)
      end
      local sx, sy = menu_x + 360, menu_y
      GraphicsUtil.print(statsFolder, sx, sy)
      GraphicsUtil.print(loc("rp_browser_stats_games", statsData.total), sx, sy + menu_h * 2)
      local row = 4
      for _, name in ipairs(statsData.order) do
        GraphicsUtil.print(name .. ": " .. (statsData.wins[name] or 0), sx, sy + menu_h * row)
        row = row + 1
      end
      GraphicsUtil.print(loc("rp_browser_stats_draws") .. ": " .. statsData.draws, sx, sy + menu_h * row)
      row = row + 1
      if statsData.other > 0 then
        GraphicsUtil.print(loc("rp_browser_stats_other") .. ": " .. statsData.other, sx, sy + menu_h * row)
      end
    end
  elseif state == "info" then
    local next_func = nil
    if ReplayV3.replayCanBeViewed(selectedReplay) == false then
      GraphicsUtil.print(loc("rp_browser_wrong_version"), menu_x - 150, menu_y - 80 + menu_h)
    end

    GraphicsUtil.print(loc("rp_browser_info_header"), menu_x + 170, menu_y - 40)
    GraphicsUtil.print(filename or "", menu_x - 150, menu_y - 40 + menu_h)

    local modeText
    if selectedReplay.metadata.gameModeName == "VS" then
      modeText = loc("rp_browser_info_2p_vs")
    elseif selectedReplay.metadata.gameModeName == "challenge" then
      modeText = loc("mm_1_challenge_mode")
    elseif selectedReplay.metadata.gameModeName == "vsSelf" then
      modeText = loc("mm_1_vs")
    elseif selectedReplay.metadata.gameModeName == "training" then
      modeText = loc("mm_1_training")
    elseif selectedReplay.metadata.gameModeName == "puzzle" then
      modeText = loc("mm_1_puzzle")
    elseif selectedReplay.metadata.gameModeName == "timeattack" then
      modeText = loc("mm_1_time")
    elseif selectedReplay.metadata.gameModeName == "endless" then
      modeText = loc("mm_1_endless")
    else
      modeText = "Unknown"
    end

    GraphicsUtil.print(modeText, menu_x + 220, menu_y + 20)

    local offsetX = 0
    for i, player in ipairs(selectedReplay.metadata.stacks) do
      ---@cast player StackMetadata
      local stack = selectedReplay.stacks[player.stackIndex]
      GraphicsUtil.print(loc("rp_browser_info_" .. i .. "p"), menu_x + offsetX, menu_y + 50)
      GraphicsUtil.print(loc("rp_browser_info_name", player.name or ("Player " .. i)), menu_x + offsetX, menu_y + 65)
      GraphicsUtil.print(loc("rp_browser_info_character", player.characterId or ""), menu_x + offsetX, menu_y + 80)
      if stack.stackType == 1 then
        ---@cast player StackMetadata
        ---@cast stack ReplayStack
        if player.level then
          GraphicsUtil.print(loc("rp_browser_info_level", player.level), menu_x + offsetX, menu_y + 95)
        else
          if player.difficulty then
            GraphicsUtil.print(loc("rp_browser_info_speed", stack.levelData.startingSpeed), menu_x + offsetX, menu_y + 95)
            GraphicsUtil.print(loc("rp_browser_info_difficulty", player.difficulty), menu_x + offsetX, menu_y + 110)
          end
        end
      else
        ---@cast player SimulatedStackMetadata
        if player.challengeModeDifficulty then
          GraphicsUtil.print(loc("challenge_difficulty_" .. player.challengeModeDifficulty), menu_x + offsetX, menu_y + 95)
        end
        if player.stageIndex then
          GraphicsUtil.print(loc("stage") .. " " .. player.stageIndex, menu_x + offsetX, menu_y + 110)
        end
      end
      offsetX = offsetX + 300
    end

    if selectedReplay.metadata.ranked then
      GraphicsUtil.print(loc("rp_browser_info_ranked"), menu_x + 200, menu_y + 130)
    end

    if ReplayV3.replayCanBeViewed(selectedReplay) then
      GraphicsUtil.print(loc("rp_browser_watch"), menu_x + 75, menu_y + 150)
    end
  end
end

return ReplayBrowser