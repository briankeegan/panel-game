# Ceiling-bot framework (north star, metrics, knobs) — FOR REVIEW by data + B tracks

Draft from the bot track, 2026-06-16, restated from the user. **data + B: please review and flag
anything mis-shelved, then I run it by the user again.** Standing reference once agreed.

## NORTH STAR
One **ceiling bot, STRICTLY better than the best human on EVERY axis** — offense, survival, puzzles, all
of it. Solves 100% of the 235 puzzles *and* out-attacks AND out-survives the best real player.
**THEN handicap *down*** (cursor speed, fumble `epsilon`, scaled offense) for easy/medium/hard. **Never
build to human level directly** — build the ceiling, pull back.

**On the offense↔survival frontier (data Flag 2 — RESOLVED, not a softening):** the frontier is real but
doesn't stop "better at all." A superhuman bot's WHOLE envelope sits outside the human's: playing ONE
balanced config it sends more than the *aggressive* human AND survives longer than the *safe* human,
because it executes flawlessly (faster, no fumbles, sees every setup). So there's no axis where a human
beats it. The frontier is only a **measurement note**: compare each axis at the bot's best vs the human's
best — NOT "must theoretical-max all axes in one config." Bar stays STRICTLY-better-on-all (not "≥ with ties").

## THE CORE MODEL (so metrics/knobs follow from it)
Survival and offense are the SAME act: **break → setup → chain**, riding the stop-time/shake
invincibility window. Garbage on your board is cleared as a **byproduct** of chains.
- **Garbage BREAKING matters** — breaking garbage triggers the clear, opens stop-time, and is how a
  chain consumes garbage. The bot MUST break garbage well (as part of offense).
- **DIGGING is BS** — reactive, clear-garbage-for-room-as-a-chore, optimizing a "garbage-cleared count."
  No dig planner, no dig mode, no dig-count goal. You break garbage to FEED a chain / open a window,
  not to make room.

## METRICS — old → new
| axis | OLD (reactive) | NEW (offense-centric) |
|---|---|---|
| mechanics | puzzle pass-rate (~7%) | puzzle pass-rate → **target 100%** (every insert/combo/chain/clear) |
| offense | barely measured | **blocks SENT / min** — must *exceed* best human (>26.5) |
| garbage **breaking** | **dig-COUNT maximized (reactive)** ❌ | **chain-into-garbage RATE** = fraction of garbage-breaks inside an active chain. **data MEASURED: humans 38–60% chained, ~0% standalone 3-match** → breaking matters, but only as offense. Drop raw break-count. |
| survival | survival seconds (separate skill) | **time-to-topout under fixed garbage** (data's call — pure survival, no dig bias); **byproduct** of the loop; **clean board must be indefinite** |
| timing | blind to it | **stop-time utilization** — % invincible / loop continuity (the offense-as-defense signature) |
| shape | chain depth, combo size | chain depth, combo size — match/beat human |
| verdict | win-rate (noisy) | per-axis vs **data's human benchmarks** (asked; pending) |

## KNOBS — old → new (SearchBrain eval levers)
| group | OLD | NEW |
|---|---|---|
| **digging** | `digPlan`, `digWhenSafe` (reactive dig MODE) | **REMOVE the reactive dig mode/planner** |
| garbage **breaking** | `w_breakGarbage` (reward clearing for room) | **lean `w_breakGarbage` → ~0** (data's call) — keep ONLY as a chain *enabler*; the goal is firing a chain that consumes garbage, not breaking for its own sake |
| offense build | `comboBuild`, `construct`, `patience` | keep + **rebalance** (don't starve clean-board survival) |
| timing | none (couldn't see stop/shake) | **NEW:** stop-time/shake-window awareness; **critical-amplify** (attack hardest when buried — TIMING_L10) |
| chain/combo | `w_chain`, `chainUnit`, `comboUnit` | keep |
| survival | `w_survival`, `heightBand` | keep (survival mostly *emerges* from offense) |
| ladder | `chainAware`, `epsilon`, cursor speed | keep — the **"tune-down" handicaps** |

## PARKED / FUTURE (not adopted yet)
- **"Organizing"** (keep a chain chambered / combo-ready board): MAY become a metric+knob — but NOT
  until its worth is *measured* (does it actually drive offense/survival?). Hypothesis, not a commitment.
- **Puzzle-solve CHOICE breakdown (prioritized):** at some point, analyze *how* the bot solves each
  puzzle — its ranked move choices / priorities — not just pass/fail. Future analysis task.

## FULL INVENTORY (completeness — the grouped tables above abbreviated these)

### Every eval knob (SearchBrain `DEFAULTS` + tier + planners)
- **Weights:** `w_chain`, `w_survival`, `w_shape`, `w_breakGarbage` (→ ~0, chain-enabler only).
- **Values:** `chainUnit`, `comboUnit`, `futureDiscount`, `heightBand`, `actMargin`.
- **Context knobs (gated safe/buried):** `raiseWhenSafe`, `digWhenSafe` (→ REMOVE), `chainDepthWhenSafe`,
  `counterPressure`, `patience`, `construct`, `comboBuild`.
- **Tier handicaps (the "tune-down" levers):** `chainAware`, `epsilon`, `cursorMoveInterval`, `reactionFrames`.
- **Planners / move-gen:** `comboPlan`, `chainPotential`, `candidates`, `setupMove`, `flattenMove`,
  `digPlan` (→ REMOVE).
- **NEW to add (timing):** stop-time/shake-window awareness; **critical-amplify** (attack hardest when buried).

### Every puzzle "type of solve" (235 puzzles, 39 leaf sets) — 100% = ALL of these
- **Win-condition types:** `moves` (71) · `chain` (84) · `clear` (80).
- **Technique categories** (what each set teaches):
  - **Inserts:** inserts · pre_setup_inserts · change_side_inserts · combo_chain_inserts
  - **Combos:** beginner_combos · novice_combos · combo_chains · pre_setup_combo_chains
  - **Chains (core):** beginner_chains · novice_chains · intermediate_chains · chains_from_huge_tower
  - **Horizontal chains:** convert_horizontal_chains · extended_horizontal_chains ·
    horizontal_chain_from_side · horizontal_chain_from_tower
  - **Earthquake chains:** earthquake_chains · deeper_earthquake_chains
  - **Clears (garbage consumed via chain):** novice/intermediate/advanced clear_puzzles (×10)
  - **Advanced setups:** shoguns · transitions
  - **Other:** removes · openers · classic (intro) · mission
- The PARKED "puzzle-solve CHOICE breakdown" ranks the bot's move priorities *within* each category.

## ASKS
- **data:** the full per-axis human benchmark to EXCEED (offense blocks/min, survival under a
  standardized pressure, chain depth, combo-size dist). Standardized survival rig? (see BOT_DATA_UPDATES)
- **B:** your insert-catch timing work + the event stream feed the chain loop — how should the live
  offense consume your `(W,r,c)` catch lines / `chainEnded` edges?
- **both:** review this framework; flag anything wrong before I rebuild offense against it.

## DATA-TRACK REVIEW & SIGN-OFF (2026-06-16)
**Verdict: ✅ APPROVE** — core model (break→setup→chain, garbage-as-byproduct) and the metric/knob
changes match the corpus (Audit 2: ~0% standalone-3 garbage breaks, 38–60% chained). Two flags:

**Per-axis HUMAN benchmark to EXCEED** (L10 corpus, see `PLAYER_AUDITS.md`; best-human bolded):
| axis | chaos | kekeke | mscl | orange | ceiling target |
|---|---|---|---|---|---|
| offense blocks/min | 23.5 | **26.5** | 22.5 | 11.4 | **> 26.5** |
| chain% of sends | 28 | 31 | 35 | **45** | ≥ 45 |
| chain-into-garbage % | 43 | 39 | 38 | **60** | ≥ 60 |
| chain depth %@6+ (per-send) | ~0 | ~0 | 1 | **26** | match orange's deep dist (Audit 4) |
| combo width % (3/4/5/6) | 48/37/13/2 | 47/36/15/2 | 41/37/19/3 | 54/25/16/5 | small-dominant (match) |
| activity (swaps/clear) | 38.8 | 34.6 | 24.0 | 21.8 | style, NOT a ceiling axis |
| danger dwell % | 35 | 54 | 36 | 48 | lower=safer |

**Flag 1 — survival benchmark caveat:** there is **no clean human "time-to-topout under fixed garbage"**
from replays — humans never play a standardized rig (garbage is variable, real-opponent). Your
`survivalStress` IS the rig, but it's bot-only; I can't source a human number for it. Use human survival
PROXIES: game-length, danger-dwell %, and "clean board → indefinite" (humans achieve this). Frame the
survival ceiling as "indefinite on a clean board + survives buried longer than any human observed," not
a fixed-rig second-count I can't produce.

**Flag 2 — "superhuman on EVERY axis" collides with the Pareto frontier YOU found.** Your own sweeps:
offense ~20/min tops itself out, ~4/min survives; full-board offense vs low-board dig-reliability trade
off. So one config can't be max-offense AND max-survival at once — the ceiling bot is the best POINT on
the frontier (beyond humans *on* the frontier), not all-axes-max simultaneously. Recommend the north
star read **"Pareto-dominate the best human (≥ on every axis, > on several)"**, not "superhuman on every
axis simultaneously" — else we chase an impossible all-max and mis-read a good frontier bot as failing.

**Knobs:** removing the reactive dig mode + leaning `w_breakGarbage`→0 (keep only as a chain enabler) is
consistent with Audit 2 — approved.

### BOT-TRACK RESPONSE to data's review (2026-06-16)
Thanks — benchmark table + Audit 2 confirmation accepted. On your two flags (ran by the user):
- **Flag 1 (survival has no human fixed-rig number): ACCEPTED.** Survival ceiling = "indefinite on a clean
  board" + "survives buried longer than any human observed (via game-length / danger-dwell proxies)" +
  beat the *bot-only* `survivalStress`/`time-to-topout` as an internal regression. We won't claim a human
  fixed-rig second-count you can't source.
- **Flag 2 (Pareto frontier vs all-axes): the USER ruled — bar stays STRICTLY-better-on-all, NOT ≥-with-ties.**
  Reasoning (now in NORTH STAR): the superhuman bot's whole envelope dominates the human's, so one balanced
  config out-attacks the aggressive human AND out-survives the safe human. The frontier is a *measurement
  note* (compare each axis at bot-best vs human-best), not a softening. So please read benchmarks as
  "ceiling must EXCEED best-human on every axis," not "≥". If you think strict-better is unreachable on a
  *specific* axis with evidence, flag THAT axis concretely — but the default bar is strict-better-everywhere.

## SIGN-OFF (required before this locks — user wants both tracks bought in, THEN it goes to the user)
Discuss in this doc / the sync file, then each track leave an explicit verdict here:
- **data track:** ☑ **APPROVE** (with Flags 1 & 2 in the DATA-TRACK REVIEW above — survival has no
  human fixed-rig number; reframe north star as Pareto-dominate-best-human, not all-axes-max). Metric
  set + knob changes + benchmarks signed off. — data
- **B track:** ⬜ approve  /  ⬜ changes (list them) — *(esp. how live offense consumes your catch-line
  timing + `chainEnded` edges.)*
Once BOTH approve, bot track runs the agreed version by the user for final lock. Not before.
