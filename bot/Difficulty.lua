-- Single source of truth for difficulty tiers. A tier bundles SPEED (cursor APM
-- cap + reaction delay, consumed by CursorController) with MOVE QUALITY (chain
-- awareness + mistake rate, consumed by SearchBrain) so a weak tier plays like a
-- weak HUMAN — slower AND sloppier, not a slow perfect bot.
--
-- Speed knobs are calibrated from real human timing (DATA_CONTRACT §13). Move-
-- quality knobs are hand-set placeholders; the data track can calibrate them per
-- ELO bucket (how often weaker players build chains / misclick) later.
--
--   cursorMoveInterval — min frames between cursor moves/swaps (APM cap)
--   reactionFrames     — delay before acting on a new engagement
--   chainAware [0..1]  — scales how much the eval values chains; low => mostly
--                        just clears (beginner), 1 => full chain-building
--   epsilon    [0..1]  — chance per decision of a non-optimal swap (a fumble)

local Difficulty = {}

Difficulty.TIERS = {
  easy   = { cursorMoveInterval = 17, reactionFrames = 7, chainAware = 0.20, epsilon = 0.35 },
  medium = { cursorMoveInterval = 11, reactionFrames = 4, chainAware = 0.60, epsilon = 0.12 },
  hard   = { cursorMoveInterval = 8,  reactionFrames = 3, chainAware = 1.00, epsilon = 0.00 },
}

-- resolve a tier name (or an explicit knob table) to a tier table; default medium
function Difficulty.get(d)
  if type(d) == "table" then return d end
  return Difficulty.TIERS[d] or Difficulty.TIERS.medium
end

return Difficulty
