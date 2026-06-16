# Ceiling-bot framework (north star, metrics, knobs) — FOR REVIEW by data + B tracks

Draft from the bot track, 2026-06-16, restated from the user. **data + B: please review and flag
anything mis-shelved, then I run it by the user again.** Standing reference once agreed.

## 🔁 SECOND REVIEW CYCLE (2026-06-16) — both tracks please RE-CONFIRM on THIS final version
User reviewed and likes it; wants one more formal review+approval pass from both tracks before lock.
**What changed since data's first sign-off:** (1) North Star hardened to **STRICTLY-better-than-best-human
on every axis** (user overruled the "≥ / Pareto-dominate" softening — frontier is now a measurement note,
not a softening); (2) **full inventory added** — all 16 eval knobs + 4 tier + 6 planners, and all 39 puzzle
technique types; (3) data's flags resolved (survival uses human proxies; strict-better bar stands).
**ACTION:** data + B — re-read, then set your verdict in the SIGN-OFF section at the bottom (approve / changes).
Both ✅ → bot track brings the locked version back to the user as a table.

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

## DIMENSIONS (winning-centric — v2 re-think, supersedes the old per-axis "metrics" table; UNDER REVIEW)
**The game is WON, not stat-maximized.** The north metric is **WINNING**; every other dimension is a
*component* of it. And **solving puzzles ≠ winning** — puzzles are a **capability gate**, not the strength score.

- **① WIN — the integral.** Beats the best human head-to-head. *Measure:* contested vs an opponent sending
  garbage at a real human's measured rate/pattern (corpus-derived) → bot out-survives their offense AND out-pressures them.
- **Performance components (must EXCEED best human; measured CONTESTED, not solo):**
  - **② Offense output** — garbage SENT/min (> kekeke 26.5).
  - **③ Offense quality** — chain depth + combo-size dist (hard-to-dig pressure, not spam — guards ② vs tiny-combo gaming).
  - **④ Survival** — time-to-topout under the corpus-derived human pressure; clean board indefinite. *(hardest to measure; needs ①'s rig.)*
  - **⑤ Execution** — speed (APM) + accuracy. The native edge; the dial we **HANDICAP** for the ladder.
- **Capability GATE (necessary, not sufficient):**
  - **⑥ Mechanics** — ~100% of the 235 puzzles (minus frame-perfect air-catches; self-check tops 99.1%). Proves it CAN do every technique.
- **Reliability:**
  - **⑦ Robustness** — wins/survives across seeds + opponents (report p10, not just median).
- **STYLE (NOT ceiling axes — only for the per-player CLONES):** combo-width mix, swaps/clear, danger-dwell. The clones match these; the ceiling dominates ①–⑦.

## ARCHITECTURE PREMISE (the bar likely needs more than knobs)
Hitting ②–④ superhuman almost certainly requires a **break→setup→chain LOOKAHEAD planner**, NOT knob tuning:
the greedy 1-ply eval caps ~8 sends/min, can't construct through garbage, solves ~7% of puzzles; only a real
sequence-search (`puzzleSolveTimed`) solved inserts. The KNOBS below are the eval surface — but reaching the
bar is an architecture change, not a tuning pass. *(If a reviewer believes a tuned eval CAN reach it, say why.)*

## OPEN QUESTIONS (reviewers — pressure-test these)
- Is "win vs a corpus-derived human-RATE/PATTERN opponent" a sound integral, or does it hide skills —
  garbage TIMING/telegraph play, counter-attacking on vulnerable frames, comeback, opponent adaptation?
- Are ①–⑦ the right set? missing or redundant dimension?
- Each dimension: well-defined + measurable vs humans + non-gameable (Goodhart)? where's the worst perverse incentive?
- Is the puzzles-as-GATE vs winning-as-SCORE split correct?
- Is the architecture premise right, or could a sufficiently-tuned eval reach the bar?

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

### DATA reply to "flag a specific unreachable axis with evidence" (2026-06-16)
No axis I can call *unreachable* with proof — so not blocking. But the **risk axis to watch is
offense-volume-while-surviving**: your own sweeps had offense top ITSELF out at ~20/min and the current
eval sits ~5/min, vs best-human **26.5/min** — and the survival↔full-board tension is real. comboPlan +
flawless execution *should* clear it (your argument, I accept it), but this is the one axis where
strict-better isn't yet *demonstrated*. Treat it as the prove-it axis at validation: if anything
under-delivers strict-better, it'll be sustained 26.5+/min without topping out. Everything else
(puzzles, chain depth, survival proxies) I expect flawless execution to exceed. — data

## SIGN-OFF (required before this locks — user wants both tracks bought in, THEN it goes to the user)
Discuss in this doc / the sync file, then each track leave an explicit verdict here:
- **data track:** ☑ **APPROVE — RE-CONFIRMED on the 2nd-cycle final version (2026-06-16).** Flag 1
  (survival proxies) resolved as I asked. Flag 2 (strict-better vs Pareto): **accept the user's overrule** —
  the "flawless execution shifts the whole envelope outward" argument is sound, so strict-better-on-every-axis
  is achievable in principle and the frontier stays a measurement note. No remaining changes from data.
  Benchmarks (offense >26.5/min, chain-into-garbage ≥60%, orange's deep-chain dist, small-combo widths)
  stand as the targets. Signed off. — data
- **B track:** ⬜ approve  /  ⬜ changes (list them) — *(esp. how live offense consumes your catch-line
  timing + `chainEnded` edges.)*
Once BOTH approve, bot track runs the agreed version by the user for final lock. Not before.
