---@class DisplayEventCapture
---
--- Phase A of the display-history replication plan
--- (see DISPLAY_HISTORY_PLAN.md). Pure observer of a local player's
--- engine signals. Builds frame-stamped event records and batches them
--- out via NetClient:sendDisplayEvents.
---
--- Does NOT modify any engine state, does NOT change any existing send
--- path. Old input-replication system remains the authoritative path
--- for remote view-stacks; this module's events are an independent
--- parallel stream that the receiver may or may not render.
---
--- Lifecycle:
---   capture = DisplayEventCapture.new(engine, playerID)
---   capture:start()      -- subscribe to engine signals; begin buffering
---   capture:stop()       -- disconnect from engine; flush remaining buffer
---
--- Wire format (per batch, JSON):
---   { from = <playerID>, events = [ { f, t, ... }, ... ] }
--- where each event has a frame stamp `f`, a 1-char type tag `t`,
--- and type-specific fields.

local logger = require("common.lib.logger")
local Signal = require("common.lib.signal")

---@class DisplayEventCapture
local DisplayEventCapture = {}
DisplayEventCapture.__index = DisplayEventCapture

-- Flush cadence target. 50ms ≈ 20 batches/sec. Receivers buffer ~100ms
-- so a flush rate of 20Hz keeps display latency bounded without spamming
-- the gameplay socket. Flush trigger is the engine's `finishedRun` signal
-- (one per engine tick), so the real check fires at engine-tick rate
-- (≤60Hz) and the flush actually fires when wall-clock crosses the
-- threshold.
local FLUSH_INTERVAL_S = 0.05

---@param engine Stack the local player's engine stack
---@param playerID integer wire identifier for the sending player
---@return DisplayEventCapture
function DisplayEventCapture.new(engine, playerID)
  assert(engine, "DisplayEventCapture requires an engine")
  assert(playerID, "DisplayEventCapture requires a playerID")
  local self = setmetatable({}, DisplayEventCapture)
  self.engine        = engine
  self.playerID      = playerID
  self.events        = {}
  self.lastFlushTime = 0
  self.started       = false
  return self
end

---Subscribe to the local engine's signals. Idempotent — calling start()
---twice is a no-op (second call returns without re-subscribing).
function DisplayEventCapture:start()
  if self.started then return end
  self.started       = true
  self.lastFlushTime = love.timer.getTime()

  local engine = self.engine
  engine:connectSignal("cursorMoved",   self, self.onCursorMoved)
  engine:connectSignal("panelsSwapped", self, self.onPanelsSwapped)
  engine:connectSignal("panelLanded",   self, self.onPanelLanded)
  engine:connectSignal("panelPop",      self, self.onPanelPop)
  engine:connectSignal("matched",       self, self.onMatched)
  engine:connectSignal("newRow",        self, self.onNewRow)
  engine:connectSignal("gameOver",      self, self.onGameOver)
  -- finishedRun fires once per engine tick. We use it as the flush
  -- heartbeat — the wall-clock interval check inside _maybeFlush keeps
  -- the actual send rate at ~20Hz even though the heartbeat is 60Hz.
  engine:connectSignal("finishedRun",   self, self.onFinishedRun)
end

---Disconnect from the engine. Flushes any remaining buffered events.
function DisplayEventCapture:stop()
  if not self.started then return end
  self.started = false
  -- Disconnect first to avoid any stray events landing during flush.
  Signal.disconnectSubscriber(self.engine, self)
  self:_flush()
end

----------------------------------------------------------------------
-- Internal: event capture + buffering
----------------------------------------------------------------------

function DisplayEventCapture:_pushEvent(ev)
  -- Frame stamp is captured at emit-time so the receiver can replay at
  -- the same in-engine timing as the sender.
  ev.f = self.engine.clock
  self.events[#self.events + 1] = ev
end

function DisplayEventCapture:_maybeFlush()
  local now = love.timer.getTime()
  if (now - self.lastFlushTime) < FLUSH_INTERVAL_S then return end
  self:_flush(now)
end

function DisplayEventCapture:_flush(now)
  if #self.events == 0 then
    self.lastFlushTime = now or love.timer.getTime()
    return
  end
  local batch = { from = self.playerID, events = self.events }
  self.events = {}
  self.lastFlushTime = now or love.timer.getTime()
  -- Guarded so a NetClient hiccup or missing connection doesn't break
  -- the engine pipeline. Display events are non-critical by design.
  if not (GAME and GAME.netClient) then return end
  local ok, err = pcall(GAME.netClient.sendDisplayEvents, GAME.netClient, batch)
  if not ok then
    logger.warn("[DisplayEventCapture] sendDisplayEvents failed: " .. tostring(err))
  end
end

----------------------------------------------------------------------
-- Signal handlers. Each is a *pure observer* — it inspects signal args
-- and the engine's current state and produces an event record. None
-- mutates the engine or any external state outside this capture's own
-- buffer.
----------------------------------------------------------------------

---@param previousRow integer
---@param previousCol integer
function DisplayEventCapture:onCursorMoved(previousRow, previousCol)
  -- Only emit when the cursor actually moved. Skips the "synthetic" calls
  -- from controls() that fire on every press even if direction blocked.
  if self.engine.cur_row == previousRow and self.engine.cur_col == previousCol then
    return
  end
  self:_pushEvent({ t = "C", r = self.engine.cur_row, c = self.engine.cur_col })
end

function DisplayEventCapture:onPanelsSwapped()
  self:_pushEvent({ t = "S", r = self.engine.cur_row, c = self.engine.cur_col })
end

---@param panel Panel
function DisplayEventCapture:onPanelLanded(panel)
  self:_pushEvent({ t = "L", r = panel.row, c = panel.column })
end

---@param panel Panel
function DisplayEventCapture:onPanelPop(panel)
  self:_pushEvent({ t = "P", r = panel.row, c = panel.column, color = panel.color })
end

---@param engine Stack
---@param attackGfxOrigin any
---@param isChainLink boolean
---@param comboSize integer
---@param metalCount integer
---@param garbagePanelCount integer
function DisplayEventCapture:onMatched(engine, attackGfxOrigin, isChainLink, comboSize, metalCount, garbagePanelCount)
  self:_pushEvent({
    t        = "M",
    combo    = comboSize,
    chain    = isChainLink and true or false,
    metal    = metalCount,
    garbage  = garbagePanelCount,
  })
end

---@param engine Stack
function DisplayEventCapture:onNewRow(engine)
  -- Capture the bottom-row state so the receiver can mirror what just
  -- appeared. Sending color IDs only (not full panel state) is enough
  -- for display.
  local row = engine.panels and engine.panels[1]
  if not row then return end
  local colors = {}
  for col = 1, #row do
    local p = row[col]
    colors[col] = p and p.color or 0
  end
  self:_pushEvent({ t = "R", colors = colors })
end

---@param engine Stack
function DisplayEventCapture:onGameOver(engine)
  self:_pushEvent({ t = "D" })
  -- Force-flush on gameOver so the receiver sees the death right away
  -- rather than waiting up to FLUSH_INTERVAL_S for the next heartbeat.
  self:_flush()
end

function DisplayEventCapture:onFinishedRun()
  self:_maybeFlush()
end

return DisplayEventCapture
