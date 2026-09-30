-- The engine's garbage and score tables, found wherever the engine keeps them.
--
-- The fork exports COMBO_GARBAGE / SCORE_COMBO_TA / SCORE_CHAIN_TA on Stack.
-- Upstream Panel Attack keeps them as locals of common/engine/checkMatches.lua,
-- reachable only as upvalues of the Stack methods that use them. This bot runs
-- on whatever upstream beta is current, so it looks in both places rather than
-- patching the engine -- and FAILS LOUDLY if a table is gone. A missing
-- COMBO_GARBAGE does not crash anything: the evaluator just believes combos
-- send nothing and quietly plays a different game.

local Stack = require("common.engine.Stack")
require("common.engine.checkMatches") -- attaches the match/garbage methods to Stack

local NAMES = { "COMBO_GARBAGE", "SCORE_COMBO_TA", "SCORE_CHAIN_TA" }

local found = {}
for _, name in ipairs(NAMES) do
  if type(Stack[name]) == "table" then found[name] = Stack[name] end
end

local wanted = {}
for _, name in ipairs(NAMES) do if not found[name] then wanted[name] = true end end
if next(wanted) then
  for _, fn in pairs(Stack) do
    if type(fn) == "function" then
      local i = 1
      while true do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if wanted[name] and type(value) == "table" then
          found[name] = value
          wanted[name] = nil
        end
        i = i + 1
      end
    end
  end
end

for _, name in ipairs(NAMES) do
  assert(found[name], "bot.EngineTables: the engine no longer has " .. name ..
    " where the bot looks for it (Stack." .. name .. " or a Stack method's upvalue);" ..
    " the evaluator cannot price garbage or score without it")
end

return found
