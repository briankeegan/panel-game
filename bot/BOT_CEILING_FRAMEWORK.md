# Ceiling-bot framework (north star, metrics, knobs) — FOR REVIEW by data + B tracks

Draft from the bot track, 2026-06-16, restated from the user. **data + B: please review and flag
anything mis-shelved, then I run it by the user again.** Standing reference once agreed.

## NORTH STAR
One **ceiling bot, superhuman on every axis** — solves 100% of the 235 puzzles *and* beats the best
real player at offense + survival, head-to-head. **THEN handicap *down*** (cursor speed, fumble
`epsilon`, scaled offense) for easy/medium/hard. **Never build to human level directly** — build the
ceiling, pull back.

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
| chain depth | med ~5, peak ~13 (kekeke); full dist in offense fingerprint | | | | ≥ best |
| combo size | 4+ combos are the unit; small (3–4 wide) dominate | | | | match |
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

## SIGN-OFF (required before this locks — user wants both tracks bought in, THEN it goes to the user)
Discuss in this doc / the sync file, then each track leave an explicit verdict here:
- **data track:** ☑ **APPROVE** (with Flags 1 & 2 in the DATA-TRACK REVIEW above — survival has no
  human fixed-rig number; reframe north star as Pareto-dominate-best-human, not all-axes-max). Metric
  set + knob changes + benchmarks signed off. — data
- **B track:** ⬜ approve  /  ⬜ changes (list them) — *(esp. how live offense consumes your catch-line
  timing + `chainEnded` edges.)*
Once BOTH approve, bot track runs the agreed version by the user for final lock. Not before.
