-- chipStore.lua — persistent cache for the SLOW shape/cascade enumerations. Each enumerate(args) result is cached to
-- bot/.chipstore/<gen>__<key>.lua, keyed on a hash of the generator's transitive bot/ require-closure (+ the authoring
-- and engine-match core). So a shape computes ONCE EVER — reused across regens AND by the setup generators that call it
-- internally — until its own code (or a dep) actually changes. `rm -rf bot/.chipstore` forces a full recompute.
local M = {}
local DIR = "bot/.chipstore"

local function readFile(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function strhash(s) local h = 5381; for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967291 end; return h end

-- generic Lua-literal serializer for enumerate results (grids, numbers, strings, nested tables; dense arrays only)
local function ser(v)
  local t = type(v)
  if t == "number" then return string.format("%.17g", v) end
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  if t == "table" then
    local parts, n = {}, #v
    for i = 1, n do parts[#parts+1] = ser(v[i]) end
    for k, val in pairs(v) do
      if not (type(k) == "number" and k == math.floor(k) and k >= 1 and k <= n) then
        parts[#parts+1] = "[" .. ser(k) .. "]=" .. ser(val)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
M.serialize = ser

-- transitive bot/ require-closure hash (+ chipBake/chipAnalyze authoring + engine match core), memoized per process
local _hash = {}
local function closure(name, seen)
  if seen[name] ~= nil then return end
  local content = readFile("bot/" .. name .. ".lua"); seen[name] = content or ""
  if content then for dep in content:gmatch('require%("bot%.([%w_]+)"%)') do closure(dep, seen) end end
end
function M.depHash(gen)
  if _hash[gen] then return _hash[gen] end
  local seen = {}; closure(gen, seen); closure("chipBake", seen); closure("chipAnalyze", seen)
  local eng = (readFile("common/engine/checkMatches.lua") or "") .. (readFile("common/engine/Match.lua") or "")
  local names = {}; for k in pairs(seen) do names[#names+1] = k end; table.sort(names)
  local parts = { eng }; for _, k in ipairs(names) do parts[#parts+1] = k .. "\1" .. seen[k] end
  _hash[gen] = strhash(table.concat(parts, "\2"))
  return _hash[gen]
end

-- memoize one enumerate call to disk. key must be filesystem-safe (numbers/underscores).
function M.memoEnum(gen, key, compute)
  local h = M.depHash(gen)
  local path = DIR .. "/" .. gen .. "__" .. key .. ".lua"
  local s = readFile(path)
  if s and s:match("^%-%- HASH (%d+)") == tostring(h) then
    local fn = loadstring(s); if fn then local ok, r = pcall(fn); if ok and r ~= nil then return r end end
  end
  local result = compute()
  os.execute("mkdir -p " .. DIR)
  local f = io.open(path, "w")
  if f then f:write("-- HASH " .. h .. "\nreturn " .. ser(result) .. "\n"); f:close() end
  return result
end

return M
