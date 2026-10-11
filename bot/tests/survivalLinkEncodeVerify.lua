-- survivalLinkEncodeVerify.lua -- the link's board encoder against the key-by-key encoder it replaced: both write
-- the same board, field for field, on boards of every shape the warm-up makes.
--   luajit bot/tests/survivalLinkEncodeVerify.lua
require("bot.headlessBoot")
local SurvivalLink = require("bot.SurvivalLink")
local json = require("common.lib.dkjson")

-- ---- the reference: one string per field, as the link first wrote it
local function num(v)
  if v % 1 == 0 and v > -2 ^ 53 and v < 2 ^ 53 then return string.format("%d", v) end
  return string.format("%.17g", v)
end
-- an object key as JSON, made once
local quoted = setmetatable({}, { __index = function(t, k) local q = string.format("%q", tostring(k)); t[k] = q; return q end })
local function enc(v, depth)
  local t = type(v)
  if v == nil then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v then return '"NaN"' end
    if v == math.huge then return '"Infinity"' end
    if v == -math.huge then return '"-Infinity"' end
    return num(v)
  end
  if t == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
  if t == "table" then
    depth = depth or 0
    if depth > 6 then return '"<deep>"' end
    local n = #v
    local isArray = n > 0 or next(v) == nil
    if isArray then for k in pairs(v) do if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then isArray = false; break end end end
    local parts = {}
    if isArray and n > 0 then
      for i = 1, n do parts[#parts + 1] = enc(v[i], depth + 1) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, x in pairs(v) do
      local tk, tx = type(k), type(x)
      if (tk == "string" or tk == "number") and tx ~= "function" and tx ~= "userdata" and tx ~= "thread" then keys[#keys + 1] = k end
    end
    for _, k in ipairs(keys) do parts[#parts + 1] = quoted[k] .. ":" .. enc(v[k], depth + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
local function scalars(t)
  local o = {}
  for k, v in pairs(t) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then o[k] = v end
  end
  return o
end
-- A table's number, boolean and string fields as a JSON object, without the table `scalars` makes.
local function encScalars(t)
  local parts, n = {}, 0
  for k, v in pairs(t) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then n = n + 1; parts[n] = quoted[k] .. ":" .. enc(v) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function garbageList(q)
  local o = {}
  for i = 1, #q do
    local g = q[i]
    o[i] = { width = g.width, height = g.height, isMetal = g.isMetal or false, isChain = g.isChain or false,
             frameEarned = g.frameEarned, finalized = g.finalized }
  end
  return o
end
-- The garbage each source has sent and not yet delivered: what its
-- telegraph shows (staged, oldest last) and what has left it (transit, by
-- the stopWatch it lands on). Its colours are not in it.
-- Only the garbage due soonest goes: a source's transit in landing order, whole entries, then its staged from the
-- end of the list, the first SOURCE_PIECES pieces in all.
local SOURCE_PIECES = 160
local function telegraph(sources)
  local out = {}
  for i, src in ipairs(sources or {}) do
    local q = src.outgoingGarbage
    local transit, pieces = {}, 0
    if q and q.transitTimers then
      for k = q.transitTimers.first, q.transitTimers.last do
        local t = q.transitTimers[k]
        if t then
          local list = q.garbageInTransit[t] or {}
          if pieces < SOURCE_PIECES then transit[#transit + 1] = { at = t, garbage = garbageList(list) } end
          pieces = pieces + #list
        end
      end
    end
    local staged = q and q.stagedGarbage or {}
    local room = math.max(0, SOURCE_PIECES - pieces)
    local kept = {}
    for j = math.max(1, #staged - room + 1), #staged do kept[#kept + 1] = staged[j] end
    out[i] = { stopWatch = src.stopWatch, staged = garbageList(kept), transit = transit }
  end
  return out
end

local function dump(s, sources)
  local rows = {}
  for r = 0, #s.panels do
    local cells = {}
    for c = 1, s.width do
      local p = s.panels[r] and s.panels[r][c]
      cells[c] = p and encScalars(p) or "false"
    end
    rows[r + 1] = "[" .. table.concat(cells, ",") .. "]"
  end
  local backlog = {}
  for i, rec in ipairs(s.swapStallingBackLog or {}) do backlog[i] = scalars(rec) end
  local landed = {}
  for i, id in ipairs(s.garbageLandedThisFrame or {}) do landed[i] = id end
  return '{"stack":' .. encScalars(s) .. ',"panels":[' .. table.concat(rows, ",") .. ']'
    .. ',"incoming":' .. enc({ staged = garbageList(s.incomingGarbage.stagedGarbage) })
    .. ',"swapStallingBackLog":' .. enc(backlog) .. ',"garbageLandedThisFrame":' .. enc(landed)
    .. ',"dropColumns":' .. enc(s.currentGarbageDropColumnIndexes) .. ',"telegraph":' .. enc(telegraph(sources)) .. '}'
end


local function same(a, b, path)
  if type(a) ~= type(b) then return false, path end
  if type(a) ~= "table" then return a == b, path end
  for k, v in pairs(a) do
    local ok, where = same(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, where end
  end
  for k in pairs(b) do if a[k] == nil then return false, path .. "." .. tostring(k) end end
  return true
end

local function text(s, sources)
  local pieces, count = SurvivalLink.dump(s, sources)
  return table.concat(pieces, "", 1, count)
end

local failures, boards = 0, 0
for i = 1, 600 do
  local s, sources = SurvivalLink.sampleBoard(i)
  local want = json.decode(dump(s, sources))
  local got, _, err = json.decode(text(s, sources))
  boards = boards + 1
  local ok, where = same(want, got, "board " .. i)
  if not ok then failures = failures + 1; if failures <= 5 then print("DIFFERS at " .. tostring(where) .. (err and (" " .. err) or "")) end end
end
print(string.format("encoder: %d boards, %d differ", boards, failures))
os.exit(failures == 0 and 0 or 1)
