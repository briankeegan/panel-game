local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
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
    assert(unpacked.p[i].s == orig.p[i].s,
      "Panel state mismatch at " .. i .. ": " .. tostring(unpacked.p[i].s) .. " vs " .. tostring(orig.p[i].s))
  end
  print("DisplaySnapshotUtil pack/unpack identity test passed.")
end

test_pack_unpack_identity()
