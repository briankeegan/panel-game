-- Single source of truth for the panel-state name<->code mapping. Snapshots
-- carry state as a numeric code everywhere (wire + replay file); it's turned
-- into a name only at draw.
local M = {}

M.codes = {
  normal = 0, swapping = 1, popping = 2, matched = 3, landing = 4,
  hovering = 5, falling = 6, dimmed = 7, dead = 8, popped = 9,
}

M.names = {}
for name, code in pairs(M.codes) do
  M.names[code] = name
end

function M.toCode(state)
  if type(state) == "number" then return state end
  return M.codes[state] or 0
end

-- accepts names unchanged so the engine-seeded initial board passes through
function M.toName(state)
  if type(state) == "string" then return state end
  return M.names[state] or "normal"
end

return M
