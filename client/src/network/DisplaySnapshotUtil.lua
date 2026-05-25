-- DisplaySnapshotUtil.lua
-- Binary pack/unpack for display snapshots. Parallel to the JSON path:
-- callers fall back to JSON when ffiGuard.FFI_SUPPORTED is false. See
-- DisplaySnapshotFFI.lua for the wire-version constant and the layout
-- comment block below for the byte format.
--
-- Wire layout (little-endian throughout):
--   [0]   version  uint8 (= WIRE_VERSION)
--   [1]   from     uint8
--   [2..] fixed scalar block (see SCALAR_OFFSETS below)
--   then variable sections, each prefixed by a uint16 count:
--     panels  : per-cell present-byte + optional bitmask + payloads
--     og      : per-entry header + optional links sublist
--     e       : per-event tag + payload

local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local M = {}

local has_ffi, ffi = pcall(require, "ffi")
local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

----------------------------------------------------------------------
-- Panel state enum (string <-> uint4) — shared with JSON sender's
-- snapshotCell which already writes integer codes via PANEL_STATE_CODES.
-- We accept both string and int on pack for safety; emit string on unpack
-- so the receiver sees the same shape JSON would produce.
----------------------------------------------------------------------
local PANEL_STATE_CODES = {
  normal = 0, swapping = 1, popping = 2, matched = 3, landing = 4,
  hovering = 5, falling = 6, dimmed = 7, dead = 8, popped = 9,
}
local PANEL_STATE_NAMES = {
  [0]="normal",[1]="swapping",[2]="popping",[3]="matched",[4]="landing",
  [5]="hovering",[6]="falling",[7]="dimmed",[8]="dead",[9]="popped",
}

----------------------------------------------------------------------
-- Float<->bytes via FFI union (only used if FFI is available).
----------------------------------------------------------------------
local floatUnion
if has_ffi then
  floatUnion = ffi.new("union { float f; uint8_t b[4]; }")
end

----------------------------------------------------------------------
-- Writer: append bytes to a growing ffi uint8_t buffer. Caller calls
-- W.finish() to get the final binary string.
----------------------------------------------------------------------
local function newWriter(initial_capacity)
  if not has_ffi then return nil end
  local cap = initial_capacity or 1024
  local buf = ffi.new("uint8_t[?]", cap)
  return { buf = buf, cap = cap, n = 0 }
end

local function ensureCap(w, extra)
  local need = w.n + extra
  if need <= w.cap then return end
  local new_cap = w.cap * 2
  while new_cap < need do new_cap = new_cap * 2 end
  local new_buf = ffi.new("uint8_t[?]", new_cap)
  ffi.copy(new_buf, w.buf, w.n)
  w.buf, w.cap = new_buf, new_cap
end

local function wU8(w, v)
  ensureCap(w, 1)
  w.buf[w.n] = band(v, 0xFF)
  w.n = w.n + 1
end

local function wU16(w, v)
  ensureCap(w, 2)
  w.buf[w.n]   = band(v, 0xFF)
  w.buf[w.n+1] = band(rshift(v, 8), 0xFF)
  w.n = w.n + 2
end

local function wU32(w, v)
  ensureCap(w, 4)
  w.buf[w.n]   = band(v, 0xFF)
  w.buf[w.n+1] = band(rshift(v, 8), 0xFF)
  w.buf[w.n+2] = band(rshift(v, 16), 0xFF)
  w.buf[w.n+3] = band(rshift(v, 24), 0xFF)
  w.n = w.n + 4
end

local function wFloat(w, v)
  ensureCap(w, 4)
  floatUnion.f = v
  w.buf[w.n]   = floatUnion.b[0]
  w.buf[w.n+1] = floatUnion.b[1]
  w.buf[w.n+2] = floatUnion.b[2]
  w.buf[w.n+3] = floatUnion.b[3]
  w.n = w.n + 4
end

local function wI8(w, v)
  -- Two's-complement encode of a signed 8-bit value.
  if v < 0 then v = v + 256 end
  wU8(w, v)
end

local function wFinish(w)
  return ffi.string(w.buf, w.n)
end

----------------------------------------------------------------------
-- Reader: walks a string with a cursor. string.byte is intrinsic in
-- LuaJIT, so byte-by-byte reads are fast and alignment-safe.
----------------------------------------------------------------------
local function newReader(data)
  return { data = data, pos = 1, len = #data }
end

local function rU8(r)
  if r.pos > r.len then return nil end
  local v = string.byte(r.data, r.pos)
  r.pos = r.pos + 1
  return v
end

local function rU16(r)
  local b0, b1 = string.byte(r.data, r.pos, r.pos + 1)
  if not b1 then return nil end
  r.pos = r.pos + 2
  return bor(b0, lshift(b1, 8))
end

local function rU32(r)
  local b0, b1, b2, b3 = string.byte(r.data, r.pos, r.pos + 3)
  if not b3 then return nil end
  r.pos = r.pos + 4
  -- bit.bor is signed; reassemble via arithmetic to keep range full.
  return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

local function rFloat(r)
  local b0, b1, b2, b3 = string.byte(r.data, r.pos, r.pos + 3)
  if not b3 then return nil end
  r.pos = r.pos + 4
  floatUnion.b[0] = b0
  floatUnion.b[1] = b1
  floatUnion.b[2] = b2
  floatUnion.b[3] = b3
  return floatUnion.f
end

local function rI8(r)
  local v = rU8(r); if not v then return nil end
  if v >= 128 then v = v - 256 end
  return v
end

----------------------------------------------------------------------
-- dc (danger_col) helpers: snapshot.dc is a sparse boolean array
-- (e.g. {false, true, false, ...}) or nil. Encode up to 8 columns as
-- a uint8 bitmask. nil is encoded as 0 (caller treats nil and all-false
-- identically — see DisplayClientStack).
----------------------------------------------------------------------
local function packDc(dc)
  if type(dc) ~= "table" then return 0 end
  local mask = 0
  for i = 1, 8 do
    if dc[i] then mask = bor(mask, lshift(1, i - 1)) end
  end
  return mask
end

local function unpackDc(mask, width)
  if mask == 0 then return nil end
  local out = {}
  local cols = width or 8
  for i = 1, cols do
    out[i] = band(mask, lshift(1, i - 1)) ~= 0
  end
  return out
end

----------------------------------------------------------------------
-- Panel optional-field bitmask
----------------------------------------------------------------------
local PANEL_OPT = {
  t  = 0x0001,  -- timer        uint16
  g  = 0x0002,  -- isGarbage    (bool flag, no payload)
  m  = 0x0004,  -- metal        (bool flag)
  ch = 0x0008,  -- chaining     (bool flag)
  gi = 0x0010,  -- garbageId    uint32
  xo = 0x0020,  -- x_offset     int8
  yo = 0x0040,  -- y_offset     int8
  gw = 0x0080,  -- width        uint8
  gh = 0x0100,  -- height       uint8
  pt = 0x0200,  -- pop_time     uint16
  it = 0x0400,  -- initial_time uint16
  cs = 0x0800,  -- combo_size   uint8
  ci = 0x1000,  -- combo_index  uint8
  sl = 0x2000,  -- isSwappingFromLeft (bool flag)
  fg = 0x4000,  -- fell_from_garbage  uint8 (1..12)
}

local function packPanel(w, cell)
  if not cell or cell == false then
    wU8(w, 0)
    return
  end
  wU8(w, 1)
  wU8(w, cell.c or 0)
  local state = cell.s
  if type(state) == "string" then state = PANEL_STATE_CODES[state] or 0 end
  wU8(w, state or 0)

  local mask = 0
  if cell.t  and cell.t ~= 0 then mask = bor(mask, PANEL_OPT.t) end
  if cell.g                  then mask = bor(mask, PANEL_OPT.g) end
  if cell.m                  then mask = bor(mask, PANEL_OPT.m) end
  if cell.ch                 then mask = bor(mask, PANEL_OPT.ch) end
  if cell.gi                 then mask = bor(mask, PANEL_OPT.gi) end
  if cell.xo ~= nil          then mask = bor(mask, PANEL_OPT.xo) end
  if cell.yo ~= nil          then mask = bor(mask, PANEL_OPT.yo) end
  if cell.gw ~= nil          then mask = bor(mask, PANEL_OPT.gw) end
  if cell.gh ~= nil          then mask = bor(mask, PANEL_OPT.gh) end
  if cell.pt ~= nil          then mask = bor(mask, PANEL_OPT.pt) end
  if cell.it ~= nil          then mask = bor(mask, PANEL_OPT.it) end
  if cell.cs ~= nil          then mask = bor(mask, PANEL_OPT.cs) end
  if cell.ci ~= nil          then mask = bor(mask, PANEL_OPT.ci) end
  if cell.sl                 then mask = bor(mask, PANEL_OPT.sl) end
  if cell.fg                 then mask = bor(mask, PANEL_OPT.fg) end

  wU16(w, mask)

  if band(mask, PANEL_OPT.t)  ~= 0 then wU16(w, cell.t)  end
  if band(mask, PANEL_OPT.gi) ~= 0 then wU32(w, cell.gi) end
  if band(mask, PANEL_OPT.xo) ~= 0 then wI8 (w, cell.xo) end
  if band(mask, PANEL_OPT.yo) ~= 0 then wI8 (w, cell.yo) end
  if band(mask, PANEL_OPT.gw) ~= 0 then wU8 (w, cell.gw) end
  if band(mask, PANEL_OPT.gh) ~= 0 then wU8 (w, cell.gh) end
  if band(mask, PANEL_OPT.pt) ~= 0 then wU16(w, cell.pt) end
  if band(mask, PANEL_OPT.it) ~= 0 then wU16(w, cell.it) end
  if band(mask, PANEL_OPT.cs) ~= 0 then wU8 (w, cell.cs) end
  if band(mask, PANEL_OPT.ci) ~= 0 then wU8 (w, cell.ci) end
  if band(mask, PANEL_OPT.fg) ~= 0 then
    -- fell_from_garbage can be `true` (boolean) or an integer 0..12.
    -- Receiver only checks truthiness + uses the value as a frame
    -- counter; encode true as 12 (the max set by the engine on land).
    local fg = cell.fg
    if fg == true then fg = 12 end
    wU8(w, fg)
  end
end

local function unpackPanel(r)
  local present = rU8(r); if not present then return nil end
  if present == 0 then return false end
  local c = rU8(r)
  local sCode = rU8(r)
  local mask = rU16(r)
  local cell = {
    c = c,
    s = PANEL_STATE_NAMES[sCode] or "normal",
  }
  if band(mask, PANEL_OPT.t)  ~= 0 then cell.t  = rU16(r) end
  if band(mask, PANEL_OPT.g)  ~= 0 then cell.g  = true end
  if band(mask, PANEL_OPT.m)  ~= 0 then cell.m  = true end
  if band(mask, PANEL_OPT.ch) ~= 0 then cell.ch = true end
  if band(mask, PANEL_OPT.gi) ~= 0 then cell.gi = rU32(r) end
  if band(mask, PANEL_OPT.xo) ~= 0 then cell.xo = rI8(r) end
  if band(mask, PANEL_OPT.yo) ~= 0 then cell.yo = rI8(r) end
  if band(mask, PANEL_OPT.gw) ~= 0 then cell.gw = rU8(r) end
  if band(mask, PANEL_OPT.gh) ~= 0 then cell.gh = rU8(r) end
  if band(mask, PANEL_OPT.pt) ~= 0 then cell.pt = rU16(r) end
  if band(mask, PANEL_OPT.it) ~= 0 then cell.it = rU16(r) end
  if band(mask, PANEL_OPT.cs) ~= 0 then cell.cs = rU8(r) end
  if band(mask, PANEL_OPT.ci) ~= 0 then cell.ci = rU8(r) end
  if band(mask, PANEL_OPT.sl) ~= 0 then cell.sl = true end
  if band(mask, PANEL_OPT.fg) ~= 0 then cell.fg = rU8(r) end
  return cell
end

----------------------------------------------------------------------
-- og (outgoing garbage) entries
----------------------------------------------------------------------
local OG_FLAG_CHAIN     = 0x01
local OG_FLAG_METAL     = 0x02
local OG_FLAG_HAS_LINKS = 0x04

local function packOgEntry(w, g)
  local flags = 0
  if g.isChain then flags = bor(flags, OG_FLAG_CHAIN) end
  if g.isMetal then flags = bor(flags, OG_FLAG_METAL) end
  if type(g.links) == "table" then flags = bor(flags, OG_FLAG_HAS_LINKS) end
  wU8(w, flags)
  wU8(w, g.height or 0)
  wU8(w, g.width or 0)
  wU32(w, g.frameEarned or 0)
  wU8(w, g.rowEarned or 0)
  wU8(w, g.colEarned or 0)
  if band(flags, OG_FLAG_HAS_LINKS) ~= 0 then
    -- links is map<frame -> {rowEarned, colEarned}>. Iterate pairs;
    -- write count first into a placeholder, then patch after enumerating.
    local linkPairs = {}
    for frame, loc in pairs(g.links) do
      linkPairs[#linkPairs + 1] = { frame = frame, row = loc.rowEarned or 0, col = loc.colEarned or 0 }
    end
    wU16(w, #linkPairs)
    for i = 1, #linkPairs do
      local p = linkPairs[i]
      wU32(w, p.frame or 0)
      wU8(w, p.row)
      wU8(w, p.col)
    end
  end
end

local function unpackOgEntry(r)
  local flags = rU8(r)
  local entry = {
    isChain     = band(flags, OG_FLAG_CHAIN) ~= 0,
    isMetal     = band(flags, OG_FLAG_METAL) ~= 0,
    height      = rU8(r),
    width       = rU8(r),
    frameEarned = rU32(r),
    rowEarned   = rU8(r),
    colEarned   = rU8(r),
  }
  if band(flags, OG_FLAG_HAS_LINKS) ~= 0 then
    local n = rU16(r) or 0
    local links = {}
    for _ = 1, n do
      local frame = rU32(r)
      local row = rU8(r)
      local col = rU8(r)
      -- Truncated stream: stop reading rather than indexing with nil.
      if not frame then break end
      links[frame] = { rowEarned = row, colEarned = col }
    end
    entry.links = links
  end
  return entry
end

----------------------------------------------------------------------
-- events
----------------------------------------------------------------------
local EVENT_CARD = 1
local EVENT_POP  = 2

local function packEvent(w, ev)
  if ev.k == "card" then
    wU8(w, EVENT_CARD)
    wU8(w, ev.chain and 1 or 0)
    wU8(w, ev.col or 0)
    wU8(w, ev.row or 0)
    wU16(w, ev.n or 0)
  elseif ev.k == "pop" then
    wU8(w, EVENT_POP)
    wU8(w, 0)
    wU8(w, ev.col or 0)
    wU8(w, ev.row or 0)
    wU16(w, ev.sz or 0)
  else
    -- unknown event kind: emit a placeholder so the reader can skip it
    wU8(w, 0)
    wU8(w, 0)
    wU8(w, 0)
    wU8(w, 0)
    wU16(w, 0)
  end
end

local function unpackEvent(r)
  local kind = rU8(r)
  local flags = rU8(r)
  local col = rU8(r)
  local row = rU8(r)
  local n = rU16(r)
  if kind == EVENT_CARD then
    return { k = "card", chain = flags == 1, col = col, row = row, n = n }
  elseif kind == EVENT_POP then
    return { k = "pop", col = col, row = row, sz = n }
  end
  return nil
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function M.pack_snapshot(from, snapshot)
  if not ffiGuard.FFI_SUPPORTED then return nil end
  if type(snapshot) ~= "table" then return nil end

  local w = newWriter(2048)

  -- Header
  wU8(w, ffiGuard.WIRE_VERSION)
  wU8(w, from or 0)

  -- Fixed scalar block (order matches the layout comment at the top)
  wU32(w, snapshot.f  or 0)
  wFloat(w, snapshot.d or 0)
  wU32(w, snapshot.go or 0)
  wU32(w, snapshot.sc or 0)
  wU16(w, snapshot.cn or 0)
  wU16(w, snapshot.pc or 0)
  wU16(w, snapshot.mp or 0)
  wU16(w, snapshot.st or 0)
  wU16(w, snapshot.ps or 0)
  wU16(w, snapshot.sw or 0)
  wU8(w, snapshot.cr or 1)
  wU8(w, snapshot.cc or 1)
  wU8(w, snapshot.w  or 6)
  wU8(w, snapshot.h  or 12)
  wU8(w, snapshot.sh or 0)
  wU8(w, snapshot.psh or 0)
  wU8(w, snapshot.pkh or 0)
  wU8(w, snapshot.ct or 0)
  wU8(w, snapshot.sp or 0)
  wU8(w, snapshot.hp or 0)
  wU8(w, snapshot.dt or 0)

  local flags = 0
  if snapshot.ic then flags = bor(flags, 0x01) end
  if snapshot.rl then flags = bor(flags, 0x02) end
  if snapshot.im == "touch" then flags = bor(flags, 0x04) end
  wU8(w, flags)
  wU8(w, packDc(snapshot.dc))

  -- panels
  local panels = snapshot.p or {}
  local panelCount = #panels
  wU16(w, panelCount)
  for i = 1, panelCount do
    packPanel(w, panels[i])
  end

  -- og
  local og = snapshot.og or {}
  wU16(w, #og)
  for i = 1, #og do
    packOgEntry(w, og[i])
  end

  -- e
  local e = snapshot.e or {}
  wU16(w, #e)
  for i = 1, #e do
    packEvent(w, e[i])
  end

  return wFinish(w)
end

function M.unpack_snapshot(data)
  if not ffiGuard.FFI_SUPPORTED then return nil end
  if type(data) ~= "string" or #data < 43 then return nil end
  if string.byte(data, 1) ~= ffiGuard.WIRE_VERSION then return nil end

  local r = newReader(data)

  rU8(r) -- version (already validated)
  local from = rU8(r)

  local snapshot = {}
  snapshot.f  = rU32(r)
  snapshot.d  = rFloat(r)
  snapshot.go = rU32(r)
  snapshot.sc = rU32(r)
  snapshot.cn = rU16(r)
  snapshot.pc = rU16(r)
  snapshot.mp = rU16(r)
  snapshot.st = rU16(r)
  snapshot.ps = rU16(r)
  snapshot.sw = rU16(r)
  snapshot.cr = rU8(r)
  snapshot.cc = rU8(r)
  snapshot.w  = rU8(r)
  snapshot.h  = rU8(r)
  snapshot.sh = rU8(r)
  snapshot.psh = rU8(r)
  snapshot.pkh = rU8(r)
  snapshot.ct = rU8(r)
  snapshot.sp = rU8(r)
  snapshot.hp = rU8(r)
  snapshot.dt = rU8(r)

  local flags = rU8(r)
  snapshot.ic = band(flags, 0x01) ~= 0
  snapshot.rl = band(flags, 0x02) ~= 0
  snapshot.im = (band(flags, 0x04) ~= 0) and "touch" or "controller"

  local dcMask = rU8(r)
  snapshot.dc = unpackDc(dcMask, snapshot.w)

  -- panels
  local panelCount = rU16(r) or 0
  local panels = {}
  for i = 1, panelCount do
    panels[i] = unpackPanel(r)
  end
  snapshot.p = panels

  -- og
  local ogCount = rU16(r) or 0
  local og = {}
  for i = 1, ogCount do
    og[i] = unpackOgEntry(r)
  end
  snapshot.og = og

  -- e — only attach if non-empty so receivers don't iterate an empty list
  local eCount = rU16(r) or 0
  if eCount > 0 then
    local e = {}
    for i = 1, eCount do
      e[i] = unpackEvent(r)
    end
    snapshot.e = e
  end

  return from, snapshot
end

return M
