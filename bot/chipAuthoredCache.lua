-- chipAuthoredCache.lua — per-generator cache of FINAL authored chips (after bake.author's engine-heavy measure/classify).
-- buildChipCache uses this so an UNCHANGED generator skips BOTH its search AND the authoring — it just reads the finished
-- chips off disk. Kept separate from chipStore (which the generators require) on purpose: adding this file does NOT change
-- any generator's dep-hash, so it can't invalidate the enumerate caches. Keyed on the same per-generator dep-hash.
local store = require("bot.chipStore")
local DIR = "bot/.chipstore"
local M = {}

local function readFile(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

function M.load(gen)
  local s = readFile(DIR .. "/" .. gen .. "__authored.lua")
  if s and s:match("^%-%- HASH (%d+)") == tostring(store.depHash(gen)) then
    local fn = loadstring(s); if fn then local ok, r = pcall(fn); if ok and type(r) == "table" then return r end end
  end
  return nil
end

function M.save(gen, chips)
  os.execute("mkdir -p " .. DIR)
  local f = io.open(DIR .. "/" .. gen .. "__authored.lua", "w")
  if f then f:write("-- HASH " .. store.depHash(gen) .. "\nreturn " .. store.serialize(chips) .. "\n"); f:close() end
end

return M
