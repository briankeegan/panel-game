-- GarbageDelivery: per-tick garbage shipping + cross-stack distribution.
--
-- Owns:
--   * drainNetworkGarbageForFrame (rollback re-apply of network-injected G)
--   * per-recipient pickup from each of its sources (single-target rooms)
--   * per-sender distribution to all targets (multi-target rooms: FFA/team)
--   * local→remote G emission, local↔local self-attack, remote-source suppress
--
-- Does NOT know about:
--   * any rendering pipeline (visual code may swap viewers freely)
--   * view-stack tick state, telegraph rendering, or anything visual
--   * which subset of stacks is "currently ticking" — runs on the routing
--     topology, not on per-stack tick scheduling
--
-- Contract with Match: Match constructs one of these and calls
-- `gd:tick()` once per inner Match:run iteration. Reads the match's
-- routing topology fields (stacks, garbageTargets, garbageSources,
-- garbageMode, teamGarbageState, fromReplay) but never anything view-
-- shaped. Mutates per-match accounting counters on the match object.

local logger = require("common.lib.logger")
local tableUtils = require("common.lib.tableUtils")
local shallowcpy = shallowcpy
local TeamUtils = require("common.data.TeamUtils")

---@class GarbageDelivery
---@field match Match
local GarbageDelivery = {}
GarbageDelivery.__index = GarbageDelivery

---@param match Match
---@return GarbageDelivery
function GarbageDelivery.new(match)
  return setmetatable({ match = match }, GarbageDelivery)
end

local function isStackAlive(s)
  return s and (s.game_over_clock or -1) <= 0
end

-- Loose-sync requires a live netClient connection AND a non-replay
-- match. Replays / scrub-preview use direct push, no wire.
local function looseSyncActive(match)
  return LOOSE_SYNC_GARBAGE
      and not match.fromReplay
      and GAME and GAME.netClient and GAME.netClient:isConnected()
end

----------------------------------------------------------------------
-- Public API: Match:run calls these around stack ticks.
--
-- tickPreSim runs BEFORE stack:run() so drainNetworkGarbageForFrame
-- replays network-injected garbage at this exact frame (rollback
-- requires the queue contents match what was there originally).
-- Single-target shipping rides this same loop.
--
-- tickPostSim runs AFTER stack:run() so multi-target distribution
-- picks up garbage that this tick's stacks just produced.
----------------------------------------------------------------------

function GarbageDelivery:tickPreSim()
  local match = self.match
  for _, stack in ipairs(match.stacks) do
    if stack then self:_pushToRecipient(stack) end
  end
end

function GarbageDelivery:tickPostSim()
  self:_distributeMultiTarget()
end

----------------------------------------------------------------------
-- Per-recipient pickup (single-target senders only; multi-target
-- senders go through _distributeMultiTarget instead).
----------------------------------------------------------------------

function GarbageDelivery:_pushToRecipient(stack)
  -- Replay network-injected garbage at the same frame it was originally
  -- received, so a rollback past the receive frame doesn't permanently
  -- lose the staging push.
  stack:drainNetworkGarbageForFrame(stack.stopWatch)

  local match = self.match
  for _, st in ipairs(match.garbageSources[stack]) do
    local senderIndex = tableUtils.indexOf(match.stacks, st)
    -- Multi-target senders are handled by _distributeMultiTarget; skip here.
    if senderIndex and #match.garbageTargets[senderIndex] > 1 then
      -- skip
    -- Skip remote senders before the pop: see _distributeMultiTarget for
    -- the full rationale (same latent-drop risk). Offline / replay
    -- engines DO want this pickup path even for is_local=false senders
    -- because there's no wire to relay through.
    elseif st.is_local or match.fromReplay then
      local oldestTransitTime = st:getOldestFinishedGarbageTransitTime()
      if oldestTransitTime and ((not st.outgoingGarbage.illegalStuffIsAllowed)
                                or (#stack.incomingGarbage.stagedGarbage < 72)) then
        local readyClock
        if match.fromReplay then
          readyClock = stack.stopWatch
        elseif st.stopWatch >= oldestTransitTime then
          readyClock = oldestTransitTime
        end
        if readyClock then
          local garbageDelivery = st:getReadyGarbageAt(readyClock)
          if garbageDelivery then
            self:_deliverOne(st, stack, garbageDelivery)
          end
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- Per-sender distribution (multi-target: FFA "all" + team "shared").
----------------------------------------------------------------------

function GarbageDelivery:_distributeMultiTarget()
  local match = self.match
  for senderIndex, targets in ipairs(match.garbageTargets) do
    if #targets > 1 then
      local sender = match.stacks[senderIndex]
      -- Skip remote senders early: their outgoing-garbage queue is either
      -- empty (snapshot pipeline doesn't tick them) or echo from input
      -- replication that we'd silently drop via _deliverMulti's
      -- "not source.is_local → return". Popping before the source-side
      -- check would mutate (and lose) any garbage the queue contained.
      -- The authoritative G from the source's own machine drives all
      -- visuals via applyGarbageEvent on every client.
      if sender.is_local then
        local oldestTransitTime = sender:getOldestFinishedGarbageTransitTime()
        if oldestTransitTime and sender.stopWatch >= oldestTransitTime then
          if match.garbageMode == "shared" then
            self:_distributeShared(senderIndex, sender, oldestTransitTime)
          else
            self:_distributeAll(senderIndex, sender, targets, oldestTransitTime)
          end
        end
      end
    end
  end
end

function GarbageDelivery:_distributeShared(senderIndex, sender, oldestTransitTime)
  local match = self.match
  local teamState = match.teamGarbageState and match.teamGarbageState[senderIndex]
  if not (teamState and #teamState.enemyIndices > 0) then return end

  local stacks = match.stacks
  local alive = function(slot) return isStackAlive(stacks[slot]) end

  -- Pre-flight: at least one living enemy BEFORE popping the transit
  -- bundle. getReadyGarbageAt mutates the queue, so a pop followed by
  -- no-living-enemies would silently drop the whole batch.
  local _, firstSlot = TeamUtils.findNextLiving(
    teamState.enemyIndices, teamState.currentTargetIndex, alive)
  if not firstSlot then return end

  local garbageDelivery = sender:getReadyGarbageAt(oldestTransitTime)
  if not garbageDelivery then return end

  -- Per-piece rotation: a chain/combo with multiple pieces at the same
  -- transit time would otherwise dump the entire batch on a single enemy
  -- with one cursor advance. Rotating per piece spreads across living
  -- enemies in order.
  for _, g in ipairs(garbageDelivery) do
    local _, pickedSlot, nextLivingIndex = TeamUtils.findNextLiving(
      teamState.enemyIndices, teamState.currentTargetIndex, alive)
    if not pickedSlot then
      logger.warn(string.format(
        "shared-mode garbage dropped mid-batch: sender=%d ran out of living enemies",
        senderIndex))
      return
    end
    if nextLivingIndex then
      teamState.currentTargetIndex = nextLivingIndex
    end
    self:_deliverOne(sender, stacks[pickedSlot], { shallowcpy(g) })
  end
end

function GarbageDelivery:_distributeAll(senderIndex, sender, targets, oldestTransitTime)
  local livingTargets = {}
  for _, target in ipairs(targets) do
    if isStackAlive(target) then
      livingTargets[#livingTargets + 1] = target
    end
  end
  if #livingTargets == 0 then return end

  local garbageDelivery = sender:getReadyGarbageAt(oldestTransitTime)
  if not garbageDelivery then return end

  self:_deliverMulti(sender, livingTargets, garbageDelivery)
end

----------------------------------------------------------------------
-- Routing: where does garbage actually go? Local→remote = G emit.
-- Remote source = suppress (server's relayed G drives all visuals).
-- Local→local = direct push + G emit (vsSelf).
-- Offline / replay = direct push.
----------------------------------------------------------------------

function GarbageDelivery:_deliverOne(source, target, garbageDelivery)
  local match = self.match
  local active = looseSyncActive(match)
  local senderId = tableUtils.indexOf(match.stacks, source)

  if active then
    if source.is_local and not target.is_local then
      self:_emitG(source, { target }, garbageDelivery, "G emit")
      return
    elseif not source.is_local then
      -- Remote source: server's relayed G drives every machine's visuals.
      return
    else
      -- Local→local (vsSelf): push locally + emit G so spectators see it.
      -- ClientMatch:_applyGarbageEventNow's echo guard prevents double-apply
      -- on the sender's own machine.
      target:receiveGarbage(garbageDelivery, senderId)
      self:_emitG(source, { target }, garbageDelivery, "G emit (self)")
      return
    end
  end
  -- Offline / replay: direct push, no wire.
  target:receiveGarbage(garbageDelivery, senderId)
end

function GarbageDelivery:_deliverMulti(source, targets, garbageDelivery)
  local match = self.match
  local active = looseSyncActive(match)

  if active and source.is_local then
    -- Local→multiple remote: one G with all recipients.
    local recipientIndices = {}
    for _, target in ipairs(targets) do
      if not target.is_local then
        local idx = tableUtils.indexOf(match.stacks, target)
        if idx then recipientIndices[#recipientIndices + 1] = idx end
      end
    end
    if #recipientIndices > 0 then
      self:_emitGMulti(source, recipientIndices, garbageDelivery)
    end
    return
  elseif active and not source.is_local then
    -- Remote source: suppress, server's relayed G delivers.
    return
  end
  -- Local↔local or offline: direct push per target.
  local senderId = tableUtils.indexOf(match.stacks, source)
  for _, target in ipairs(targets) do
    local garbageCopy = {}
    for j, g in ipairs(garbageDelivery) do garbageCopy[j] = shallowcpy(g) end
    target:receiveGarbage(garbageCopy, senderId)
  end
end

----------------------------------------------------------------------
-- Wire emit (calls into GAME.netClient). Per-match accounting counters
-- live on the match object so the existing G summary log keeps working.
----------------------------------------------------------------------

function GarbageDelivery:_emitG(source, targets, garbageDelivery, label)
  local match = self.match
  local senderIndex = tableUtils.indexOf(match.stacks, source)
  local recipientIndices = {}
  for _, target in ipairs(targets) do
    local idx = tableUtils.indexOf(match.stacks, target)
    if idx then recipientIndices[#recipientIndices + 1] = idx end
  end
  if #recipientIndices == 0 then return end

  local pieceCount = garbageDelivery and #garbageDelivery or 0
  logger.info(string.format(
    "%s: stack[%d] -> stack[%d] frame=%d count=%d",
    label or "G emit", senderIndex or -1, recipientIndices[1] or -1,
    source.stopWatch or -1, pieceCount))

  match._gSentEvents = (match._gSentEvents or 0) + 1
  match._gSentPieces = (match._gSentPieces or 0) + pieceCount

  GAME.netClient:sendGarbageEvent({
    senderFrame = source.stopWatch,
    recipients = recipientIndices,
    garbage = garbageDelivery,
  })
end

function GarbageDelivery:_emitGMulti(source, recipientIndices, garbageDelivery)
  local match = self.match
  local senderIndex = tableUtils.indexOf(match.stacks, source)
  local pieceCount = garbageDelivery and #garbageDelivery or 0
  logger.info(string.format(
    "G emit (all): stack[%d] -> [%s] frame=%d count=%d",
    senderIndex or -1, table.concat(recipientIndices, ","),
    source.stopWatch or -1, pieceCount))

  match._gSentEvents = (match._gSentEvents or 0) + 1
  -- Broadcast is ONE wire send, but pieces fan out: bookkeeping counts
  -- pieces × recipients so applied-across-all totals match.
  match._gSentPieces = (match._gSentPieces or 0) + pieceCount * #recipientIndices

  GAME.netClient:sendGarbageEvent({
    senderFrame = source.stopWatch,
    recipients = recipientIndices,
    garbage = garbageDelivery,
  })
end

return GarbageDelivery
