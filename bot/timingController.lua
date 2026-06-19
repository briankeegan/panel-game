-- DEPRECATED: old bot brain, being replaced by the chips-brain rebuild (see bot/CHIPS_BRAIN_PLAN.md). Do NOT build on this.
-- timingController.lua — B-track. The WHEN, as a thin FSM ABOVE the FIT/cache (NOT folded into the FIT cost).
-- Data's Audit 7 (Brian's WHEN theory, measured): offense is gated on the stop-time freeze clock, not board shape.
-- This controller picks the MODE; the FIT/cache decides the WHAT within that mode. Keeping it a separate gate (vs a
-- leaf term in the beam) is deliberate — timing as a per-frame leaf score fails (greedy search stalls; see
-- build_signal_integration). A gate that switches modes is the climb-until-fire structure that works, and it lets the
-- live brain SKIP the deep FIT search in RAISE/BUILD phases (relieves the full-board search cost A/B flagged).
--
-- Pure function, no engine deps — trivially testable and wireable. Cutoffs are TUNABLE against the human per-band
-- targets data is putting in bench_targets.json (Audit 7b). Defaults below are placeholders from the orange/kekeke
-- policy; do NOT treat them as final until data confirms on more corpora.
--
--   local mode = timingController.decide({ stopClock=, danger=, incomingEta=, chainReady=, breakReady= }, cfg)
--   mode ∈ "RAISE" | "BUILD" | "FIRE" | "BREAK"   -- the live brain runs the matching subsystem for that mode.

local M = {}

M.defaults = {
  clockLow = 12,        -- below this the freeze window is still "filling" → BUILD, don't fire yet
  clockHigh = 33,       -- at/above this the window is "full" → spend it (FIRE/BREAK)
  clockFloor = 33,      -- keep the clock above this between attacks (measured floor ~33f, never 0)
  dangerHigh = 0.80,    -- top-out proximity (0..1, surface/ceiling) above which survival overrides
  leadFrames = 30,      -- start the fire this many frames BEFORE incoming lands (proactive, not reactive)
}

-- state fields (all optional; nil treated as benign):
--   stopClock   : current stop_time freeze counter (0 = no freeze)
--   danger      : 0..1 top-out proximity (surface height / ceiling)
--   incomingEta : frames until incoming garbage lands (nil/inf = none imminent)
--   chainReady  : a fireable chain tactic is arranged (cache hit / FIT has a fire line) — bool
--   breakReady  : a garbage-break tactic is available (adjacent near-match) — bool
function M.decide(state, cfg)
  cfg = cfg or M.defaults
  local clock = state.stopClock or 0
  local danger = state.danger or 0
  local eta = state.incomingEta or math.huge
  local chainReady = state.chainReady and true or false
  local breakReady = state.breakReady and true or false
  local comboReady = state.comboReady and true or false

  -- 1. SURVIVAL OVERRIDE: about to top out and a break is available → take it (opens stop-time, buys the window).
  if danger >= cfg.dangerHigh and breakReady then return "BREAK" end

  -- 2. NO FREEZE YET (clock 0): TAKE an available clear. Measured (botBench AVAIL diag): a combo is available ~75% of
  --    frames but the bot fires almost none — it sits in BUILD/flails and clears 6-9 panels/game. Break first (opens
  --    stop-time + chains garbage), else a chain, else FIRE THE COMBO to clear (keep the board down, make progress).
  if clock <= 0 then
    if breakReady then return "BREAK" end
    if chainReady then return "FIRE" end
    if comboReady then return "FIRE" end
    return "RAISE"
  end

  -- 3. WINDOW FULL (clock high) OR incoming imminent: spend it. FIRE if a chain is arranged, else BREAK to chain
  --    garbage / refresh the clock. Proactive: a near-term incoming (within lead time) fires defensively even if the
  --    window isn't full yet. (Floor-keeping is emergent: firing when full refreshes stop-time before it hits 0.)
  local windowFull = clock >= cfg.clockHigh
  local imminent = eta <= cfg.leadFrames
  if windowFull or imminent then
    if chainReady then return "FIRE" end
    if breakReady then return "BREAK" end   -- no chain ready but spend/refresh the window via a break
    return "BUILD"                          -- nothing to fire → keep arranging
  end

  -- 4. WINDOW FILLING (low/mid clock, no imminent incoming): BUILD — arrange the chain, don't fire yet.
  return "BUILD"
end

return M
