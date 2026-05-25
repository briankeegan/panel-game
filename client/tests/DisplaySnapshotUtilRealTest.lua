local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local assert = assert

-- Example of a more realistic, complex snapshot (fields/nils/booleans)
local real_snapshot = {
  f = 456,
  d = 2.75,
  cr = 5,
  cc = 4,
  ic = false,
  rl = true,
  sh = 0,
  psh = 0,
  pkh = 0,
  dt = 0,
  ct = 0,
  go = 0,
  im = "controller",
  cn = 0,
  sc = 0,
  sp = 1,
  pc = 0,
  mp = 0,
  hp = 100,
  st = 0,
  ps = 0,
  sw = 0,
  dc = 0,
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
  assert(from2 == from, "From mismatch for real snapshot")
  for k, v in pairs(real_snapshot) do
    if k ~= "p" then
      assert(unpacked[k] == v, "Mismatch on field " .. k)
    end
  end
  for i = 1, #real_snapshot.p do
    assert(unpacked.p[i].c == real_snapshot.p[i].c, "Panel color mismatch at " .. i)
    assert(unpacked.p[i].s == real_snapshot.p[i].s, "Panel state mismatch at " .. i .. ": " .. tostring(unpacked.p[i].s) .. " vs " .. tostring(real_snapshot.p[i].s))
  end
  print("Real snapshot test passed.")
end

test_real_snapshot()
