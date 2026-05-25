---@class DisplayClientStack
---
--- Snapshot-based receiver for the parallel "Spectator View: New"
--- pipeline (see DISPLAY_HISTORY_PLAN.md). Holds the latest snapshot
--- shipped by a remote player's DisplayEventCapture; does NO simulation.
---
--- The receiver path is intentionally trivial:
---   applyBatch({from, snapshot}) → just stores the snapshot
---   render(viewStack)            → paints from the stored snapshot
---
--- No engine, no physics, no rollback, no event log. The snapshot IS the
--- state; we draw whatever the sender most recently said its board looks
--- like.

local logger = require("common.lib.logger")

---@class DisplayClientStackSnapshot
---@field f integer engine clock at snapshot time
---@field d integer displacement (0-15) smooth scroll offset
---@field cr integer cursor row
---@field cc integer cursor col
---@field w integer board width in panels
---@field h integer board height in panels
---@field sh integer shake_time
---@field psh integer prev_shake_time
---@field pkh integer peak_shake_time
---@field ic boolean in_countdown
---@field ct integer countdown_timer
---@field go integer game_over_clock (0 if alive)
---@field im string inputMethod ("controller" | "touch")
---@field cn integer chain_counter
---@field sc integer score
---@field sp integer speed
---@field lv integer level
---@field pc integer panels_cleared
---@field mp integer metalPanelsQueued
---@field hp integer health
---@field st integer stop_time
---@field ps integer pre_stop_time
---@field sw integer swap count
---@field rl boolean rise_lock
---@field og table outgoing garbage queue (staged)
---@field e table? one-shot trigger events (pop FX + score cards)
---@field p table flat panels array, indexed (row-1)*width + col; empty slots = nil
---@field dc boolean[]? per-column danger flags (sparse), nil when no columns are in danger
---@field dt integer? danger timer (frames since dc went non-empty)

---@class DisplayClientStack
---@field playerID integer wire identifier of the remote player
---@field player Player? optional reference to the local Player object (for name / layout)
---@field viewStack table? matching ClientStack (for engine field mirroring + render layout)
---@field snapshot DisplayClientStackSnapshot? most recent snapshot received, nil until the first arrives
---@field prevSnapshot DisplayClientStackSnapshot? snapshot before `snapshot`, kept for interpolation
---@field snapshotsApplied integer running count of snapshots applied (diagnostic)
---@field latestRecvTime number love.timer.getTime() at last snapshot arrival
---@field prevRecvTime number love.timer.getTime() at prior snapshot arrival
local DisplayClientStack = {}
DisplayClientStack.__index = DisplayClientStack

-- Snapshot interval target. Sender ships at ~20Hz (50ms). Used as the
-- fallback denominator when interpolating before the second snapshot
-- arrives (avoids div-by-zero on the first frame after .new).
local EXPECTED_INTERVAL_S = 0.05

---@param playerID integer
---@param player Player?
---@param viewStack table? matching ClientStack for the remote player (engine field mirror target)
-- Seed the receiver with the deterministic initial board so the remote
-- view isn't blank during countdown before the first snapshot lands.
-- Both clients ran the engine's starting_state() against the shared
-- panelSource seed, so viewStack.engine.panels has the initial 6-row
-- layout populated locally — we just snapshot it here.
local function _initialSnapshotFromEngine(viewStack)
  if not viewStack or not viewStack.engine then return nil end
  local engine = viewStack.engine
  local width  = engine.width  or 6
  local height = engine.height or 12
  local panels = {}
  for row = 0, height + 1 do
    local r = engine.panels and engine.panels[row]
    for col = 1, width do
      local idx = row * width + col
      local p = r and r[col]
      if p and p.color and p.color ~= 0 then
        panels[idx] = {
          c  = p.color,
          s  = p.state,
          t  = (p.timer and p.timer ~= 0) and p.timer or nil,
          g  = p.isGarbage or nil,
          m  = p.metal or nil,
          ch = p.chaining or nil,
          gi = p.garbageId,
          xo = p.x_offset,
          yo = p.y_offset,
          gw = p.width,
          gh = p.height,
        }
      else
        panels[idx] = false
      end
    end
  end
  return {
    f  = engine.clock or 0,
    d  = engine.displacement or 0,
    cr = engine.cur_row or 1,
    cc = engine.cur_col or 1,
    w  = width,
    h  = height,
    p  = panels,
    go = 0,
  }
end

---@return DisplayClientStack
function DisplayClientStack.new(playerID, player, viewStack)
  local self = setmetatable({}, DisplayClientStack)
  self.playerID         = playerID
  self.player           = player
  self.viewStack        = viewStack
  self.snapshot         = _initialSnapshotFromEngine(viewStack)
  self.prevSnapshot     = nil
  self.snapshotsApplied = 0
  self.latestRecvTime   = self.snapshot and love.timer.getTime() or 0
  self.prevRecvTime     = 0
  if self.snapshot and self.snapshot.p then
    local cache = {}
    for i = 1, #self.snapshot.p do cache[i] = self.snapshot.p[i] end
    self._cachedPanels = cache
  end
  return self
end

-- Mirror HUD scalars from the snapshot onto the engine fields the existing
-- drawScore / drawSpeed / drawLevel / drawMultibar / drawAnalyticData
-- methods read from. The engine isn't simulating for this stack (Match:
-- shouldRun returns false when displayHistoryActive is on), so writing
-- these fields is safe — nothing else is going to overwrite them.
--
-- engine.clock IS mirrored (Telegraph attack animation reads it). The
-- corresponding contamination of Match:updateClock is handled by an
-- explicit guard in Match.lua that skips non-local stacks when
-- displayHistoryActive is true.
--
-- engine.game_over_clock is NOT mirrored — the existing D-event path
-- already owns it. If we mirrored snapshot.go, a stale snapshot with
-- go=0 could "resurrect" a dead stack for hasEnded purposes, blocking
-- the match-end logic.
local function mirrorHudScalars(self, snapshot)
  local viewStack = self.viewStack
  if not viewStack or not viewStack.engine then return end
  local engine = viewStack.engine
  if snapshot.sc ~= nil then engine.score             = snapshot.sc end
  if snapshot.sp ~= nil then engine.speed             = snapshot.sp end
  if snapshot.lv ~= nil then engine.level             = snapshot.lv end
  if snapshot.pc ~= nil then engine.panels_cleared    = snapshot.pc end
  if snapshot.mp ~= nil then engine.metalPanelsQueued = snapshot.mp end
  if snapshot.hp ~= nil then engine.health            = snapshot.hp end
  if snapshot.st ~= nil then engine.stop_time         = snapshot.st end
  if snapshot.ps ~= nil then engine.pre_stop_time     = snapshot.ps end
  if snapshot.cn ~= nil then engine.chain_counter     = snapshot.cn end
  if snapshot.sw ~= nil then engine.swapCount         = snapshot.sw end
  if snapshot.sh ~= nil then engine.shake_time        = snapshot.sh end
  if snapshot.psh~= nil then engine.prev_shake_time   = snapshot.psh end
  if snapshot.pkh~= nil then engine.peak_shake_time   = snapshot.pkh end
  if snapshot.og ~= nil and engine.outgoingGarbage then
    engine.outgoingGarbage.stagedGarbage = snapshot.og
  end
  if snapshot.f  ~= nil then engine.clock             = snapshot.f end
end

---Apply an inbound batch. The batch is the JSON-decoded `Y` payload —
---{ from = playerID, snapshot = {...} }. We just store the snapshot;
---no per-field event handling.
---@param batch table
function DisplayClientStack:applyBatch(batch)
  if type(batch) ~= "table" then return end
  local snapshot = batch.snapshot
  if type(snapshot) ~= "table" then return end
  -- Match-boundary detection. A stale tail snapshot from the previous
  -- match can arrive after our DisplayClientStack has been rebuilt for
  -- the new match (flushDisplayEvents drains at startMatch, but the
  -- sender's stop()-final may still be in flight). When we detect the
  -- boundary, treat the incoming snapshot as the first of the new match:
  -- drop the stale snapshot we just stored, reset prev. Two signals:
  --   (a) Big clock regression: prev.f >> incoming.f (new match started
  --       at clock 0 or low).
  --   (b) Resurrection: prev had go>0 (dead) but incoming has go==0
  --       (alive). You can't un-die within a match.
  local cur = self.snapshot
  local isBoundary = false
  if cur then
    local prevF = cur.f or 0
    local nextF = snapshot.f or 0
    if (prevF - nextF) > 60 then isBoundary = true end
    if (cur.go or 0) > 0 and (snapshot.go or 0) == 0 then isBoundary = true end
  end
  if isBoundary then
    self.snapshot     = nil
    self.prevSnapshot = nil
    self.prevRecvTime = 0
    self._cachedPanels = nil
  end
  -- Shift latest → prev for interpolation. Render uses both to lerp
  -- displacement (and cursor, if cheap) between frames.
  self.prevSnapshot   = self.snapshot
  self.prevRecvTime   = self.latestRecvTime
  self.snapshot       = snapshot
  self.latestRecvTime = love.timer.getTime()
  self.snapshotsApplied = self.snapshotsApplied + 1

  -- Delta merge: snapshot.p arrives with `true` for cells unchanged since
  -- the last shipped state. Resolve to a full grid using the cached
  -- previous grid, then replace snapshot.p with the resolved grid so the
  -- rest of the render path (paintGridFromSnapshot) is unaware deltas
  -- exist.
  if snapshot.p then
    local cached = self._cachedPanels
    -- Orphan-delta safety: if a new spectator joins mid-match, their
    -- first snapshot may arrive as a delta (sender doesn't know about
    -- viewers; keyframes only every KEYFRAME_EVERY sends). Without a
    -- cache, an unresolved `true` cell hits expandCell as `not true.c`
    -- which is a crash. Resolve to `false` (empty) when nothing cached;
    -- the next keyframe corrects.
    for i = 1, #snapshot.p do
      if snapshot.p[i] == true then
        snapshot.p[i] = (cached and cached[i]) or false
      end
    end
    local nextCache = {}
    for i = 1, #snapshot.p do nextCache[i] = snapshot.p[i] end
    self._cachedPanels = nextCache
  end

  -- Push HUD scalars onto the matching engine so existing HUD render
  -- methods (drawScore etc.) display the correct values.
  mirrorHudScalars(self, snapshot)

  -- Telemetry, throttled to ~1Hz. Mirrors the [SPECTATE-SEND] log on
  -- the sender so we can compare side-by-side what was shipped vs.
  -- what we got. Grep logs/client.log for `[SPECTATE-RECV]`. One-shot
  -- on first death-state snapshot per stack so we know the wire path
  -- delivered the death info.
  local nowSec = self.latestRecvTime
  if (nowSec - (self._lastTelemetryAt or 0)) >= 1.0 then
    self._lastTelemetryAt = nowSec
    -- Count panels in the wire-form grid by state. Each cell is either
    -- false (empty pad), a table with .s/.c, or absent.
    local total, stateCount = 0, {}
    local p = snapshot.p
    if p then
      for _, cell in pairs(p) do
        if type(cell) == "table" and cell.c and cell.c ~= 0 then
          total = total + 1
          local s = cell.s or "?"
          stateCount[s] = (stateCount[s] or 0) + 1
        end
      end
    end
    local keys, parts = {}, {}
    for k in pairs(stateCount) do keys[#keys+1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts+1] = k .. "=" .. stateCount[k] end
    local dc = snapshot.dc
    local dcStr = "{}"
    if type(dc) == "table" then
      local cols = {}
      for i = 1, #dc do if dc[i] then cols[#cols+1] = tostring(i) end end
      dcStr = "{" .. table.concat(cols, ",") .. "}"
    end
    require("common.lib.logger").info(string.format(
      "[SPECTATE-RECV] pid=%s clock=%s go=%s d=%s panels=%d states=[%s] dangerCols=%s dt=%s",
      tostring(self.playerID),
      tostring(snapshot.f or 0),
      tostring(snapshot.go or 0),
      tostring(snapshot.d or 0),
      total, table.concat(parts, ","), dcStr,
      tostring(snapshot.dt or 0)))
  end
  if (snapshot.go or 0) > 0 and not self._loggedFirstDeath then
    self._loggedFirstDeath = true
    require("common.lib.logger").info(string.format(
      "[SPECTATE-RECV] FIRST-DEATH-SNAPSHOT pid=%s go=%s clock=%s",
      tostring(self.playerID),
      tostring(snapshot.go or 0),
      tostring(snapshot.f or 0)))
  end
  -- One-shot triggers: pop FX + score cards. Replay each by calling the
  -- existing PlayerStack helpers on the remote stack so its pop_q + cards
  -- queues fill exactly as if the panel had popped locally. The existing
  -- drawPopEffects / drawCards code paths then render them. Fire-and-
  -- forget — events are discarded after replay so they don't double-play
  -- on the next snapshot.
  if snapshot.e and self.viewStack and self.viewStack.enqueue_popfx then
    local SoundController = require("client.src.music.SoundController")
    local theme = themes and themes[config and config.theme]
    for _, ev in ipairs(snapshot.e) do
      if ev.k == "pop" then
        pcall(self.viewStack.enqueue_popfx, self.viewStack, ev.col, ev.row, ev.sz or 1)
        if theme and theme.sounds and theme.sounds.pops then
          local popLevel = math.min(math.max(ev.pl or 1, 1), 4)
          local popIndex = math.min(math.max(ev.gi or ev.pi or 1, 1), 10)
          local sfx = theme.sounds.pops[popLevel] and theme.sounds.pops[popLevel][popIndex]
          if sfx then pcall(SoundController.playSfx, SoundController, sfx) end
        end
      elseif ev.k == "card" and self.viewStack.enqueue_card then
        pcall(self.viewStack.enqueue_card, self.viewStack, ev.chain == true, ev.col, ev.row, ev.n or 1)
        local character = self.viewStack.character
        if character then
          if ev.chain == true and character.playChainSfx then
            pcall(character.playChainSfx, character, ev.n or 1)
          elseif ev.chain ~= true and character.playComboSfx then
            pcall(character.playComboSfx, character, ev.n or 1)
          end
        end
      elseif ev.k == "gland" then
        if theme and theme.sounds and theme.sounds.garbage_thud then
          local idx = math.min(math.max(ev.h or 1, 1), 3)
          local sfx = theme.sounds.garbage_thud[idx]
          if sfx then pcall(SoundController.playSfx, SoundController, sfx) end
        end
      end
    end
    snapshot.e = nil
  end
end

---Diagnostic snapshot for tests / debug overlays.
function DisplayClientStack:debugSnapshot()
  local s = self.snapshot or {}
  return {
    playerID         = self.playerID,
    snapshotsApplied = self.snapshotsApplied,
    frame            = s.f,
    cursorRow        = s.cr,
    cursorCol        = s.cc,
    gameOverClock    = s.go,
  }
end

-- Fallback empty table for snapshots that pre-date the danger-col field
-- (older sender versions). Lookup `dangerCol[col]` returns nil → renderer
-- falls through to the non-danger branch.
local NO_DANGER = {}

-- Re-expand a wire-form cell into a Panel-shaped table the existing
-- Panels:addToDraw / drawGarbage helpers expect. Wire uses short keys
-- (c/s/t/g/m/...); this maps them back to the long names the renderer
-- reads. Returns nil for empty cells.
local function expandCell(cell, row, col, frameTimes)
  if not cell or not cell.c or cell.c == 0 then return nil end
  return {
    color              = cell.c,
    state              = cell.s or "normal",
    column             = col,
    row                = row,
    timer              = cell.t  or 0,
    isGarbage          = cell.g  or false,
    metal              = cell.m  or false,
    chaining           = cell.ch or false,
    garbageId          = cell.gi,
    x_offset           = cell.xo,
    y_offset           = cell.yo,
    width              = cell.gw,
    height             = cell.gh,
    pop_time           = cell.pt,
    initial_time       = cell.it,
    combo_size         = cell.cs,
    combo_index        = cell.ci,
    isSwappingFromLeft = cell.sl or false,
    fell_from_garbage  = cell.fg,
    -- frameTimes is per-match (level data); the receiver attaches the
    -- viewStack's engine's frameTimes when available so matched-state
    -- timing math in getDrawProps works.
    frameTimes         = frameTimes,
  }
end

-- Walk the snapshot grid, painting each non-empty cell as a panel sprite
-- or a multi-cell garbage block. Re-uses the same Panels:addToDraw batch
-- system PlayerStack:drawPanels uses, and the same garbage-draw helpers
-- on the character / metal panel set. Cells are passed through with
-- their real state so matched / swapping / popping animations render
-- correctly via the existing getDrawProps state machine.
---@param self DisplayClientStack
---@param viewStack table the matching ClientStack (for panels_dir + gfxScale + character)
---@param snapshot DisplayClientStackSnapshot
---@param shakeOffset number panel-coord vertical shake from mirrored shake_time
local function paintGridFromSnapshot(self, viewStack, snapshot, shakeOffset)
  local panelsDir = viewStack.panels_dir
  if not panelsDir then return end
  local panelSet = panels and panels[panelsDir]
  if not panelSet or not panelSet.addToDraw then return end

  panelSet:prepareDraw()

  local width  = snapshot.w or 6
  local height = snapshot.h or 12
  local displacement = snapshot.d or 0
  local grid = snapshot.p or {}
  -- Danger animation lives on PlayerStack (danger_col, danger_timer);
  -- sender ships them as dc/dt so the receiver can play the column-
  -- bounce on stacks that reached the danger zone.
  local dangerCol   = snapshot.dc or NO_DANGER
  local dangerTimer = snapshot.dt or 0

  -- frameTimes lives on the engine.levelData.frameConstants; needed by
  -- getDrawProps for the matched-state flash/face/pop timing. We pull
  -- it from the still-resident remote engine — it doesn't tick but its
  -- level data is set up at match start and is stable.
  local frameTimes
  if viewStack.engine
      and viewStack.engine.levelData
      and viewStack.engine.levelData.frameConstants then
    frameTimes = viewStack.engine.levelData.frameConstants
  end

  -- Garbage character + metal panel set come from the sender's stack;
  -- ClientStack already loaded them at match start. Match the lookup
  -- PlayerStack:drawPanels uses so multi-cell garbage renders with the
  -- right sprite atlas.
  local garbageCharacter = viewStack.garbageSource and viewStack.garbageSource.character
                       or viewStack.character
  local metalPanelSet    = viewStack.garbageSource and panels[viewStack.garbageSource.panels_dir]
                       or panelSet

  local metall_w, metall_h, metalr_w, metalr_h
  if metalPanelSet and metalPanelSet.images and metalPanelSet.images.metals then
    metall_w, metall_h = metalPanelSet.images.metals.left:getDimensions()
    metalr_w, metalr_h = metalPanelSet.images.metals.right:getDimensions()
  end

  -- Loop matches PlayerStack:drawPanels' iteration order (rows from
  -- bottom, columns right-to-left so swap animations layer correctly).
  for row = 0, height do
    for col = width, 1, -1 do
      local cell = grid[row * width + col]
      local panel = expandCell(cell, row, col, frameTimes)
      if panel and panel.state ~= "popped" then
        local draw_x = 4 + (col - 1) * 16
        local draw_y = 4 + (11 - row) * 16 + displacement - shakeOffset

        if panel.isGarbage then
          -- Only the bottom-right corner of a garbage block triggers the
          -- block draw (mirrors PlayerStack:drawPanels).
          if panel.x_offset == (panel.width or 1) - 1 and panel.y_offset == 0 then
            if panel.state ~= "matched"
                or (panel.timer and panel.pop_time and panel.timer <= panel.pop_time) then
              if panel.metal and metalPanelSet and metalPanelSet.drawMetalGarbage then
                metalPanelSet:drawMetalGarbage(draw_x, draw_y, panel.width, viewStack.gfxScale)
              elseif garbageCharacter and garbageCharacter.drawGarbage then
                local drawHeight = math.min(panel.height or 1,
                  28 + (panel.height or 1) % 4)
                local garbageX = draw_x - ((panel.width or 1) - 1) * 16
                local garbageY = draw_y - (drawHeight - 1) * 16
                garbageCharacter:drawGarbage(garbageX, garbageY, panel.width, drawHeight, viewStack.gfxScale)
              end
            end
          end
          -- Matched garbage panels also draw the per-cell "pop reveal"
          -- sprite. Reuse the panel set's batch for that.
          if panel.state == "matched" and frameTimes then
            panelSet:addToDraw(panel, draw_x, draw_y, viewStack.gfxScale,
              dangerCol, dangerTimer, snapshot.st or 0)
          end
        else
          panelSet:addToDraw(panel, draw_x, draw_y, viewStack.gfxScale,
            dangerCol, dangerTimer, snapshot.st or 0)
        end
      end
    end
  end

  panelSet:drawBatch()
end

-- Cursor sprite is fetched the same way PlayerStack:render_cursor does:
-- alternating frame indexed by snapshot.f / 16 % 2. Position in panel
-- coords matches the engine's (cur_col-1)*16, (11-cur_row)*16 +
-- displacement formula.
local function paintCursorFromSnapshot(self, viewStack, snapshot)
  local theme = viewStack.theme or (themes and themes[config and config.theme])
  if not theme or not theme.images or not theme.images.cursor then return end
  local frameIndex = (math.floor((snapshot.f or 0) / 16) % 2) + 1
  local cursor = theme.images.cursor[frameIndex]
  if not cursor or not cursor.image then return end

  -- During countdown the cursor blinks (alternating frames invisible);
  -- mirror PlayerStack:render_cursor's behavior.
  local countdown_timer = snapshot.ct or 0
  if countdown_timer > 0 and ((snapshot.f or 0) % 2 ~= 0) then return end

  local desiredCursorWidth = 40
  local panelWidth = 16
  local scale_x = desiredCursorWidth / cursor.image:getWidth()
  local scale_y = 24 / cursor.image:getHeight()

  -- Cursor-only interpolation: lerp from prev (cr, cc) to latest (cr, cc)
  -- over ~30ms wall-clock. Short interval so we glide instead of teleport
  -- between snapshots, without re-introducing the displacement lag-bug.
  local cr = snapshot.cr or 1
  local cc = snapshot.cc or 1
  local prev = self.prevSnapshot
  if prev and self.latestRecvTime > 0 then
    local elapsed = love.timer.getTime() - self.latestRecvTime
    local alpha = math.min(1, math.max(0, elapsed / 0.03))
    local prevCr = prev.cr or cr
    local prevCc = prev.cc or cc
    if math.abs(cr - prevCr) <= 6 then cr = prevCr + (cr - prevCr) * alpha end
    if math.abs(cc - prevCc) <= 6 then cc = prevCc + (cc - prevCc) * alpha end
  end

  local xPosition = (cc - 1) * panelWidth
  local yPosition = (11 - cr) * panelWidth + (snapshot.d or 0)

  if (snapshot.go or 0) > 0 then
    love.graphics.setColor(1, 1, 1, 0.3)
  else
    love.graphics.setColor(1, 1, 1, 1)
  end

  love.graphics.draw(cursor.image,
    xPosition * viewStack.gfxScale,
    yPosition * viewStack.gfxScale,
    0,
    scale_x * viewStack.gfxScale,
    scale_y * viewStack.gfxScale)
  love.graphics.setColor(1, 1, 1, 1)
end

---Render this remote player's board from the stored snapshot. Uses the
---existing Panels:addToDraw batch system so panel sprites match the
---player's chosen panel mod. Drawn inside viewStack:setDrawArea so the
---transform / scissor match the old viewer's coordinate system.
---
---No engine work. The snapshot is the state; we paint from it directly.
---@param viewStack table the matching ClientStack (for layout)
-- Render at the latest authoritative state. No interpolation, no
-- artificial lag. Snapshots arrive frequently enough (20Hz baseline,
-- 60Hz during raises via the fast-event bypass) that direct rendering
-- keeps up. The earlier delayed-interp introduced a half-interval lag
-- that never caught up because every fresh snapshot reset the elapsed
-- clock — visible to the user as the remote "lagging behind" forever.
----------------------------------------------------------------------
-- Layer-by-layer draw paths. One function per visible component; each
-- one knows exactly what it draws and what it needs. The render method
-- is a flat call list — no `if hasX then drawX` branches inline.
-- Adding/removing/reordering a layer is one line.
----------------------------------------------------------------------

-- Character portrait painted behind the stack frame. No-op if the
-- viewStack doesn't expose drawCharacter (e.g. SimulatedStack).
local function drawPortraitLayer(viewStack)
  if not viewStack.drawCharacter then return end
  pcall(viewStack.drawCharacter, viewStack)
end

-- The panel grid: every non-empty cell becomes a sprite or part of a
-- multi-cell garbage block. Owns its own batch via panelSet:drawBatch.
-- pcall'd so a malformed cell (e.g. delta sentinel not resolved against
-- the receiver's cache) crashes only the grid layer for this frame,
-- not the surrounding portrait/frame/wall/cursor.
local function drawGridLayer(self, viewStack, snapshot, shakeOffset)
  local ok, err = pcall(paintGridFromSnapshot, self, viewStack, snapshot, shakeOffset)
  if not ok then logger.warn("drawGridLayer: " .. tostring(err)) end
end

-- Frame border around the play area.
local function drawFrameLayer(viewStack)
  if not viewStack.drawFrame then return end
  pcall(viewStack.drawFrame, viewStack)
end

-- The wall at the bottom of the panel area. Shakes with the stack but
-- intentionally does NOT take displacement (smooth-scroll offset) — see
-- PlayerStack:render. Skipped if the snapshot didn't ship board height.
local function drawWallLayer(viewStack, snapshot, shakeOffset)
  if not viewStack.drawWall then return end
  if not snapshot.h then return end
  pcall(viewStack.drawWall, viewStack, shakeOffset, snapshot.h)
end

-- The remote player's cursor sprite, placed by snapshot cr/cc. pcall'd
-- so a missing cursor sprite for the remote panels mod can't take the
-- frame down.
local function drawCursorLayer(self, viewStack, snapshot)
  local ok, err = pcall(paintCursorFromSnapshot, self, viewStack, snapshot)
  if not ok then logger.warn("drawCursorLayer: " .. tostring(err)) end
end

-- Compute the shake offset for this frame in panel coordinates. Pulled
-- out so render() stays a flat sequence.
local function computeShakeOffset(viewStack)
  if not viewStack.currentShakeOffset then return 0 end
  if not viewStack.gfxScale or viewStack.gfxScale == 0 then return 0 end
  local ok, val = pcall(viewStack.currentShakeOffset, viewStack)
  if not ok or type(val) ~= "number" then return 0 end
  return val / viewStack.gfxScale
end

-- Flat orchestrator: every layer in declared order. Push/pop balance is
-- owned by withDrawArea + the explicit love.graphics.push/pop wrapper
-- below, so a throw inside any single layer can't leak the matrix stack.
function DisplayClientStack:render(viewStack)
  if not viewStack or not self.snapshot then return end
  if not viewStack.setDrawArea or not viewStack.resetDrawArea then return end

  local snapshot = self.snapshot
  local shakeOffset = computeShakeOffset(viewStack)

  viewStack:withDrawArea(0, 0, function()
    love.graphics.push("all")
    local ok, err = pcall(function()
      drawPortraitLayer(viewStack)
      drawGridLayer(self, viewStack, snapshot, shakeOffset)
      drawFrameLayer(viewStack)
      drawWallLayer(viewStack, snapshot, shakeOffset)
      drawCursorLayer(self, viewStack, snapshot)
    end)
    love.graphics.pop()
    if not ok then logger.warn("DisplayClientStack:render layer error: " .. tostring(err)) end
  end)
end

return DisplayClientStack
