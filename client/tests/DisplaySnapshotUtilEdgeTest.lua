local DisplaySnapshotUtil = require("client.src.network.DisplaySnapshotUtil")
local ffiGuard = require("client.src.network.DisplaySnapshotFFI")
local assert = assert

local function test_empty_snapshot()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {} }
  local from = 0
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for empty snapshot")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch for empty snapshot")
  assert(type(unpacked.p) == "table", "Panels table missing in unpacked empty snapshot")
  print("Empty snapshot test passed.")
end

test_empty_snapshot()

local function test_all_states()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {} }
  local states = { "normal", "swapping", "popping", "matched", "landing", "hovering", "falling", "dimmed", "dead", "popped" }
  for i, s in ipairs(states) do
    orig.p[i] = { c = i, s = s }
  end
  local from = 1
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for all states test")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  for i, s in ipairs(states) do
    assert(unpacked.p[i].s == s, "Panel state mismatch at " .. i .. ": " .. tostring(unpacked.p[i].s) .. " vs " .. tostring(s))
    assert(unpacked.p[i].c == i, "Panel color mismatch at " .. i)
  end
  print("All states test passed.")
end

test_all_states()

local function test_max_panels()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { p = {} }
  for i = 1, 72 do
    orig.p[i] = { c = (i % 8), s = "normal" }
  end
  local from = 99
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed for max panels test")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  for i = 1, 72 do
    assert(unpacked.p[i].c == orig.p[i].c, "Panel color mismatch at " .. i)
    assert(unpacked.p[i].s == orig.p[i].s, "Panel state mismatch at " .. i)
  end
  print("Max panels test passed.")
end

test_max_panels()

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k, v in pairs(b) do
    if not deepEqual(v, a[k]) then return false end
  end
  return true
end

local function test_large_extra_field()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { f=1, d=1, cr=1, cc=1, ic=true, rl=false, sh=1, psh=1, pkh=1, dt=1, ct=1, go=0, im="controller", cn=1, sc=1, sp=1, pc=1, mp=1, hp=1, st=1, ps=1, sw=1, dc=1, p={} }
  for i=1,72 do orig.p[i]={c=1,s="normal"} end
  -- Large extra field (should be truncated to fit 512 bytes)
  local bigstr = string.rep("x", 1000)
  orig.big = bigstr
  local from = 1
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  assert(type(unpacked.big) == "string", "Extra field 'big' missing")
  assert(#unpacked.big < 1000, "Extra field 'big' not truncated")
  print("DisplaySnapshotUtil large extra field test passed.")
end

test_large_extra_field()

local function test_deeply_nested_extra()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { f=1, d=1, cr=1, cc=1, ic=true, rl=false, sh=1, psh=1, pkh=1, dt=1, ct=1, go=0, im="controller", cn=1, sc=1, sp=1, pc=1, mp=1, hp=1, st=1, ps=1, sw=1, dc=1, p={} }
  for i=1,72 do orig.p[i]={c=1,s="normal"} end
  orig.nested = { a = { b = { c = { d = { e = 42 }}}}}
  local from = 2
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  assert(deepEqual(unpacked.nested, orig.nested), "Deeply nested extra field mismatch")
  print("DisplaySnapshotUtil deeply nested extra field test passed.")
end

test_deeply_nested_extra()

local function test_nonstring_key_extra()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { f=1, d=1, cr=1, cc=1, ic=true, rl=false, sh=1, psh=1, pkh=1, dt=1, ct=1, go=0, im="controller", cn=1, sc=1, sp=1, pc=1, mp=1, hp=1, st=1, ps=1, sw=1, dc=1, p={} }
  for i=1,72 do orig.p[i]={c=1,s="normal"} end
  orig[123] = "numberkey"
  local from = 3
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  -- dkjson encodes numeric keys as strings
  assert(unpacked["123"] == "numberkey", "Non-string key not preserved as string")
  print("DisplaySnapshotUtil non-string key extra field test passed.")
end

test_nonstring_key_extra()

local function test_nil_and_empty_fields()
  if not ffiGuard.FFI_SUPPORTED then print("FFI not supported, skipping test.") return end
  local orig = { f=1, d=1, cr=1, cc=1, ic=true, rl=false, sh=1, psh=1, pkh=1, dt=1, ct=1, go=0, im="controller", cn=1, sc=1, sp=1, pc=1, mp=1, hp=1, st=1, ps=1, sw=1, dc=1, p={}, foo=nil, bar="", arr={} }
  for i=1,72 do orig.p[i]={c=1,s="normal"} end
  local from = 4
  local packed = DisplaySnapshotUtil.pack_snapshot(from, orig)
  assert(packed, "Packing failed")
  local from2, unpacked = DisplaySnapshotUtil.unpack_snapshot(packed)
  assert(from2 == from, "From mismatch")
  assert(unpacked.bar == "", "Empty string field not preserved")
  assert(type(unpacked.arr) == "table", "Empty table field not preserved")
  print("DisplaySnapshotUtil nil and empty fields test passed.")
end

test_nil_and_empty_fields()
