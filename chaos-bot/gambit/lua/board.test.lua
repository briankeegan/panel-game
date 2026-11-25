-- WHAT GAMBIT IS SHOWN OF A BREAK (board.lua shown): a converting garbage panel's colour only once the screen draws it.
--   luajit board.test.lua   (from this directory, or with board.lua's path as its argument)
local B = dofile(arg[1] or ((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "board.lua"))
local function col(p) return B.panel(p, {}, 6, 28)[4] end
local base = { row = 2, column = 3, id = 1, color = 4, isGarbage = true, state = "matched", y_offset = -1, initial_time = 100, pop_time = 40 }
local function with(t) local p = {} for k, v in pairs(base) do p[k] = v end for k, v in pairs(t) do p[k] = v end return p end
assert(col(with{ timer = 90 }) == 130 + (6 * 2 + 2) % 90, "flashing: hidden")
assert(col(with{ timer = 60 }) ~= 4, "flash over, not popped: hidden")
assert(col(with{ timer = 40 }) == 4, "popped: shown")
assert(col(with{ timer = 10 }) == 4, "after pop: shown")
assert(col(with{ timer = 90, y_offset = 0 }) == 4, "rest of the block: its own colour (9)")
assert(col(with{ timer = 90, isGarbage = false, state = "matched" }) == 4, "a plain match: shown")
print("ok: converting garbage colours shown only once drawn")
