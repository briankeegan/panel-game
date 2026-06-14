---@class DisplayEventCapture
---
--- Snapshot-based capture for the parallel "Spectator View: New" pipeline
--- (see DISPLAY_HISTORY_PLAN.md). Periodically snapshots the local engine's
--- *current state* (panel grid, displacement, cursor, scalars) and ships
--- the snapshot to other clients via NetClient:sendDisplayEvents.
---
--- Receivers do zero simulation — they store the latest snapshot and paint
--- from it directly. The sender does NO work beyond reading its own engine
--- fields and serializing them.
---
--- Lifecycle:
---   capture = DisplayEventCapture.new(engine, playerID)
---   capture:start()      -- begin periodic snapshots
---   capture:stop()       -- stop and flush
---
--- Wire format (one batch per send):
---   { from = <playerID>, snapshot = { f, d, cr, cc, w, h, p[..], ... } }
--- The shape is small-key for bandwidth; the receiver expands when applying.

local logger = require("common.lib.logger")
local PanelStateCodes = require("client.src.network.PanelStateCodes")

---@class DisplayEventCapture
---@field engine Stack the local player's engine stack being observed
---@field playerID integer wire identifier for the sending player
---@field lastFlushTime number love.timer.getTime() at last successful send
---@field started boolean idempotency flag for start()/stop()
---@field _heartbeatSubscriber table? subscriber object connected to engine.finishedRun for the periodic flush check
local DisplayEventCapture = {}
DisplayEventCapture.__index = DisplayEventCapture

-- Send cadence target: 20Hz (~50ms). The grid only meaningfully changes
-- between ticks when panels move; 20Hz is well below 60Hz engine rate but
-- visually smooth enough for a peer's board. The heartbeat is the engine's
-- `finishedRun` signal (one per tick); _maybeSend gates the actual send
-- on wall-clock elapsed so the rate is independent of tick rate.
local SEND_INTERVAL_S = 0.05

-- Adaptive idle rate (item 6 of smoother-visuals goal): when nothing
-- visually interesting has changed for IDLE_AFTER_S, drop to
-- IDLE_INTERVAL_S until the next fastEvent. The fast-event bypass
-- already snaps us back to 20Hz the moment something happens, so this
-- only kicks in during true visual idle (e.g. stack sitting still
-- post-countdown or mid-stop). Average bandwidth drops; visible motion
-- stays at full rate.
local IDLE_AFTER_S    = 1.0
local IDLE_INTERVAL_S = 0.15

---@param engine Stack the local player's engine stack
---@param playerID integer wire identifier for the sending player
---@param hostStack table? the PlayerStack holding danger_col / danger_timer (only those fields live on PlayerStack, not engine). nil for SimulatedStack.
---@return DisplayEventCapture
function DisplayEventCapture.new(engine, playerID, hostStack, historyList)
  assert(engine, "DisplayEventCapture requires an engine")
  assert(playerID, "DisplayEventCapture requires a playerID")
  local self = setmetatable({}, DisplayEventCapture)
  self.engine        = engine
  self.playerID      = playerID
  self.lastFlushTime = 0
  self.started       = false
  -- One-shot trigger queue: pop FX + score-card events that fire as
  -- things happen and play once on the receiver. Appended by signal
  -- handlers, drained into each snapshot.
  self._pendingEvents     = {}
  self._popSizeThisFrame  = 1
  -- Optional list to accumulate every batch for replay recording.
  -- When set, each batch built in _send is appended here in addition
  -- to being sent over the network.
  self._historyList = historyList
  -- Park the PlayerStack on the engine as _renderHost so buildSnapshot
  -- can pull PlayerStack-resident render fields (danger_col,
  -- danger_timer) without passing extra args through every layer.
  -- Engine never reads _renderHost; it's purely render-side data
  -- riding on the engine reference for convenience.
  if hostStack then
    engine._renderHost = hostStack
  end
  return self
end

---Per-frame heartbeat driven from BattleRoom:update. Independent of
---engine.finishedRun, which stops firing once the player dies
---(Stack:shouldRun returns false on game_ended). Without this, the
---death-state panel transitions set by PlayerStack:applyVisualDeath
---never reach the wire.
function DisplayEventCapture:tick()
  if not self.started then return end
  self:_maybeSend()
end

----------------------------------------------------------------------
-- Snapshot construction
----------------------------------------------------------------------

-- Compact a Panel object to the minimum needed to draw it. Skipping fields
-- the renderer doesn't read keeps the wire payload small (the grid is the
-- dominant cost). Nil-out empty / default values to compress further when
-- JSON-encoded (json.encode skips nil entries).
---@param panel Panel?
---@return table? cell nil when panel is nil; otherwise a compact wire-cell
local function snapshotCell(panel)
  if not panel then return nil end
  -- state travels as a compact numeric code (see PanelStateCodes).
  local stateCode = PanelStateCodes.toCode(panel.state)
  local cell = {
    -- color: 0/nil = empty slot, 1-8 = panel color
    c = panel.color,
    -- state: numeric code for FFI packing
    s = stateCode,
  }
  -- Timers / flags only if non-default so JSON stays small.
  if panel.timer       and panel.timer ~= 0       then cell.t  = panel.timer end
  if panel.isGarbage                              then cell.g  = true end
  if panel.metal                                  then cell.m  = true end
  if panel.chaining                               then cell.ch = true end
  if panel.garbageId                              then cell.gi = panel.garbageId end
  -- Garbage block geometry: needed to render multi-cell garbage as a
  -- single block (only the bottom-right corner of the block triggers
  -- the actual sprite draw — see PlayerStack:drawPanels). Ship per
  -- garbage cell; receiver reuses the existing drawGarbage helper.
  if panel.x_offset    ~= nil                     then cell.xo = panel.x_offset end
  if panel.y_offset    ~= nil                     then cell.yo = panel.y_offset end
  if panel.width       ~= nil                     then cell.gw = panel.width end
  if panel.height      ~= nil                     then cell.gh = panel.height end
  if panel.pop_time    ~= nil                     then cell.pt = panel.pop_time end
  if panel.initial_time~= nil                     then cell.it = panel.initial_time end
  if panel.combo_size  ~= nil                     then cell.cs = panel.combo_size end
  if panel.combo_index ~= nil                     then cell.ci = panel.combo_index end
  if panel.isSwappingFromLeft                     then cell.sl = true end
  -- fell_from_garbage: timer value (or true) that the renderer uses to
  -- animate the garbage-pop bounce on hovering/falling panels. Without
  -- this, panels emerging from a popped garbage block fall as if they
  -- were plain panels — no bounce.
  if panel.fell_from_garbage                      then cell.fg = panel.fell_from_garbage end
  -- senderId: stack index of the player who sent this garbage. The renderer
  -- needs it to pick the correct character art (face/flash/composition)
  -- per-block. Without it the spec falls back to local match-setup state
  -- which can diverge from the sender's choice → different sprite art only
  -- during the matched/break window.
  if panel.senderId                               then cell.sid = panel.senderId end
  return cell
end

-- Cell equality covering every shipped field. Used by buildSnapshot to
-- mark cells as unchanged (sentinel `true`) when they match the last
-- shipped state — bandwidth saver.
local function cellsEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.c  == b.c  and a.s  == b.s  and a.t  == b.t
     and a.g  == b.g  and a.m  == b.m  and a.ch == b.ch
     and a.gi == b.gi and a.xo == b.xo and a.yo == b.yo
     and a.gw == b.gw and a.gh == b.gh and a.pt == b.pt
     and a.it == b.it and a.cs == b.cs and a.ci == b.ci
     and a.sl == b.sl and a.fg == b.fg and a.sid == b.sid
end

-- Keyframe interval. Every Nth send goes out as a full grid (no deltas)
-- so receivers that lost a packet, joined late, or got a stale cached
-- value can recover.
local KEYFRAME_EVERY = 100

-- Build a wire-ready snapshot of the engine's current state. Pure read —
-- never mutates the engine.
---@param engine Stack
---@return table snapshot
local function buildSnapshot(engine)
  local width  = engine.width  or 6
  local height = engine.height or 12

  -- Grid is a flat list indexed by (row-1)*width + (col-1), 1-based.
  -- Why flat: nested tables JSON-encode with more punctuation; flat keeps
  -- the wire compact. Receiver re-indexes by the same formula.
  --
  -- Iterate by explicit bound (height+1), NOT by #enginePanels. Lua's #
  -- operator on a table with any nil row can short-circuit before the
  -- top — that's how the dead-player's top rows were going missing on
  -- the receiver. The per-row `if enginePanelRow` guard handles legit
  -- nil rows gracefully.
  -- Pad EVERY cell index with at least `false` so the table stays dense
  -- 1..(height+2)*width. dkjson encodes sparse Lua tables as JSON OBJECTS
  -- with STRING keys, which breaks the receiver's numeric `grid[idx]`
  -- lookup — panels show up at the wrong rows or vanish entirely. The
  -- false sentinel decodes as boolean false; expandCell treats it as
  -- empty (`not cell` short-circuits → nil panel → skipped).
  local panels = {}
  local enginePanels = engine.panels
  for row = 0, height + 1 do
    local enginePanelRow = enginePanels and enginePanels[row]
    for col = 1, width do
      local idx = row * width + col
      panels[idx] = (enginePanelRow and snapshotCell(enginePanelRow[col])) or false
    end
  end

  -- danger_col + danger_timer live on the PlayerStack, NOT the engine,
  -- but the receiver needs them so the renderer can play the column-
  -- bounce animation on columns that reached the danger zone. Pull them
  -- via the PlayerStack reference attached at capture-creation time.
  -- Without these, every panel renders with empty dangerCol → static.
  local dangerCol, dangerTimer = nil, 0
  local hostStack = engine._renderHost
  if hostStack and hostStack.danger_col then
    dangerCol   = hostStack.danger_col
    dangerTimer = hostStack.danger_timer or 0
  end

  -- Analytics: the receiver's remote engine is paused (pauseNonLocalSimulation)
  -- so its analytic never ticks. Ship the local stack's counts; the receiver
  -- mirrors them onto its remote PlayerStack and recomputes APM/GPM from clock.
  local an = nil
  if hostStack and hostStack.analytic and hostStack.analytic.data then
    local d = hostStack.analytic.data
    an = {
      dp = d.destroyed_panels   or 0,
      sg = d.sent_garbage_lines or 0,
      mv = d.move_count         or 0,
      sw = d.swap_count         or 0,
      rc = d.reached_chains     or {},
      uc = d.used_combos        or {},
    }
  end

  return {
    f  = engine.clock                      or 0,
    d  = engine.displacement               or 0,
    cr = engine.cur_row                    or 1,
    cc = engine.cur_col                    or 1,
    w  = width,
    h  = height,
    sh = engine.shake_time                 or 0,
    psh= engine.prev_shake_time            or 0,
    pkh= engine.peak_shake_time            or 0,
    dc = dangerCol,
    dt = dangerTimer,
    ic = engine.in_countdown and true or false,
    ct = engine.countdown_timer            or 0,
    go = engine.game_over_clock            or 0,
    im = engine.inputMethod                or "controller",
    cn = engine.chain_counter              or 0,
    -- HUD scalars: read on the receiver and mirrored onto the engine
    -- field so the existing drawScore / drawSpeed / drawLevel /
    -- drawMultibar / drawAnalyticData code paths work unchanged.
    sc = engine.score                      or 0,
    sp = engine.speed                      or 0,
    -- engine.level not used (level lives on PlayerStack, set from player
    -- settings at match start and present on both sides — no need to ship)
    pc = engine.panels_cleared             or 0,
    mp = engine.metalPanelsQueued          or 0,
    hp = engine.health                     or 0,
    st = engine.stop_time                  or 0,
    ps = engine.pre_stop_time              or 0,
    sw = engine.swapCount                  or 0,
    rl = engine.rise_lock and true or false,
    -- Telegraph: outgoing garbage queue (the pieces in transit toward
    -- targets). Shipping just the staged list — what Telegraph:render
    -- reads. Each entry carries the minimum fields the renderer + icon
    -- lookup need (height/width/isChain/isMetal/frameEarned/rowEarned/
    -- colEarned/links). Empty when nothing in transit.
    og = (function()
      local out = {}
      local q = engine.outgoingGarbage and engine.outgoingGarbage.stagedGarbage
      if not q then return out end
      for i, g in ipairs(q) do
        ---@diagnostic disable: undefined-field
        out[i] = {
          height       = g.height,
          width        = g.width,
          isChain      = g.isChain,
          isMetal      = g.isMetal,
          frameEarned  = g.frameEarned,
          rowEarned    = g.rowEarned,
          colEarned    = g.colEarned,
          links        = g.links,  -- table<frame,location>; only set on chains
        }
        ---@diagnostic enable: undefined-field
      end
      return out
    end)(),
    an = an,
    p  = panels,
  }
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

---Begin shipping periodic snapshots. Subscribes to engine's finishedRun
---signal as the heartbeat — once per engine tick we check wall-clock and
---send if the interval has elapsed. Idempotent.
function DisplayEventCapture:start()
  if self.started then return end
  self.started       = true
  self.lastFlushTime = love.timer.getTime()
  -- finishedRun fires once per engine tick (≤60Hz); _maybeSend rate-limits
  -- via wall-clock so we send at ~20Hz regardless.
  self.engine:connectSignal("finishedRun", self, self.onFinishedRun)
  -- One-shot triggers for pop FX + score cards. Mirrors what
  -- PlayerStack's onEngineMatched / onPanelPop normally drive locally,
  -- ferried over the wire so the new viewer plays the same animations.
  self.engine:connectSignal("matched",     self, self.onMatched)
  self.engine:connectSignal("panelPop",    self, self.onPanelPop)
  -- Track recent landings so _maybeSend can bump rate while the bounce
  -- animation plays out (~8 ticks). Without this the 20Hz default
  -- undersamples the bounce and the receiver sees panels snap to rest
  -- with no visible bounce.
  self.engine:connectSignal("panelLanded", self, self.onPanelLanded)
  -- Initial snapshot so receivers paint the board on frame 0 rather than
  -- waiting one full SEND_INTERVAL_S window. Without this the remote board
  -- is blank for ~50ms after every match start.
  self:_send()
end

---Stop the capture and ship one final snapshot so the receiver sees the
---terminal state (cracked face, dimmed panels). Idempotent.
---
---The final send used to race the next match's startMatch on the receiver
---— a stale terminal snapshot could arrive after the receiver rebuilt its
---DisplayClientStacks and briefly paint the dead board over the fresh
---match. The receiver now drains pending Y messages at startMatch
---(NetClient:flushDisplayEvents) and detects match-boundary transitions in
---applyBatch (big clock regression or dead→alive flip → drop stale prev).
function DisplayEventCapture:stop()
  if not self.started then return end
  self.started = false
  local Signal = require("common.lib.signal")
  Signal.disconnectSubscriber(self.engine, self)
  self:_send()
end

----------------------------------------------------------------------
-- Internal: send gating
----------------------------------------------------------------------

function DisplayEventCapture:onFinishedRun()
  self:_maybeSend()
end

-- One-shot trigger: a panel match just resolved. Queue a score-card
-- event so the receiver's PlayerStack:enqueue_card replays it.
function DisplayEventCapture:onMatched(engine, attackGfxOrigin, isChainLink, comboSize, metalCount, garbagePanelCount)
  self._popSizeThisFrame = comboSize or 1
  -- Match → flash → face → popping → hover → fall → land covers ~80
  -- ticks. Bump send rate for the full window so the receiver gets
  -- enough frames to render smooth pop + drop sequences instead of the
  -- 20Hz snap-cuts.
  local engineClock = self.engine and self.engine.clock or 0
  local target = engineClock + 90
  if (self._matchActiveUntilClock or 0) < target then
    self._matchActiveUntilClock = target
  end
  if not attackGfxOrigin then return end
  -- Card kind matches the existing enqueue_card pairs in PlayerStack:
  -- non-chain combo card + (optionally) chain card.
  if comboSize and comboSize > 3 then
    self._pendingEvents[#self._pendingEvents + 1] = {
      k = "card", chain = false,
      col = attackGfxOrigin.column, row = attackGfxOrigin.row,
      n = comboSize,
    }
  end
  if isChainLink then
    self._pendingEvents[#self._pendingEvents + 1] = {
      k = "card", chain = true,
      col = attackGfxOrigin.column,
      row = (comboSize and comboSize > 3) and (attackGfxOrigin.row + 1) or attackGfxOrigin.row,
      n = engine.chain_counter or 1,
    }
  end
end

function DisplayEventCapture:onPanelPop(panel)
  if not panel then return end
  self._pendingEvents[#self._pendingEvents + 1] = {
    k = "pop",
    col = panel.column, row = panel.row,
    sz = self._popSizeThisFrame,
    pl = math.min(math.max(self.engine.chain_counter or 1, 1), 4),
    pi = panel.combo_index or 1,
    gi = panel.isGarbage and (panel.pop_index or 0) or nil,
  }
end

-- A panel just landed. Record an active-until clock so _maybeSend bypasses
-- the 20Hz gate for the FULL landing duration. Panel.lua sets panel.timer
-- to 12 on land; the bounce animation is exactly 12 ticks of timer
-- countdown. Bump by 13 to cover that span plus a safety frame. Multiple
-- lands in quick succession extend the bump (max), not reset, so a stack
-- of landings stays smooth.
function DisplayEventCapture:onPanelLanded(panel)
  local engineClock = self.engine and self.engine.clock or 0
  local target = engineClock + 13
  if (self._landingActiveUntilClock or 0) < target then
    self._landingActiveUntilClock = target
  end
  -- Garbage land "thud": ship a one-shot event so the receiver can play
  -- the same garbage_thud SFX the sender's PlayerStack would. Dedup by
  -- garbageId so multi-cell blocks only emit once per land.
  if panel and panel.isGarbage and panel.shake_time and panel.garbageId
      and (panel.row or 0) <= (self.engine.height or 12) then
    self._landedGarbageIds = self._landedGarbageIds or {}
    if not self._landedGarbageIds[panel.garbageId] then
      self._landedGarbageIds[panel.garbageId] = true
      self._pendingEvents[#self._pendingEvents + 1] = {
        k = "gland",
        h = panel.height or 1,
      }
    end
  end
end

function DisplayEventCapture:_maybeSend()
  local now = love.timer.getTime()
  -- Fast-events bypass: ship every tick when something visually fast is
  -- happening that 20Hz undersamples. Three triggers:
  --   * manual raise in progress (player holding raise button)
  --   * within the panel-landing bounce window (~12 ticks)
  --   * displacement just changed (any raise — passive or manual — or the
  --     mod-16 wrap when a new row spawns)
  local engineClock = self.engine.clock or 0
  local curDisplacement = self.engine.displacement or 0
  local curR = self.engine.cur_row or 0
  local curC = self.engine.cur_col or 0
  local displacementChanged = (self._lastSentDisplacement ~= nil)
    and (self._lastSentDisplacement ~= curDisplacement)
  local cursorChanged = (self._lastSentCurR ~= nil)
    and (self._lastSentCurR ~= curR or self._lastSentCurC ~= curC)
  local fastEvent = (self.engine.manual_raise == true)
    or ((self._landingActiveUntilClock or 0) > engineClock)
    or ((self._matchActiveUntilClock or 0) > engineClock)
    or displacementChanged
    or cursorChanged
  -- Track wall-clock of the most recent fast event so the idle detector
  -- below knows when to slow down. Anything that's a fastEvent counts as
  -- "active" — same definition both sides should agree on.
  if fastEvent then self._lastFastEventAt = now end
  -- Adaptive interval: stretch to IDLE_INTERVAL_S once we've been quiet
  -- past IDLE_AFTER_S since the last fastEvent. Any fastEvent on the
  -- next tick still bypasses gating entirely, so wake-up latency is one
  -- engine tick.
  local interval = SEND_INTERVAL_S
  if (now - (self._lastFastEventAt or 0)) > IDLE_AFTER_S then
    interval = IDLE_INTERVAL_S
  end
  if not fastEvent and (now - self.lastFlushTime) < interval then return end
  -- Option F (adaptive rate): if the local engine is behind wall-clock
  -- by 2+ frames, skip this send. The local player's main loop is
  -- already racing to catch up; piling JSON-encode work on top makes it
  -- worse. The next attempt fires after a wall-clock pass and reads the
  -- deficit again. Effect: snapshots pause during render hitches; resume
  -- naturally once the main loop is healthy. Worst case the receiver
  -- sees a slightly older board for a few frames.
  --
  -- Deficit lives on the Match (top-level engine), not the per-Stack
  -- engine we observe. Read via GAME.battleRoom.match.engine when
  -- available.
  local matchEngine = GAME and GAME.battleRoom
    and GAME.battleRoom.match
    and GAME.battleRoom.match.engine
  if matchEngine and (matchEngine._wallClockDeficitFrames or 0) >= 2 then
    return
  end
  self:_send(now)
end

-- Cheap signature of an engine state — captures the scalars that change
-- when ANYTHING visible has happened. If two consecutive ticks produce
-- the same signature, the snapshot would be identical and we can skip
-- the JSON encode entirely. False negatives are fine (we send more
-- often than strictly needed); false positives would mean a missed
-- update, so the signature must change when ANY relevant state changes.
--
-- engine.clock changes every tick the engine runs, so under normal play
-- this signature changes constantly. It only stops changing when the
-- engine ITSELF stops ticking — countdown frozen, pause, post-death.
-- Exactly the "send is wasted" scenarios.
local function stateSignature(engine)
  return (engine.clock or 0) * 1000000
       + (engine.cur_row or 0) * 100
       + (engine.cur_col or 0)
end

-- Rolling hash of panel state across the grid. Picks up applyVisualDeath
-- state flips and any other panel-state transition that happens when
-- engine.clock has frozen (post-death). Cost: one pass over ~84 cells.
local function panelsSignature(engine)
  if not engine.panels then return 0 end
  local h = 0
  local height = engine.height or 12
  local width  = engine.width  or 6
  for row = 0, height + 1 do
    local r = engine.panels[row]
    if r then
      for col = 1, width do
        local p = r[col]
        if p then
          local stateLen = p.state and #p.state or 0
          h = (h * 31 + (p.color or 0) * 17 + stateLen * 7 + (p.timer or 0)) % 16777216
        end
      end
    end
  end
  return h
end

-- Diagnostic snapshot for the throttled telemetry line. Counts panels
-- by state so logs reveal whether dead/landing/matched are actually
-- shipping. Iterates the same grid buildSnapshot does — kept tiny.
local function _diagPanelStats(engine)
  local height = engine.height or 12
  local width  = engine.width  or 6
  local stateCount = {}
  local total = 0
  if engine.panels then
    for row = 0, height + 1 do
      local r = engine.panels[row]
      if r then
        for col = 1, width do
          local p = r[col]
          if p and p.color and p.color ~= 0 then
            total = total + 1
            local s = p.state or "?"
            stateCount[s] = (stateCount[s] or 0) + 1
          end
        end
      end
    end
  end
  -- Compact "state=N,state=N" form, sorted for stability.
  local keys = {}
  for k in pairs(stateCount) do keys[#keys+1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts+1] = k .. "=" .. stateCount[k] end
  return total, table.concat(parts, ",")
end

local function _diagDangerCols(hostStack)
  if not hostStack or not hostStack.danger_col then return "{}" end
  local cols = {}
  for i = 1, #hostStack.danger_col do
    if hostStack.danger_col[i] then cols[#cols+1] = tostring(i) end
  end
  return "{" .. table.concat(cols, ",") .. "}"
end

function DisplayEventCapture:_send(now)
  self.lastFlushTime = now or love.timer.getTime()

  -- Skip-when-unchanged: bail before the expensive serialize if NOTHING
  -- shippable has changed since the last send. Catches:
  --   * Engine clock advancing (normal play) — sig differs
  --   * Panel state flipping while clock frozen (post-death
  --     applyVisualDeath) — panelsSig differs
  --   * One-shot events pending — _pendingEvents non-empty
  -- All three quiet → no info to ship → skip.
  local sig       = stateSignature(self.engine)
  local panelsSig = panelsSignature(self.engine)
  if sig == self._lastSentSig
      and panelsSig == self._lastSentPanelsSig
      and #self._pendingEvents == 0 then
    return
  end
  self._lastSentSig = sig
  self._lastSentPanelsSig = panelsSig
  -- Remember displacement + cursor position so the next _maybeSend can
  -- bypass the 20Hz gate on the very next change.
  self._lastSentDisplacement = self.engine.displacement or 0
  self._lastSentCurR = self.engine.cur_row or 0
  self._lastSentCurC = self.engine.cur_col or 0

  local snapshot = buildSnapshot(self.engine)

  -- Delta encoding for the panel grid. Most cells stay unchanged frame-
  -- to-frame; ship `true` as the unchanged sentinel and the full table
  -- only where the cell differs. Receiver merges deltas onto its cached
  -- grid. Periodic keyframes (every KEYFRAME_EVERY sends) ship the full
  -- grid so receivers can recover from packet loss or stale state.
  self._sendCount = (self._sendCount or 0) + 1
  local isKeyframe = (self._sendCount == 1)
      or (self._sendCount % KEYFRAME_EVERY == 0)
  local fullP = snapshot.p
  if fullP then
    -- Snapshot original cell refs BEFORE mutation so the next send's
    -- comparison sees the actual shipped values.
    local newCache = {}
    for i = 1, #fullP do newCache[i] = fullP[i] end
    if not isKeyframe and self._lastShippedPanels then
      local last = self._lastShippedPanels
      for i = 1, #fullP do
        if cellsEqual(fullP[i], last[i]) then
          snapshot.p[i] = true
        end
      end
    end
    self._lastShippedPanels = newCache
  end

  -- Attach any one-shot triggers collected since last send, then clear.
  -- These play once on the receiver — pop FX and score cards.
  if #self._pendingEvents > 0 then
    snapshot.e = self._pendingEvents
    self._pendingEvents = {}
  end
  -- Record this batch for replay playback (same delta-encoded form that
  -- goes over the wire, so the playback path is identical to live receive).
  if self._historyList then
    self._historyList[#self._historyList + 1] = { from = self.playerID, snapshot = snapshot }
  end
  -- The recording above happens regardless (offline solo still saves the data
  -- replay). Only the live wire send needs a client; sendDisplayEvents picks
  -- FFI vs JSON internally.
  if GAME and GAME.netClient then
    local ok, err = pcall(GAME.netClient.sendDisplayEvents, GAME.netClient, { from = self.playerID, snapshot = snapshot })
    if not ok then
      logger.warn("[DisplayEventCapture] sendDisplayEvents failed: " .. tostring(err))
    end
  end

  -- Removed noisy [SPECTATE-SEND] telemetry log per request.
end

return DisplayEventCapture
