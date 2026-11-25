-- THE CHAOS STACK AS THE C ENGINE'S BOARD (engine/ca.h, through gambit/native/pa.c's HEAD), as the player sees it: every field by pa.c's own name, every panel's fields
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
  -- the chaos v3 stack's own fields (reference/chaos-v3/common/engine/Stack.lua), under the names gambit/native/pa.c's HEAD reads
  local ld, fc, bh, q = a.levelData, a.levelData.frameConstants, a.behaviours, a.incomingGarbage
  put("riseTimer", a.rise_timer)
  put("levelData.maxHealth", ld.maxHealth); put("levelData.shockFrequency", ld.shockFrequency); put("levelData.shockCap", ld.shockCap)
  put("frames.HOVER", fc.HOVER); put("frames.GARBAGE_HOVER", fc.GARBAGE_HOVER); put("frames.FLASH", fc.FLASH)
  put("frames.FACE", fc.FACE); put("frames.POP", fc.POP); put("frames.GARBAGE_POP", fc.GARBAGE_POP)
  put("levelData.stop.BaseConstant", ld.stop.BaseConstant)
  put("game_mode", a.game_mode); put("margin_time", a.margin_time); put("chaos_mode", a.chaos_mode)
  put("incoming.GarbageQueueType", q.GarbageQueueType); put("incoming.ChaosMode", q.ChaosMode)
  put("incoming.illegalStuffIsAllowed", q.illegalStuffIsAllowed)
  put("behaviours.passiveRaise", bh.passiveRaise); put("behaviours.allowManualRaise", bh.allowManualRaise)
  put("behaviours.swapStallingMode", bh.swapStallingMode); put("behaviours.swapStallingPunish", bh.swapStallingPunish)
  put("behaviours.startTimersWithSwapCount", bh.startTimersWithSwapCount or 0)
  put("height", a.height); put("panelsCreatedCount", a.panelsCreatedCount); put("speed", a.speed)
  put("nextSpeedIncreaseClock", a.nextSpeedIncreaseClock); put("clock", a.clock); put("game_stopwatch", a.game_stopwatch)
  put("displacement", a.displacement); put("rise_lock", a.rise_lock); put("has_risen", a.has_risen)
  put("manual_raise", a.manual_raise); put("manual_raise_yet", a.manual_raise_yet); put("prevent_manual_raise", a.prevent_manual_raise)
  put("swapThisFrame", a.swapThisFrame); put("stop_time", a.stop_time); put("pre_stop_time", a.pre_stop_time)
  put("shake_time", a.shake_time); put("prev_shake_time", a.prev_shake_time); put("shake_time_on_frame", a.shake_time_on_frame)
  put("peak_shake_time", a.peak_shake_time or 0); put("health", a.health); put("panels_in_top_row", a.panels_in_top_row)
  put("chain_counter", a.chain_counter); put("clear_counter", a.clear_counter); put("has_all_clear", a.has_all_clear)
  put("n_active_panels", a.n_active_panels); put("n_prev_active_panels", a.n_prev_active_panels)
  put("n_active_garbage", a.n_active_garbage); put("n_prev_active_garbage", a.n_prev_active_garbage)
  put("garbage_landed_this_frame", a.garbage_landed_this_frame); put("garbage_landed_last_frame", a.garbage_landed_last_frame)
  put("garbage_matched_this_frame", a.garbage_matched_this_frame); put("swappingPanelCount", a.swappingPanelCount)
  put("panels_cleared", a.panels_cleared); put("metalPanelsQueued", a.metalPanelsQueued)
  put("garbage_panels_cleared", a.garbage_panels_cleared); put("cur_row", a.cur_row); put("cur_col", a.cur_col)
  put("top_cur_row", a.top_cur_row); put("queuedSwapRow", a.queuedSwapRow); put("queuedSwapColumn", a.queuedSwapColumn)
  put("swapCount", a.swapCount); put("cur_timer", a.cur_timer); put("cur_wait_time", a.cur_wait_time or 20)
  put("cursorDirection", a.cursorDirection == nil and -1 or DIRS[a.cursorDirection])
  put("garbageCreatedCount", a.garbageCreatedCount); put("highestGarbageIdMatched", a.highestGarbageIdMatched)
  put("game_over_clock", a.game_over_clock or 0); put("margin_time_counter", a.margin_time_counter)
  put("shake_margin", a.shake_margin); put("color_count", a.color_count)
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
