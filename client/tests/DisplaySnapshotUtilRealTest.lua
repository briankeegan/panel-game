local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local assert = assert

-- Realistic snapshot covering scalar variation + canonical state names.
local real_snapshot = {
  f = 456, d = 2.75, cr = 5, cc = 4,
  w = 6, h = 12,
  ic = false, rl = true,
  sh = 0, psh = 0, pkh = 0,
  dt = 3, ct = 0, go = 0,
  im = "touch",
  cn = 4, sc = 12345, sp = 7,
  pc = 22, mp = 0, hp = 100,
  st = 0, ps = 0, sw = 11,
  dc = {true, false, false, false, false, true},
  p = {
    {c=1,s="normal"}, {c=2,s="swapping"}, {c=3,s="popping"}, {c=4,s="matched"},
    {c=5,s="landing"}, {c=6,s="hovering"}, {c=7,s="falling"}, {c=0,s="dimmed"},
    {c=0,s="dead"}, {c=0,s="popped"},
  },
}

local function test_real_snapshot()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local from = 7
  local packed = DisplaySnapshotUtil.pack_snapshot(from, real_snapshot)
  assert(packed, "Packing failed for real snapshot")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  for _, k in ipairs({"f","cr","cc","w","h","ic","rl","sh","psh","pkh","dt","ct","go",
                      "im","cn","sc","sp","pc","mp","hp","st","ps","sw"}) do
    assert(unpacked[k] == real_snapshot[k],
      "Mismatch on field " .. k .. ": " .. tostring(unpacked[k]) .. " vs " .. tostring(real_snapshot[k]))
  end
  assert(math.abs(unpacked.d - real_snapshot.d) < 1e-6, "displacement drift")
  for i = 1, 6 do
    assert(unpacked.dc[i] == real_snapshot.dc[i], "dc col " .. i)
  end
  for i = 1, #real_snapshot.p do
    assert(unpacked.p[i].c == real_snapshot.p[i].c, "Panel color mismatch at " .. i)
    assert(unpacked.p[i].s == real_snapshot.p[i].s, "Panel state mismatch at " .. i)
  end
  print("Real snapshot test passed.")
end

test_real_snapshot()
