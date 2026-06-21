-- chipRegistry.lua — the dynamic chip-generator registry. Every generator self-registers a produce() at require time;
-- buildChipCache discovers all generators (scans bot/get*.lua), requires them, and bakes whatever registered — so a new
-- generator is in the full build the moment its file exists, with no hand-wiring. produce() returns a flat list of
-- bake-ready records: { g = board, sr, sc = fire anchor, kind, absSwaps = {{r,c}..} swap anchors in play order }.
local M = { _byName = {}, _order = {} }

function M.register(spec)            -- spec = { name = string, produce = function() -> records }
  assert(type(spec) == "table" and spec.name and type(spec.produce) == "function", "bad generator spec")
  if not M._byName[spec.name] then M._order[#M._order + 1] = spec.name end
  M._byName[spec.name] = spec        -- last registration of a name wins (re-require is harmless)
end

function M.all()                     -- registered generators, in registration order
  local out = {}; for _, n in ipairs(M._order) do out[#out + 1] = M._byName[n] end; return out
end

-- discover + load every generator file so they self-register (idempotent: require caches). Safe to call repeatedly.
function M.loadAll(dir)
  dir = dir or "bot"
  local ok, lfs = pcall(require, "lfs")
  if not ok then return M end
  local files = {}
  for f in lfs.dir(dir) do local mod = f:match("^(get.+)%.lua$"); if mod then files[#files + 1] = mod end end
  table.sort(files)                  -- deterministic load order
  for _, mod in ipairs(files) do pcall(require, dir .. "." .. mod) end
  return M
end

return M
