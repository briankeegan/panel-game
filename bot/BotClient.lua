-- Headless bot client for UPSTREAM Panel Attack (panel-attack/panel-game).
--
-- Plays the role NetClient plays for a human, minus the UI: connect ->
-- version-check -> login -> sit in the lobby -> accept a challenge -> ready ->
-- play -> rematch. Reuses the client's own net pieces (TcpClient, which also
-- answers the server's pings, ClientProtocol, ServerMessages) so the wire is
-- exactly a real client's.
--
-- HOW A MATCH WORKS HERE -- LOCKSTEP, NOT THE FORK'S LOOSE SYNC. Upstream has
-- no garbage, death or display messages. Every client simulates BOTH stacks
-- from the players' inputs: ours from the bot's own inputs, the opponent's from
-- the inputs the server relays ("I" messages). Garbage, rollback and game over
-- all come out of the engine's own Match:run, exactly as in a real client
-- (ClientMatch:run + PlayerStack:send_controls), and the result is reported as
-- the winner's player number, as NetClient:reportLocalGameResult does.
--
-- This file lives only in bot/ and is dropped onto a fresh checkout of
-- upstream beta at run time, so it must not depend on anything the fork adds
-- to the engine.

local class = require("common.lib.class")
local logger = require("common.lib.logger")
local socket = require("socket")
local lfs = require("lfs")
local TcpClient = require("client.src.network.TcpClient")
local ClientProtocol = require("common.network.ClientProtocol")
local NetworkProtocol = require("common.network.NetworkProtocol")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local consts = require("common.engine.consts")
local ServerMessages = require("client.src.network.ServerMessages") -- toServerMenuState (the canonical ready builder)
local LevelPresets = require("common.data.LevelPresets")
local GameModes = require("common.data.GameModes")

local IDENTITY_DIR = "bot/identities"

local I_PREFIX = NetworkProtocol.clientMessageTypes.playerInput.prefix     -- "I" (our input)
local OPP_PREFIX = NetworkProtocol.serverMessageTypes.opponentInput.prefix -- "I" (relayed opponent input)
local IDLE = KeyDataEncoding.base64encode[1]

---@class BotClient
local BotClient = class(function(self, opts)
  opts = opts or {}
  self.ip = opts.ip or "127.0.0.1"
  self.port = opts.port or 49569
  self.name = opts.name or "BotBella"
  -- Only the evaluator brain ships to upstream: EnvelopeBrain and its chip
  -- catalog stay on the fork.
  self.brainKind = opts.brain or "weighted"
  assert(self.brainKind == "weighted", "upstream bot supports brain 'weighted' only, got " .. tostring(opts.brain))
  self.searchProfile = opts.searchProfile       -- weight-set path (bot/profiles/*.json)
  self.cursorSpeed = opts.cursorSpeed           -- { cursorMoveInterval, reactionFrames }; nil = full speed
  self.gameplay = TcpClient()
  -- Persisted server identity so re-runs reuse the same account instead of
  -- re-registering (and tripping the server's name-already-taken guard).
  self.userId = self:readIdentity() or "need a new user id"
  self.newUserId = nil -- set when THIS login registered the account (the runner saves it back)
  self.publicId = nil
  self.roomNumber = nil
  self.localPlayerNumber = nil
  self.players = nil
  self.inRoom = false
  self.matchStart = nil
  self.oppInputs = {} -- relayed opponent inputs, held until the match exists to take them
  self.level = opts.level or 10
  -- Ranked is a login setting like level and character, and the bot sets it
  -- EXPLICITLY every time: at login and again on every ready. Off unless a
  -- caller opts in -- a bot's games must never move anyone's rating.
  self.ranked = opts.ranked == true
  local level = self.level
  -- Player-settings stub shaped like a fresh client's localPlayer.settings so
  -- ServerMessages.toServerMenuState builds a normal menu_state.
  self.playerStub = {
    hasLoaded = false,
    settings = {
      level = level, difficulty = level, speed = 1,
      levelData = LevelPresets.getModern(level),
      style = GameModes.Styles.MODERN,
      selectedCharacterId = consts.RANDOM_CHARACTER_SPECIAL_VALUE, characterId = nil,
      selectedStageId = consts.RANDOM_STAGE_SPECIAL_VALUE, stageId = nil,
      panelId = nil,
      wantsReady = false, wantsRanked = self.ranked,
      inputMethod = "controller",
    },
  }
end)

function BotClient:identityPath()
  return IDENTITY_DIR .. "/" .. self.name .. "_" .. self.ip .. ".txt"
end

function BotClient:readIdentity()
  local f = io.open(self:identityPath(), "r")
  if not f then return nil end
  local id = f:read("*a")
  f:close()
  id = id and id:gsub("%s+$", "")
  if id and #id > 0 then return id end
  return nil
end

function BotClient:writeIdentity(userId)
  lfs.mkdir("bot")
  lfs.mkdir(IDENTITY_DIR)
  local f = io.open(self:identityPath(), "w")
  if not f then
    logger.warn("bot: could not persist identity to " .. self:identityPath())
    return
  end
  f:write(tostring(userId))
  f:close()
end

-- Pump the socket and drive a Response to completion.
function BotClient:await(response, label, timeoutSec)
  if not response then return "expired", nil end
  -- Upstream's Response reads replies off GAME.netClient.tcpClient, a global,
  -- so point it at THIS bot's socket for as long as the wait lasts.
  GAME.netClient = GAME.netClient or {}
  GAME.netClient.tcpClient = self.gameplay
  local deadline = socket.gettime() + (timeoutSec or 8)
  while socket.gettime() < deadline do
    self.gameplay:processIncomingMessages()
    local status, value = response:tryGetValue()
    if status ~= "waiting" then
      return status, value
    end
    socket.sleep(0.005)
  end
  logger.warn("bot: timed out awaiting " .. tostring(label))
  return "timeout", nil
end

---@return boolean ok, string? err
function BotClient:login()
  logger.info("bot: connecting to " .. self.ip .. ":" .. self.port)
  if not self.gameplay:connectToServer(self.ip, self.port) then
    return false, "could not connect to " .. self.ip .. ":" .. self.port
  end

  local status, value = self:await(
    self.gameplay:sendRequest(ClientProtocol.requestVersionCompatibilityCheck()), "version-check")
  if status ~= "received" then return false, "version check " .. status end
  if not value.versionCompatible then
    return false, "version incompatible (network protocol " .. NetworkProtocol.NETWORK_VERSION .. ")"
  end

  status, value = self:await(
    self.gameplay:sendRequest(ClientProtocol.requestLogin(
      self.userId, self.name,
      self.level,   -- level
      "controller", -- inputMethod
      nil,          -- panels_dir (cosmetic)
      consts.RANDOM_CHARACTER_SPECIAL_VALUE, nil, -- character: random, like a fresh client
      consts.RANDOM_STAGE_SPECIAL_VALUE, nil,     -- stage: random, like a fresh client
      self.ranked,  -- ranked (off by default; see the constructor)
      false)),      -- save replays publicly
    "login")
  if status ~= "received" then return false, "login " .. status end
  if not value.login_successful then
    return false, "login denied: " .. tostring(value.reason)
  end

  self.publicId = value.publicId
  if value.new_user_id then
    self.userId = value.new_user_id
    self.newUserId = value.new_user_id
    self:writeIdentity(self.userId)
    logger.info("bot: registered new account, persisted user_id")
  end
  logger.info(string.format("bot: logged in as '%s' (publicId=%s)", self.name, tostring(self.publicId)))
  return true
end

local function findLocalNumber(players, publicId)
  for playerNumber, p in pairs(players) do
    if p.publicId == publicId then return playerNumber end
  end
end

-- Apply one sanitized server-pushed message to our local state.
function BotClient:dispatch(msg)
  if msg[OPP_PREFIX] then
    -- A relayed opponent input. Held rather than applied: a batch can carry
    -- match_start AND the first inputs, and the match is built after the batch.
    self.oppInputs[#self.oppInputs + 1] = msg[OPP_PREFIX]
  elseif msg.lobbyStateV2 then
    self.lobbyPlayers = msg.content and msg.content.players
  elseif msg.create_room then
    self.roomNumber = msg.roomNumber
    self.players = msg.players
    self.inRoom = true
    self.localPlayerNumber = findLocalNumber(msg.players, self.publicId) or self.localPlayerNumber
    logger.info(string.format("bot[%s]: in room %s as slot %s", self.name, tostring(self.roomNumber),
      tostring(self.localPlayerNumber)))
  elseif msg.match_start then
    -- inputs still queued belong to the previous match (NetClient drops them here too)
    self.oppInputs = {}
    self.matchStart = { replay = msg.replay }
    logger.info("bot[" .. self.name .. "]: MATCH START")
  elseif msg.gameResult then
    -- both sides reported; no more inputs are coming for this match
    self.oppInputs = {}
    self.matchEnded = true
    logger.info("bot[" .. self.name .. "]: gameResult received")
  elseif msg.gameAbort then
    self.oppInputs = {}
    self.matchEnded = true
    self.outcome = self.outcome or "aborted"
  elseif msg.challengeUpdate then
    -- someone challenged us in the lobby: always accept (reciprocate), which
    -- makes the server create the room and we fall into the normal match flow.
    local ch = msg.challengeUpdate
    if ch.challengeActive and ch.receiverId == self.publicId and not self.inRoom then
      self:acceptChallenge(ch.senderId, ch.gameModeId)
    end
  elseif msg.leave_room then
    self.inRoom = false
    self.players = nil
    self.roomNumber = nil
    if self.match and not self.matchEnded then
      self.matchEnded = true
      self.outcome = self.outcome or "aborted"
    end
    logger.info("bot[" .. self.name .. "]: left room (" .. tostring(msg.reason) .. ")")
  end
end

function BotClient:pump()
  if not self.gameplay:processIncomingMessages() then
    self.disconnected = true
  end
  local q = self.gameplay.receivedMessageQueue
  local msg = q:pop()
  while msg do
    self:dispatch(msg)
    msg = q:pop()
  end
end

function BotClient:acceptChallenge(senderId, gameModeId)
  logger.info(string.format("bot[%s]: accepting challenge from %s (mode %s)",
    self.name, tostring(senderId), tostring(gameModeId)))
  self.gameplay:sendRequest(ClientProtocol.updateChallengeStatus(self.publicId, senderId, gameModeId, true))
end

function BotClient:challenge(receiverId, gameModeId)
  self.gameplay:sendRequest(ClientProtocol.updateChallengeStatus(self.publicId, receiverId, gameModeId, true))
end

-- Declare loaded + ready in one settings update. A bot has no assets, so it
-- just asserts loaded. Server gate: wants_ready and loaded and ready.
function BotClient:sendReady()
  self.playerStub.hasLoaded = true
  self.playerStub.settings.wantsReady = true
  self.playerStub.settings.wantsRanked = self.ranked -- re-asserted on every ready, not just at login
  local menuState = ServerMessages.toServerMenuState(self.playerStub)
  self.gameplay:sendRequest(ClientProtocol.sendPlayerSettings(menuState))
end

-- Build the engine match from the match_start replay -- the same engine a real
-- client runs -- with our stack local and the opponent's fed by relayed inputs.
function BotClient:startMatch()
  local Match = require("common.engine.Match")
  self.match = Match.createFromReplay(self.matchStart.replay)
  self.myStack = self.match.stacks[self.localPlayerNumber]
  if not self.myStack then
    error("bot[" .. self.name .. "]: no stack at slot " .. tostring(self.localPlayerNumber))
  end
  self.myStack.is_local = true
  for i, stack in ipairs(self.match.stacks) do
    if stack ~= self.myStack then self.oppStack, self.oppNumber = stack, i end
  end
  self.match:start()
  self.brain = require("bot.WeightedBrain").new({ profile = self.searchProfile })
  self.controller = require("bot.CursorController").new(self.cursorSpeed)
  self.boardState = require("bot.BoardState")
  self.matchEnded, self.outcome, self._resultReported = false, nil, false
  logger.info(string.format("bot[%s]: match built; my stack = slot %d", self.name, self.localPlayerNumber))
end

local WAIT_DECISION = { type = "WAIT" }
-- Brain time allowed per frame. A 60Hz frame is 16.7ms and the engine needs
-- some of it for both stacks, so thinking gets about half.
local THINK_BUDGET = 0.008

-- Our input for this frame, exactly when a real client would send one
-- (PlayerStack:send_controls): never while an input is still buffered, and --
-- after the very first -- not until the opponent's first input has arrived, so
-- the side that got match_start earlier waits once instead of running ahead.
--
-- KEEPING PACE IS A RULE. In lockstep an input is owed every frame; a client
-- whose inputs trail by MAX_LAG frames (~3s) gets the match aborted. A
-- decision on a tall board costs up to a few hundred ms, so the brain never
-- runs to completion inside one frame: it runs as a coroutine, pauses between
-- candidates once THINK_BUDGET is spent, and resumes next frame. Meanwhile the
-- controller keeps executing (or idles) and the input goes out on time. A slow
-- decision just lands a few frames later, like a longer reaction; the decision
-- itself is identical to an uninterrupted one.
function BotClient:_sendInput()
  local stack = self.myStack
  if stack:game_ended() then return end
  if #stack.confirmedInput > 0 and self.oppStack and #self.oppStack.confirmedInput == 0 then return end
  if #stack.confirmedInput - stack.clock > 0 then return end

  local st = self.boardState.extract(stack)
  local decision = WAIT_DECISION
  if not self.controller:isBusy() then
    if not self.thinking then
      local brain, match = self.brain, self.match
      self.thinking = coroutine.create(function() return brain:decide(st, stack, match) end)
      self.thinkRises, self.thinkDisp = 0, st.displacement
    elseif st.displacement and self.thinkDisp and st.displacement > self.thinkDisp + 6 then
      -- a row committed while we thought (displacement runs 16 -> 0, then resets
      -- to 16): the whole board, and the cell we will pick, moved up one row
      self.thinkRises = self.thinkRises + 1
    end
    self.thinkDisp = st.displacement
    local deadline = socket.gettime() + THINK_BUDGET
    self.brain.pause = function() if socket.gettime() > deadline then coroutine.yield() end end
    local ok, result = coroutine.resume(self.thinking)
    if not ok then error(debug.traceback(self.thinking, result)) end
    if coroutine.status(self.thinking) == "dead" then
      self.thinking = nil
      decision = result or WAIT_DECISION
      if decision.type == "SWAP" and self.thinkRises > 0 then
        local row = decision.pos[1] + self.thinkRises
        decision = (row <= (st.rows or 12)) and { type = "SWAP", pos = { row, decision.pos[2] } } or WAIT_DECISION
      end
    end
  end
  local char = self.controller:nextInput(st, decision) or IDLE
  self.gameplay:send(NetworkProtocol.markedMessageForTypeAndBody(I_PREFIX, char))
  stack:receiveConfirmedInput(char)
end

-- One tick of a real client's ClientMatch:run at 60Hz: take the opponent's
-- relayed inputs, send ours, let the engine run both stacks (it catches the
-- opponent up and rolls back for late garbage), and report once it has ended.
function BotClient:tickMatch()
  if not self.match or self._resultReported then return end

  if self.oppStack then
    for i = 1, #self.oppInputs do self.oppStack:receiveConfirmedInput(self.oppInputs[i]) end
  end
  self.oppInputs = {}

  self:_sendInput()
  self.match:run()

  if self.match:hasEnded() then
    self._resultReported = true
    self.match:handleMatchEnd()
    if self.match.aborted then
      self.outcome = "aborted"
      logger.warn(string.format("bot[%s]: match aborted%s -- my clock %d (%d inputs), opponent clock %d (%d inputs)",
        self.name, self.match.desyncError and " as irrecoverably desynced" or "",
        self.myStack.clock, #self.myStack.confirmedInput, self.oppStack.clock, #self.oppStack.confirmedInput))
      pcall(function() self.gameplay:sendRequest(ClientProtocol.sendMatchAbort(self.roomNumber)) end)
    else
      local winners = self.match:getWinners()
      local report
      if #winners == 1 then
        local winnerNumber
        for i, stack in ipairs(self.match.stacks) do if stack == winners[1] then winnerNumber = i end end
        report = winnerNumber
        self.outcome = (winnerNumber == self.localPlayerNumber) and "won" or "lost"
      else
        report = 0 -- two winners is a draw, which the server calls 0
        self.outcome = "draw"
      end
      self.gameplay:sendRequest(ClientProtocol.reportLocalGameResult(report))
    end
    logger.info(string.format("bot[%s]: match over -> %s", self.name, self.outcome))
  end
end

-- Forget the finished match; the room stays open for a rematch.
function BotClient:resetMatch()
  self.match, self.matchStart, self.myStack, self.oppStack = nil, nil, nil, nil
  self.matchEnded, self._resultReported = false, false
  self.brain, self.controller, self.thinking = nil, nil, nil
end

function BotClient:leaveRoom()
  pcall(function() self.gameplay:sendRequest(ClientProtocol.leaveRoom()) end)
  self.inRoom = false
  self.roomNumber = nil
  self.players = nil
  self.matchStart = nil
end

function BotClient:disconnect()
  pcall(function() self.gameplay:sendRequest(ClientProtocol.leaveRoom()) end)
  self.gameplay:resetNetwork()
end

return BotClient
