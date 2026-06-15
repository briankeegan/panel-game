-- Pure-Lua reimplementation of LÖVE's love.math RandomGenerator (xorshift64*),
-- for running the engine HEADLESS (bot client, replay re-sim, server E2E) where
-- real LÖVE isn't present. Must be BIT-EXACT to LÖVE so headless panel
-- generation matches a real client's — otherwise boards desync.
--
-- LÖVE's RNG is version-stable (11.x and 12.x clients already play in sync, so
-- the algorithm cannot differ between them). Verified against real LÖVE via
-- bot/rng_probe.
--
-- Shared module: both the bot track and the data track's re-sim import this
-- (DATA_CONTRACT §12). Install over the engine with:
--   love.math.newRandomGenerator = require("common.lib.LoveRandom").newRandomGenerator

local ffi = require("ffi")
local bit = require("bit")
local bxor, bor, lshift, rshift, bnot = bit.bxor, bit.bor, bit.lshift, bit.rshift, bit.bnot

local u64 = ffi.typeof("uint64_t")
-- LÖVE: rng_state.b64 *= 2685821657736338717ULL after the xorshifts.
local MUL = 2685821657736338717ULL
-- LÖVE default seed (RandomGenerator ctor): low=0xCBBF7A44, high=0x0139408D.
local DEFAULT_SEED = 0x0139408DCBBF7A44ULL

-- Thomas Wang's 64-bit integer hash — LÖVE's setSeed runs the seed through this
-- (re-hashing while zero) to scramble it into the initial state, because
-- xorshift gives poor distribution across similar seeds.
local function wangHash64(key)
  key = bnot(key) + lshift(key, 21)
  key = bxor(key, rshift(key, 24))
  key = (key + lshift(key, 3)) + lshift(key, 8)
  key = bxor(key, rshift(key, 14))
  key = (key + lshift(key, 2)) + lshift(key, 4)
  key = bxor(key, rshift(key, 28))
  key = key + lshift(key, 31)
  return u64(key)
end

-- reinterpret a uint64 bit pattern as an IEEE-754 double (LÖVE's random() trick)
local conv = ffi.new("union { uint64_t i; double d; }")

local RandomGenerator = {}
RandomGenerator.__index = RandomGenerator

-- One xorshift64* step -> 64-bit cdata.
function RandomGenerator:rand()
  local s = self.state
  s = bxor(s, rshift(s, 12))
  s = bxor(s, lshift(s, 25))
  s = bxor(s, rshift(s, 27))
  self.state = s
  return s * MUL -- uint64 multiply wraps mod 2^64
end

-- random() -> double in [0, 1). LÖVE: u.i = (0x3FF << 52) | (r >> 12); u.d - 1.0
function RandomGenerator:_random01()
  local r = self:rand()
  conv.i = bor(lshift(u64(0x3FF), 52), rshift(r, 12))
  return conv.d - 1.0
end

-- random()            -> [0,1)
-- random(max)         -> integer [1, max]
-- random(min, max)    -> integer [min, max]
function RandomGenerator:random(min, max)
  if min == nil then
    return self:_random01()
  elseif max == nil then
    return math.floor(self:_random01() * min) + 1
  else
    return math.floor(self:_random01() * (max - min + 1)) + min
  end
end

function RandomGenerator:setSeed(seed, high)
  local s
  if high ~= nil then
    -- (low, high) 32-bit halves, like love.math.setRandomSeed(low, high)
    s = bor(lshift(u64(high), 32), u64(ffi.cast("uint32_t", seed)))
  else
    s = u64(seed)
  end
  self.seed = s
  -- LÖVE: hash the seed into the state, re-hashing while zero (xorshift can't
  -- escape a zero state).
  repeat
    s = wangHash64(s)
  until s ~= 0ULL
  self.state = s
end

function RandomGenerator:getSeed()
  return self.seed
end

-- State snapshot for the engine's panel generators. The engine only
-- snapshots/restores it in-memory between generations (never serialized to the
-- wire), so round-tripping the raw 64-bit cdata is sufficient and exact.
function RandomGenerator:getState()
  return self.state
end

function RandomGenerator:setState(s)
  self.state = u64(s)
end

local M = {}

function M.newRandomGenerator(seed, high)
  local self = setmetatable({ state = DEFAULT_SEED, seed = DEFAULT_SEED }, RandomGenerator)
  if seed ~= nil then self:setSeed(seed, high) end
  return self
end

M.RandomGenerator = RandomGenerator
return M
