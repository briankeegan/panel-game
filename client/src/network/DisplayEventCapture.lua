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

---@param engine Stack the local player's engine stack
---@param playerID integer wire identifier for the sending player
---@return DisplayEventCapture
function DisplayEventCapture.new(engine, playerID)
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
  return self
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
  local cell = {
    -- color: 0/nil = empty slot, 1-8 = panel color
    c = panel.color,
    -- state: short string (already short in engine; "normal", "swapping",
    -- "popping", "matched", "landing", "hovering", "falling", "dimmed",
    -- "dead", "popped"). Receiver picks sprite by this.
    s = panel.state,
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
  return cell
end

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
  local panels = {}
  local enginePanels = engine.panels
  if enginePanels then
    -- Walk rows 0..height+1 (engine uses row 0 for the buffer below the
    -- play area and row height+1 for the upcoming row above) so all
    -- visible cells are captured. Empty cells stay nil.
    for row = 0, math.min(height + 1, #enginePanels) do
      local enginePanelRow = enginePanels[row]
      if enginePanelRow then
        for col = 1, width do
          local idx = row * width + col
          panels[idx] = snapshotCell(enginePanelRow[col])
        end
      end
    end
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
end

---Stop the capture and send one final snapshot so the receiver sees the
---terminal state (e.g. a game-over board). Idempotent.
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
  -- Track pop size for the upcoming panelPop events this frame (mirrors
  -- PlayerStack.popSizeThisFrame which is set on matched and read by
  -- onPanelPop).
  self._popSizeThisFrame = comboSize or 1
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

-- One-shot trigger: a panel popped. Queue a pop-FX event keyed to the
-- pop size we last saw on matched.
function DisplayEventCapture:onPanelPop(panel)
  if not panel then return end
  self._pendingEvents[#self._pendingEvents + 1] = {
    k = "pop",
    col = panel.column, row = panel.row,
    sz = self._popSizeThisFrame,
  }
end

function DisplayEventCapture:_maybeSend()
  local now = love.timer.getTime()
  if (now - self.lastFlushTime) < SEND_INTERVAL_S then return end
  self:_send(now)
end

function DisplayEventCapture:_send(now)
  self.lastFlushTime = now or love.timer.getTime()
  if not (GAME and GAME.netClient) then return end
  local snapshot = buildSnapshot(self.engine)
  -- Attach any one-shot triggers collected since last send, then clear.
  -- These play once on the receiver — pop FX and score cards.
  if #self._pendingEvents > 0 then
    snapshot.e = self._pendingEvents
    self._pendingEvents = {}
  end
  local batch = { from = self.playerID, snapshot = snapshot }
  local ok, err = pcall(GAME.netClient.sendDisplayEvents, GAME.netClient, batch)
  if not ok then
    logger.warn("[DisplayEventCapture] sendDisplayEvents failed: " .. tostring(err))
  end
end

return DisplayEventCapture
