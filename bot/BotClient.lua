-- Headless bot client orchestrator.
--
-- Plays the role NetClient plays for a human, minus the UI/scene/audio
-- coupling: connect -> version-check -> login (-> later: join room, ready,
-- run a Match, send inputs). Reuses the low-level reusable net pieces
-- (TcpClient, ClientProtocol, Request/Response) directly.
--
-- Phase 0 step 1: connect + login only.

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

-- wire prefixes
local I_PREFIX = NetworkProtocol.clientMessageTypes.playerInput.prefix -- "I"
local D_PREFIX = NetworkProtocol.clientMessageTypes.deathEvent.prefix  -- "D"
local G_PREFIX = NetworkProtocol.clientMessageTypes.garbageEvent.prefix -- "G" (send attack)
local Y_PREFIX = NetworkProtocol.clientMessageTypes.displayEvent.prefix -- "Y" (display snapshot)
local SRV_D_PREFIX = NetworkProtocol.serverMessageTypes.deathEvent.prefix -- "D" (relayed)
local SRV_G_PREFIX = NetworkProtocol.serverMessageTypes.garbageEvent.prefix -- "G" (relayed attack)

-- The engine (GarbageDelivery, inside match:run) and DisplayEventCapture both
-- ship via GAME.netClient. Route to the bot currently ticking — set in
-- startMatch/tickMatch — so it works for one or many bots in a process.
local currentBot = nil
local function ensureNetClient()
  if GAME.netClient then return end
  GAME.netClient = {
    sendDisplayEvents = function(_, batch) if currentBot then currentBot:_shipDisplaySnapshot(batch) end end,
    sendGarbageEvent  = function(_, body) if currentBot then currentBot:_shipGarbageEvent(body) end end,
    flushDisplayEvents = function() end,
    -- GarbageDelivery.looseSyncActive gates on this: the bot IS a connected
    -- client (its own gameplay socket), so loose-sync garbage ships over the
    -- wire just like a real client — not direct-pushed to the opponent stack.
    isConnected = function() return true end,
  }
end

-- Phase-0 placeholder "brain": random input biased to fill the board so a
-- bot-vs-bot match tops out within seconds. Replaced by the real decide() +
-- CursorController in Phase 1. Bit layout: Right=1,Left=2,Down=4,Up=8,Swap=16,Raise=32.
local function randomInputChar()
  local bits = 0
  if math.random() < 0.5 then bits = bits + 32 end  -- Raise (fill fast)
  if math.random() < 0.12 then bits = bits + 16 end -- Swap
  local r = math.random()
  if r < 0.08 then bits = bits + 8
  elseif r < 0.16 then bits = bits + 4
  elseif r < 0.24 then bits = bits + 2
  elseif r < 0.32 then bits = bits + 1 end
  return KeyDataEncoding.base64encode[bits + 1]
end

---@class BotClient
local BotClient = class(function(self, opts)
  opts = opts or {}
  self.ip = opts.ip or "127.0.0.1"
  self.port = opts.port or 49569
  self.name = opts.name or "BotBella"
  self.brainKind = opts.brain or "heuristic"   -- "heuristic"|"random"|"expert"|"search"
  self.searchProfile = opts.searchProfile       -- optional per-player eval weights (brain == "search")
  self.difficulty = opts.difficulty or "medium" -- "easy" | "medium" | "hard" (cursor-speed/reaction cap)
  self.gameplay = TcpClient({ name = "bot-gameplay", defaultPort = self.port })
  -- Persisted server identity so re-runs reuse the same account instead of
  -- re-registering (and tripping the server's name-already-taken guard).
  self.userId = self:readIdentity() or "need a new user id"
  -- lobby/room/match state, populated by pump() from server-pushed messages
  self.publicId = nil
  self.roomNumber = nil
  self.localPlayerNumber = nil
  self.players = nil
  self.lobby = nil
  self.inRoom = false
  self.matchStart = nil -- {replay, startInMs, startAtMs} once matchStart arrives
  -- Player-settings stub matching a fresh client's localPlayer.settings exactly,
  -- so ServerMessages.toServerMenuState builds a byte-identical menu_state (incl.
  -- levelData, which the opponent's character-select reads). Character/stage are
  -- random, like a default client.
  self.level = opts.level or 10 -- corpus + play target is L10
  local level = self.level
  self.playerStub = {
    hasLoaded = false,
    settings = {
      level = level, difficulty = level, speed = 1,
      levelData = LevelPresets.getModern(level),
      style = GameModes.Styles.MODERN,
      selectedCharacterId = consts.RANDOM_CHARACTER_SPECIAL_VALUE, characterId = nil,
      selectedStageId = consts.RANDOM_STAGE_SPECIAL_VALUE, stageId = nil,
      panelId = nil,
      wantsReady = false, wantsRanked = false,
      inputMethod = "controller",
      endlessNoRaise = false,
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

-- Pump the gameplay socket and drive a Response to completion.
-- Returns status ("received"/"timeout"/"expired"), value.
function BotClient:await(response, label, timeoutSec)
  if not response then return "expired", nil end
  local deadline = socket.gettime() + (timeoutSec or 6)
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

  -- 1) version compatibility
  local status, value = self:await(
    self.gameplay:sendRequest(ClientProtocol.requestVersionCompatibilityCheck()), "version-check")
  if status ~= "received" then return false, "version check " .. status end
  if not value.versionCompatible then
    return false, "version incompatible (server build " .. tostring(value.serverBuildVersion) .. ")"
  end
  logger.info("bot: version compatible")

  -- 2) login
  status, value = self:await(
    self.gameplay:sendRequest(ClientProtocol.requestLogin(
      self.userId, self.name,
      self.level,   -- level
      "controller", -- inputMethod
      nil,          -- panels_dir (cosmetic; resolved client-side)
      -- Random character/stage, exactly like a fresh client's default. Sending
      -- nil is the missing-mod case that flickers the opponent's ready icon
      -- (ready_state_flash_root_cause); "__Random*" resolves to a bundled mod.
      consts.RANDOM_CHARACTER_SPECIAL_VALUE, nil, -- selected character (random), resolved
      consts.RANDOM_STAGE_SPECIAL_VALUE, nil,     -- selected stage (random), resolved
      false,        -- ranked
      false)),       -- save replays publicly
    "login")
  if status ~= "received" then return false, "login " .. status end
  if not value.login_successful then
    return false, "login denied: " .. tostring(value.reason)
  end

  self.publicId = value.publicId
  if value.new_user_id then
    self.userId = value.new_user_id
    self:writeIdentity(self.userId)
    logger.info("bot: registered new account, persisted user_id")
  end
  logger.info(string.format("bot: logged in as '%s' (publicId=%s)",
    self.name, tostring(self.publicId)))
  return true
end

-- Resolve our own slot in a room from the players table (server doesn't echo
-- it back post-sanitize; we match on our publicId).
local function findLocalNumber(players, publicId)
  for playerNumber, p in pairs(players) do
    if p.publicId == publicId then return playerNumber end
  end
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Apply one sanitized server-pushed message to our local state.
function BotClient:dispatch(msg)
  if msg.lobbyStateV2 then
    self.lobby = msg.content
  elseif msg.create_room or msg.addToRoom then
    self.roomNumber = msg.roomNumber
    self.players = msg.players
    self.gameMode = msg.gameMode
    self.inRoom = true
    self.localPlayerNumber = findLocalNumber(msg.players, self.publicId) or self.localPlayerNumber
    logger.info(string.format("bot[%s]: in room %s as slot %s (%d players)",
      self.name, tostring(self.roomNumber), tostring(self.localPlayerNumber),
      countKeys(msg.players)))
  elseif msg.playerJoinedRoom then
    -- incremental notice to existing room members (not a full snapshot)
    local j = msg.playerJoinedRoom
    self.players = self.players or {}
    self.players[j.playerNumber] = {
      playerNumber = j.playerNumber, name = j.name, publicId = j.publicId, settings = j.settings,
    }
    logger.info(string.format("bot[%s]: player joined slot %s (%s); now %d players",
      self.name, tostring(j.playerNumber), tostring(j.name), countKeys(self.players)))
  elseif msg.playerLeftRoom and self.players then
    for playerNumber, p in pairs(self.players) do
      if p.publicId == msg.playerLeftRoom.publicId then self.players[playerNumber] = nil end
    end
  elseif msg.match_start then
    self.matchStart = { replay = msg.replay, startInMs = msg.startInMs, startAtMs = msg.startAtMs }
    logger.info(string.format("bot[%s]: MATCH START (startInMs=%s)",
      self.name, tostring(msg.startInMs)))
  elseif msg[SRV_G_PREFIX] then
    -- relayed GarbageEvent: an attack. Apply to our stack if we're a recipient
    -- (and it isn't our own echo). Server stamped body.sender.
    local body = msg[SRV_G_PREFIX]
    if self.myStack and body.sender ~= self.localPlayerNumber
        and type(body.recipients) == "table" then
      for _, r in ipairs(body.recipients) do
        if r == self.localPlayerNumber then
          self.myStack:applyNetworkGarbage(body.garbage, body.sender)
          self._garbageRecvCount = (self._garbageRecvCount or 0) + 1
          break
        end
      end
    end
  elseif msg[SRV_D_PREFIX] then
    -- relayed DeathEvent. For 2p, a death we didn't send = the opponent's.
    self.oppDied = true
    self.outcome = self.outcome or "won"
    logger.info("bot[" .. self.name .. "]: opponent topped out (relayed D)")
  elseif msg.gameResult then
    self.matchEnded = true
    logger.info("bot[" .. self.name .. "]: gameResult received")
  elseif msg.challengeUpdate then
    -- someone challenged us in the lobby: always accept (reciprocate), which
    -- makes the server create the room and we fall into the normal match flow.
    local ch = msg.challengeUpdate
    if ch.challengeActive and ch.receiverId == self.publicId and not self.inRoom then
      self:acceptChallenge(ch.senderId, ch.gameModeId)
    end
  elseif msg.leave_room then
    self.inRoom = false
    logger.info("bot[" .. self.name .. "]: left room (" .. tostring(msg.reason) .. ")")
  end
  -- relayed input "I" and other messages fall through (ignored for 3a).
end

-- Non-blocking: read the socket and drain all pushed messages into state.
function BotClient:pump()
  self.gameplay:processIncomingMessages()
  local q = self.gameplay.receivedMessageQueue
  local msg = q:pop()
  while msg do
    self:dispatch(msg)
    msg = q:pop()
  end
end

-- Accept an incoming lobby challenge by reciprocating (mutual active challenge ->
-- server opens the room). gameModeId echoes whatever they challenged us to.
function BotClient:acceptChallenge(senderId, gameModeId)
  logger.info(string.format("bot[%s]: accepting challenge from %s (mode %s)",
    self.name, tostring(senderId), tostring(gameModeId)))
  self.gameplay:sendRequest(ClientProtocol.updateChallengeStatus(
    self.publicId, senderId, gameModeId, true))
end

function BotClient:createRoom(gameMode, openRoom)
  logger.info("bot[" .. self.name .. "]: creating room (" .. gameMode.name .. ")")
  -- displayHistoryEnabled=true so opponents (humans) render the bot from snapshots.
  self.gameplay:sendRequest(ClientProtocol.sendRoomRequest(gameMode, "normal", openRoom, true))
end

-- Pack + send one display snapshot as a Y message on this bot's socket.
function BotClient:_shipDisplaySnapshot(batch)
  local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
  local util = require("client.src.network.DisplaySnapshotUtil")
  local payload
  if ffiGuard.FFI_SUPPORTED and batch.from and batch.snapshot then
    payload = util.pack_snapshot(batch.from, batch.snapshot)
  end
  if not payload then payload = json.encode(batch) end
  self.gameplay:send(NetworkProtocol.markedMessageForTypeAndBody(Y_PREFIX, payload))
  self._displaySendCount = (self._displaySendCount or 0) + 1
end

-- Ship a garbage attack the engine produced. body = {senderFrame, recipients,
-- garbage}; the server stamps `sender` on relay.
function BotClient:_shipGarbageEvent(body)
  self.gameplay:send(NetworkProtocol.markedMessageForTypeAndBody(G_PREFIX, json.encode(body)))
  self._garbageSendCount = (self._garbageSendCount or 0) + 1
end

function BotClient:joinRoom(roomNumber, slotNumber)
  logger.info("bot[" .. self.name .. "]: joining room " .. tostring(roomNumber))
  self.gameplay:sendRequest(ClientProtocol.requestJoinRoom(roomNumber, slotNumber))
end

-- Declare loaded + ready + wants_ready in one settings update. A bot has no
-- assets, so it just asserts loaded=true. Server gate: wants_ready ∧ loaded ∧ ready.
function BotClient:sendReady()
  logger.info("bot[" .. self.name .. "]: readying up")
  -- Build the EXACT menu_state a real client sends (mirrors
  -- NetClient:sendPlayerSettings -> ServerMessages.toServerMenuState), so the
  -- opponent's character-select sees a complete, normal player — no missing
  -- fields, no hand-rolled shape.
  self.playerStub.hasLoaded = true
  self.playerStub.settings.wantsReady = true
  local menuState = ServerMessages.toServerMenuState(self.playerStub)
  self.gameplay:sendRequest(ClientProtocol.sendPlayerSettings(menuState))
end

-- Build the live engine match from the matchStart replay (same engine the
-- client runs, headless) and mark our own stack local. Call once after
-- matchStart arrives.
function BotClient:startMatch()
  local Match = require("common.engine.Match")
  self.match = Match.createFromReplay(self.matchStart.replay)
  self.myStack = self.match.stacks[self.localPlayerNumber]
  if not self.myStack then
    error("bot[" .. self.name .. "]: no stack at slot " .. tostring(self.localPlayerNumber))
  end
  self.myStack.is_local = true
  -- Generate each stack's starting board (starting_state), set countdown, and
  -- save the clock-0 rollback base — exactly as a real client does. Without this
  -- the bot simulates an EMPTY board from frame 0 (no panels -> brain always
  -- WAITs -> cursor never moves -> the human sees a blank board).
  self.match:start()
  if self.brainKind ~= "random" then
    -- THE bot, full strength. EnvelopeBrain now plays online here (the only thing it needed
    -- from SearchBrain was this seat in the online-play loop).
    self.brain = require("bot.EnvelopeBrain").new({})
    self.controller = require("bot.CursorController").new()
    self.boardState = require("bot.BoardState")
  end
  -- Display-snapshot capture so a human opponent sees the bot's board.
  ensureNetClient()
  currentBot = self
  self.capture = require("client.src.network.DisplayEventCapture").new(self.myStack, self.publicId or self.localPlayerNumber, self.myStack, nil)
  self.capture:start()

  self.scheduledStartMs = socket.gettime() * 1000 + (self.matchStart.startInMs or 500)
  self.matchEnded = false
  self.deathSent = false
  self._resultReported = false
  logger.info(string.format("bot[%s]: match built; my stack = slot %d; start in %dms",
    self.name, self.localPlayerNumber, self.matchStart.startInMs or 500))
end

-- Advance exactly one engine frame: feed+send our input, run, ship D on death,
-- and finalize on our death or the opponent's. Non-blocking; call per ~60Hz tick.
function BotClient:tickMatch()
  if not self.match or self.matchEnded then return end
  if socket.gettime() * 1000 < self.scheduledStartMs then return end -- hold for the aligned start instant
  currentBot = self -- route engine/capture sends (G, Y) to this bot's socket

  local stack = self.myStack
  -- Feed+send input while the stack is still running. NOTE: alive sentinel is
  -- game_over_clock == -1 (NOT 0); use game_ended() so we keep ticking up to the
  -- recorded death frame.
  if not stack:game_ended() then
    local char
    if self.brain then
      local st = self.boardState.extract(stack)
      local decision = self.brain:decide(st)
      char = self.controller:nextInput(st, decision)
      self.lastState, self.lastDecision = st, decision -- exposed for the game emitter
      -- decide->execute instrumentation (split "brain WAITs/picks bad" from
      -- "controller never executes"): count decisions, SWAP intents, swap inputs.
      self._decTotal = (self._decTotal or 0) + 1
      if decision and decision.type == "SWAP" then self._decSwap = (self._decSwap or 0) + 1 end
      if char == KeyDataEncoding.swap then self._swapInputs = (self._swapInputs or 0) + 1 end
    else
      char = randomInputChar()
    end
    -- EXECUTED action this frame (what the controller actually input) for the game
    -- emitter — the human corpus counts executed actions, so emit those, not the
    -- brain's per-frame intent (else swaps_per_clear is inflated). Movement/idle = WAIT.
    if char == KeyDataEncoding.swap then
      self.lastExecuted = { type = "SWAP", pos = { stack.cur_row, stack.cur_col } }
    elseif char == KeyDataEncoding.raise then
      self.lastExecuted = { type = "RAISE" }
    else
      self.lastExecuted = { type = "WAIT" }
    end
    stack:receiveConfirmedInput(char)
    self.gameplay:send(NetworkProtocol.markedMessageForTypeAndBody(I_PREFIX, char))
  end

  self.match:run()

  -- Ship a display snapshot (rate-limited internally) so the human sees the board.
  if self.capture then self.capture:tick() end

  if (stack.game_over_clock or -1) > 0 and not self.deathSent then
    self.deathSent = true
    logger.info(string.format("bot[%s]: topped out at frame %d -> sending D", self.name, stack.game_over_clock))
    self.gameplay:send(NetworkProtocol.markedMessageForTypeAndBody(D_PREFIX,
      json.encode({ senderFrame = stack.game_over_clock, stopWatch = stack.game_over_stopWatch, reason = "topOut" })))
  end

  if (self.deathSent or self.oppDied) and not self._resultReported then
    self._resultReported = true
    self.matchEnded = true
    if self.capture then self.capture:stop(); self.capture = nil end
    self.outcome = self.oppDied and "won" or "lost"
    logger.info(string.format("bot[%s]: match over -> %s", self.name, self.outcome))
    pcall(function() self.gameplay:sendRequest(ClientProtocol.reportLocalGameResult(self.outcome)) end)
  end
end

-- Leave any room and clear local room/match state. Used on startup to shed a
-- stale room membership left by a previously-crashed run (the server re-attaches
-- a returning account to its old room).
function BotClient:leaveRoom()
  pcall(function() self.gameplay:sendRequest(ClientProtocol.leaveRoom()) end)
  self.inRoom = false
  self.roomNumber = nil
  self.players = nil
  self.matchStart = nil
  self.oppDied = nil
end

function BotClient:disconnect()
  pcall(function() self.gameplay:sendRequest(ClientProtocol.leaveRoom()) end)
  self.gameplay:resetNetwork()
end

return BotClient
