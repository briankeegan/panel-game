-- THE STACK AS THE C ENGINE'S BOARD (eval/native/pa.h), as the player sees it: every field by pa.c's own name, every panel's fields
-- in pa.h's order, the garbage queued, the stall log. Nothing the player cannot see goes in: the rows not dealt yet, and the colours
-- garbage breaks into until the screen draws each one (shown), are left to the engine's unseen colours, which match nothing.
local M = {}
M.NUL = -2147483648
local NUL = M.NUL
local function b01(v) return v and 1 or 0 end
local function nbool(v) if v == nil then return NUL end return v and 1 or 0 end
local function nint(v) if v == nil then return NUL end return v end

local DIRS = { up = 0, down = 1, left = 2, right = 3 }
-- The board's scalars, by pa.c's HEAD names, each handed to put(name, value) (nil: the Lua's nil, not handed). Nothing is made: a frame
-- that builds no table leaves the collector nothing to do inside it.
function M.head(a, put)
  local ld, fc, st, bh = a.levelData, a.levelData.frameConstants, a.levelData.stop, a.behaviours
  put("riseTimer", a.rise_timer)
  put("levelData.startingSpeed", ld.startingSpeed); put("levelData.colors", ld.colors); put("levelData.maxHealth", ld.maxHealth)
  put("levelData.shockFrequency", ld.shockFrequency); put("levelData.shockCap", ld.shockCap)
  put("levelData.speedIncreaseMode", ld.speedIncreaseMode)
  put("frames.HOVER", fc.HOVER); put("frames.GARBAGE_HOVER", fc.GARBAGE_HOVER); put("frames.FLASH", fc.FLASH)
  put("frames.FACE", fc.FACE); put("frames.POP", fc.POP)
  put("levelData.stop.formula", st.formula); put("levelData.stop.comboConstant", st.comboConstant)
  put("levelData.stop.chainConstant", st.chainConstant); put("levelData.stop.dangerConstant", st.dangerConstant)
  put("levelData.stop.coefficient", st.coefficient); put("levelData.stop.dangerCoefficient", st.dangerCoefficient)
  put("behaviours.passiveRaise", bh.passiveRaise); put("behaviours.allowManualRaise", bh.allowManualRaise)
  put("behaviours.swapStallingMode", bh.swapStallingMode); put("behaviours.swapStallingPunish", bh.swapStallingPunish)
  put("height", a.height); put("panelIdCount", a.panelsCreatedCount); put("speed", a.speed); put("nextSpeedIncreaseClock", a.nextSpeedIncreaseClock)
  put("clock", a.clock); put("stopWatch", a.stopWatch); put("stopWatchIsRunning", a.stopWatchIsRunning); put("inCountdown", a.in_countdown or false)
  put("displacement", a.displacement); put("riseLock", a.rise_lock); put("hasRisen", a.has_risen); put("manualRaise", a.manual_raise)
  put("manualRaiseYet", a.manual_raise_yet); put("preventManualRaise", a.prevent_manual_raise); put("swapThisFrame", a.swapThisFrame)
  put("stopTime", a.stop_time); put("preStopTime", a.pre_stop_time); put("shakeTime", a.shake_time); put("prevShakeTime", a.prev_shake_time)
  put("shakeTimeOnFrame", a.shake_time_on_frame); put("peakShakeTime", a.peak_shake_time); put("health", a.health)
  put("wasToppedOut", a.wasToppedOut); put("chainCounter", a.chain_counter); put("nActive", a.n_active_panels)
  put("nPrevActive", a.n_prev_active_panels); put("swappingCount", a.swappingPanelCount); put("panelsCleared", a.panels_cleared)
  put("metalPanelsQueued", a.metalPanelsQueued); put("score", a.score); put("curRow", a.cur_row); put("curCol", a.cur_col)
  put("topCurRow", a.top_cur_row); put("queuedSwapRow", a.queuedSwapRow); put("queuedSwapCol", a.queuedSwapColumn)
  put("swapCount", a.swapCount); put("curTimer", a.cur_timer); put("curWaitTime", a.cur_wait_time or 20)
  put("cursorDirection", a.cursorDirection == nil and -1 or DIRS[a.cursorDirection]); put("cursorLock", a.cursorLock)
  put("garbageCreatedCount", a.garbageCreatedCount); put("highestGarbageIdMatched", a.highestGarbageIdMatched)
  local over = a.game_over_clock or -1
  put("gameOverClock", over); put("gameOver", over > 0)
end

local STATES = { normal = 0, dimmed = 1, swapping = 2, matched = 3, popping = 4, popped = 5, hovering = 6, falling = 7,
                 landing = 8, dead = 9 }
-- A panel's colour as the screen shows it. A garbage panel a break converts is drawn with its colour only once its flash is over and its
-- pop has come (client/src/graphics/PanelCellRender.lua: flash_time >= FLASH and timer <= pop_time); before that the player sees the
-- garbage's face, so it is one of the engine's unseen break colours (pa.c UNSEEN_COLOUR, 130..219: distinct beside each other, matching
-- nothing).
local function shown(p, width, flash)
  if p.isGarbage and p.state == "matched" and p.y_offset == -1 and
     not (flash and p.initial_time and p.pop_time and p.initial_time - p.timer >= flash and p.timer <= p.pop_time) then
    return 130 + (width * p.row + p.column - 1) % 90
  end
  return p.color
end
-- A panel's fields, in pa.h's order (width, flash: the stack's, for the colour shown).
function M.panel(p, v, width, flash)
  v = v or {}
  v[1], v[2], v[3], v[4], v[5], v[6], v[7] = p.row, p.column, p.id, shown(p, width or 6, flash), nbool(p.chaining), nbool(p.matching), p.timer
  v[8], v[9], v[10], v[11], v[12] = nint(p.initial_time), nint(p.pop_time), nint(p.pop_index), nint(p.x_offset), nint(p.y_offset)
  v[13], v[14], v[15], v[16], v[17] = nint(p.width), nint(p.height), nint(p.shake_time), b01(p.isGarbage), STATES[p.state]
  v[18], v[19], v[20], v[21] = nint(p.combo_index), nint(p.combo_size), nbool(p.isSwappingFromLeft), nbool(p.dont_swap)
  v[22], v[23], v[24], v[25] = nbool(p.queuedHover), nint(p.fell_from_garbage), b01(p.stateChanged), b01(p.propagatesChaining)
  v[26], v[27], v[28], v[29] = b01(p.matchAnyway), nbool(p.propagatesFalling), nint(p.garbageId), nbool(p.metal)
  return v
end
M.NF = 29

-- The garbage queued (the next to drop last), the stall log, the garbage landed this frame and the drop columns, as the game holds them.
local EMPTY = {}
function M.staged(a) return a.incomingGarbage.stagedGarbage end
-- a queued piece's fields, width height chain metal earned finalized, into the io from x; the index after them
function M.putIncoming(g, Bd, x)
  Bd[x], Bd[x + 1], Bd[x + 2], Bd[x + 3], Bd[x + 4] = g.width, g.height, b01(g.isChain), b01(g.isMetal), g.frameEarned
  Bd[x + 5] = g.finalized == nil and NUL or b01(g.finalized)
  return x + 6
end
function M.stall(a) return a.swapStallingBackLog or EMPTY end
function M.putStall(s, Bd, x)
  Bd[x], Bd[x + 1], Bd[x + 2], Bd[x + 3], Bd[x + 4] = s.leftId, s.rightId, s.row, s.col, s.clock
  return x + 5
end
function M.landed(a) return a.garbageLandedThisFrame or EMPTY end
function M.drop(a) return a.currentGarbageDropColumnIndexes or EMPTY end

return M
