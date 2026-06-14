-- PanelStateCodes — the single source of truth for the panel-state
-- <-> numeric-code mapping used across the snapshot pipeline.
--
-- Design: snapshots carry panel `state` as a COMPACT NUMERIC CODE everywhere
-- it is built, transmitted, and stored (the replay file). It is deserialized
-- back to the engine's string name ("normal", "dimmed", ...) only at the
-- moment of drawing. Both directions go through the helpers below so the table
-- lives in exactly one place.

local M = {}

-- name -> code
M.codes = {
  normal = 0, swapping = 1, popping = 2, matched = 3, landing = 4,
  hovering = 5, falling = 6, dimmed = 7, dead = 8, popped = 9,
}

-- code -> name (derived from M.codes so the two can never drift)
M.names = {}
for name, code in pairs(M.codes) do
  M.names[code] = name
end

-- Serialize: engine string name (or an already-numeric code) -> numeric code.
---@param state string|number|nil
---@return integer
function M.toCode(state)
  if type(state) == "number" then return state end
  return M.codes[state] or 0
end

-- Deserialize: numeric code (or an already-string name) -> engine string name.
-- Accepts strings unchanged so the initial-board seed (read straight off the
-- engine, where state is already a name) passes through untouched.
---@param state number|string|nil
---@return string
function M.toName(state)
  if type(state) == "string" then return state end
  return M.names[state] or "normal"
end

return M
