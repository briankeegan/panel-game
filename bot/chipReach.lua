-- chipReach.lua — setup cursor-move radius, deliberately ISOLATED from chipSizes. Only the setup generators read it;
-- the shape/cascade generators don't. Keeping it in its own file means tuning the radius invalidates only the setup
-- caches (chipStore hashes each generator's require-closure) and leaves the expensive shape enumerations cached.
local M = {}

-- max cursor-moves between a setup swap and the fire swap. Full reach (5) for every multi-panel family so nothing is
-- left on the table; tiny single combos (3-5 cells, can't span 5 moves) stay at 2.
function M.radius(size)
  if size >= 6 then return 5 end
  return 2
end

return M
