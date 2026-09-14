-- botState.lua — P2 of the chips-brain redesign (CHIPS_BRAIN_PLAN.md). Classifies the top-level state
-- RAISE / DANGER / OFFENSE from the board signals (Brian's defs, 2026-06-19).
--
-- Brian's defs are interdependent (RAISE references !OFFENSE, OFFENSE references !RAISE), so they need an evaluation
-- ORDER to be deterministic. The only ordering that satisfies every clause:
--   DANGER (topped out) > RAISE (material < 5) > OFFENSE (mid-chain, has time) > RAISE (board low) > OFFENSE (default)
-- i.e. the mid-chain OFFENSE override is what makes RAISE's 2nd clause "&& !OFFENSE" resolve.

local M = {}

-- rows that hold at least one of OUR (non-garbage) panels = our playable material
local function nonGarbageRows(board, rows, width)
  local n = 0
  for r = 1, rows do
    local row = board[r]
    if row then for c = 1, width do
      local cell = row[c]
      if cell and cell.c ~= 0 and not cell.isGarbage then n = n + 1; break end
    end end
  end
  return n
end

-- classify(state) -> stateName, signals(table for tracing/sub-state use)
function M.classify(state)
  local rows = state.rows
  local width = state.width or 6
  local top = rows                                  -- the ceiling
  local height = state.maxColHeight or 0            -- total stack height incl garbage
  local toppedOut = state.toppedOut or state.critical or false
  local midChain = (state.chainCounter or 0) >= 2   -- chain_counter counts from 2
  local ngRows = nonGarbageRows(state.board, rows, width)

  local sig = { ngRows = ngRows, height = height, top = top, toppedOut = toppedOut, midChain = midChain,
                health = state.health, maxHealth = state.maxHealth }

  if toppedOut then return "DANGER", sig end                 -- the death timer is ticking — this is when timing matters
  if ngRows < 5 then return "RAISE", sig end                 -- too little material to work with
  if midChain then return "OFFENSE", sig end                 -- don't interrupt a chain (not topped => we have time)
  if height < top - 2 then return "RAISE", sig end           -- board low: build it up
  return "OFFENSE", sig                                      -- default: make offense
end

return M
