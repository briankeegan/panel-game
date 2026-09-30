-- StackEventRecorder — per-frame EVENT capture for the v1 complete-capture contract
-- (bot/STATE_CAPTURE_DESIGN.md). Connects to an engine Stack's signals and buffers the
-- decision-relevant events as RAW scalar payloads (never the gfx/stack/chain OBJECTS —
-- those aren't serializable and would bloat/circular the corpus). One recorder per stack,
-- held weak-keyed so it GCs with the stack (no leak; mirrors the engine's own signal
-- lifecycle). `BoardState.capture` drains it once per frame.
--
-- Identical live and on replay re-sim — the same signals fire either way, so the corpus
-- and the live bot see the same event stream BY CONSTRUCTION. Events are stored RAW here;
-- any binning/aggregation is the DERIVE layer's job (data track's call: raw in corpus).
--
-- NOTE: during a live ROLLBACK re-sim, signals re-fire and would be re-captured; the live
-- bot drains per frame so this only matters across a net-correction (rare). The corpus
-- re-parse is a clean forward re-sim, so its event stream is exact.

local M = {}

-- weak-by-key: the recorder (value) lives exactly as long as its stack (key).
local recorders = setmetatable({}, { __mode = "k" })

local function n(x) return type(x) == "number" and x or nil end

-- Each handler appends ONE flat scalar event to buf. cb signature: (subscriber, ...emitted).
-- Emitted payloads (verified vs common/engine/*.lua emitSignal calls):
local handlers = {
  -- a match resolved: combo size, whether it's a chain link, metal count, garbage cleared
  matched = function(buf, _, _stack, _gfx, isChain, comboSize, metalCount, garbageCount)
    buf[#buf + 1] = { type = "matched", chain = isChain and true or false,
      combo = n(comboSize), metal = n(metalCount) or 0, garbage = n(garbageCount) or 0 }
  end,
  -- garbage panels converted this clear (the dig signal): count + how many were on-screen
  garbageMatched = function(buf, _, count, onScreen)
    buf[#buf + 1] = { type = "garbageMatched", count = n(count), onScreen = n(onScreen) }
  end,
  -- a chain just ENDED — "the window is closing" cue for the break->setup->chain loop
  chainEnded = function(buf, _, chain)
    buf[#buf + 1] = { type = "chainEnded", height = type(chain) == "table" and n(chain.height) or nil }
  end,
  -- a chain just EXTENDED a link
  newChainLink = function(buf, _, chain)
    buf[#buf + 1] = { type = "newChainLink", height = type(chain) == "table" and n(chain.height) or nil }
  end,
  -- garbage the bot SENT (its own offense leaving the board)
  garbagePushed = function(buf, _, g)
    buf[#buf + 1] = { type = "garbagePushed", w = type(g) == "table" and n(g.width) or nil,
      h = type(g) == "table" and n(g.height) or nil, chain = type(g) == "table" and (g.isChain and true or false) or nil }
  end,
  panelLanded = function(buf) buf[#buf + 1] = { type = "panelLanded" } end,
  panelPop    = function(buf) buf[#buf + 1] = { type = "panelPop" } end,
  panelsSwapped = function(buf) buf[#buf + 1] = { type = "panelsSwapped" } end,
  swapDenied  = function(buf) buf[#buf + 1] = { type = "swapDenied" } end,
  newRow      = function(buf) buf[#buf + 1] = { type = "newRow" } end,
  gameOver    = function(buf) buf[#buf + 1] = { type = "gameOver" } end,
}

local function attach(stack)
  local rec = { buf = {}, token = {} } -- token kept alive by rec so the weak sub survives
  for name, h in pairs(handlers) do
    -- only connect to signals this stack actually defines (connectSignal asserts otherwise)
    if stack.signalSubscriptions and stack.signalSubscriptions[name] then
      stack:connectSignal(name, rec.token, function(...) h(rec.buf, ...) end)
    end
  end
  recorders[stack] = rec
  return rec
end

function M.forStack(stack)
  return recorders[stack] or attach(stack)
end

-- Return the events buffered since the last drain, and reset. The callbacks read rec.buf
-- fresh on each emit, so swapping in a new table here is safe.
function M.drain(stack)
  local rec = M.forStack(stack)
  local out = rec.buf
  rec.buf = {}
  return out
end

return M
