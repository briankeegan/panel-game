local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local PanelStateCodes = require("client.src.network.PanelStateCodes")
local assert = assert

local function test_pack_unpack_identity()
  if not ffiGuard.FFI_SUPPORTED then
    print("FFI not supported, skipping test.")
    return
  end
  local orig = {
    f = 123, d = 1.5, cr = 2, cc = 3,
    w = 6, h = 12,
    ic = true, rl = false,
    sh = 4, psh = 5, pkh = 6,
    dt = 7, ct = 8, go = 0,
    im = "controller",
    cn = 9, sc = 1000, sp = 2,
    pc = 10, mp = 1, hp = 50,
    st = 0, ps = 0, sw = 0,
    dc = {false, true, false, false, false, true},
    p = {},
  }
  for i = 1, 72 do
    orig.p[i] = { c = (i % 8), s = (i % 10 == 0) and "matched" or "normal" }
  end
  local from = 42
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  for _, k in ipairs({"f","cr","cc","w","h","ic","rl","sh","psh","pkh","dt","ct","go",
                      "im","cn","sc","sp","pc","mp","hp","st","ps","sw"}) do
    assert(unpacked[k] == orig[k],
      "Mismatch on field " .. k .. ": " .. tostring(unpacked[k]) .. " vs " .. tostring(orig[k]))
  end
  assert(math.abs(unpacked.d - orig.d) < 1e-6, "displacement (float) drift")
  for i = 1, 6 do
    assert(unpacked.dc[i] == orig.dc[i], "dc column " .. i .. " mismatch")
  end
  for i = 1, 72 do
    assert(unpacked.p[i].c == orig.p[i].c, "Panel color mismatch at " .. i)
    -- unpack yields the numeric state code; orig uses engine state names
    assert(unpacked.p[i].s == PanelStateCodes.toCode(orig.p[i].s),
      "Panel state mismatch at " .. i .. ": " .. tostring(unpacked.p[i].s)
        .. " vs " .. tostring(PanelStateCodes.toCode(orig.p[i].s)))
  end
  print("DisplaySnapshotUtil pack/unpack identity test passed.")
end

-- Regression: the engine's -1 alive sentinel must never reach the wire — it
-- round-trips through uint32 as 4294967295 and reads back as "dead". Capture
-- coerces alive to 0; here we prove 0 stays 0 and a real death frame survives.
local function test_game_over_clock_sentinel()
  if not ffiGuard.FFI_SUPPORTED then
    print("FFI not supported, skipping go sentinel test.")
    return
  end
  local function roundtrip_go(go)
    local snap = {
      f = 1, d = 0, cr = 1, cc = 1, w = 6, h = 12,
      ic = false, rl = false, sh = 0, psh = 0, pkh = 0,
      dt = 0, ct = 0, go = go, im = "controller",
      cn = 0, sc = 0, sp = 0, pc = 0, mp = 0, hp = 0,
      st = 0, ps = 0, sw = 0,
      dc = {false, false, false, false, false, false},
      p = {},
    }
    for i = 1, 72 do snap.p[i] = { c = 0, s = "normal" } end
    local packed = DisplaySnapshotUtil.pack_snapshot(1, snap)
    local _, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
    return unpacked.go
  end
  assert(roundtrip_go(0) == 0, "alive (go=0) must round-trip to 0, got " .. tostring(roundtrip_go(0)))
  assert(roundtrip_go(500) == 500, "death frame (go=500) must round-trip to 500, got " .. tostring(roundtrip_go(500)))
  print("DisplaySnapshotUtil go sentinel test passed.")
end

test_pack_unpack_identity()
test_game_over_clock_sentinel()
