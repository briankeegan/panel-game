# Ceiling-bot framework (North Star) — 🔒 LOCKED 2026-06-16 (v3)

The agreed North Star for the superhuman ceiling bot. Converged through 2 adversarial reviews + data + B + the
user. Build plan (divide & conquer) below the lock banner. Changes require user sign-off.

## 🔒 LOCKED 2026-06-16 — v3 is the North Star (data ✅ · B ✅ · user ✅)
Survived 2 adversarial reviewers (Round 1) + both domain experts (data, B) + the user's rulings (dig re-scoped;
strict-better with wiggle room on interaction axes). **This is THE North Star. Changes require user sign-off.**

## 🔒 BUILD PLAN — divide & conquer (2026-06-16)
**Phase 1 (NOW — the puzzle GATE is measurable with no opponent):**
- **BOT track (lead, me):** build the **receding-horizon MPC planner** — beam; sim-horizon ≥ one full cascade,
  commit short; knobs → cost function; re-derive catches live. **VALIDATE on the puzzle GATE first** — drive
  solve-rate 7% → ~100% (every insert/combo/chain/clear). Capability proof, no opponent needed.
- **B track:** the offense-TIMING engine — refine `puzzleSolveTimed` as the MPC reference; supply the event-driven
  candidate-gen + bimodal-W timing prior; help the live planner consume `chainEnded` edges + catch lines (axis ③).
- **DATA track:** (a) re-parse the corpus through the v1 capture (post-fit) → unlocks shake/health/timing signals;
  (b) build the **contested-effect scorecard** (un-dug garbage to a *defending* board; counter-window hit rate;
  win+margin; p10) ready for Phase 2; (c) supply mechanics/style/diagnostic human benchmarks.
**Phase 2 (the contested axes ①②③④⑥⑦ — need an opponent):**
- **JOINT bot+data:** stand up the **killable self-play LEAGUE** (bot: engine harness — extend `winRateTest`
  bot-vs-bot to a checkpoint/tier league + human-input opponents; data: scorecard runs on it). Measure + drive the
  contested axes superhuman → THEN handicap DOWN for the difficulty ladder.

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
best — NOT "must theoretical-max all axes in one config."

**BAR (user ruling 2026-06-16 — wiggle room where uncertain):** STRICTLY-better on the **THROUGHPUT** axes
(②④⑤ — provable; envelope-dominance holds). On the **INTERACTION** axes (③ tactical-timing, ⑦ reading) —
which both reviewers AND data say are hard to build AND can't be human-benchmarked from static replays —
**leave wiggle room: aspire to strict-better, accept Pareto-dominate where we can't yet measure, and REVISIT
as we build/test.** Not locked. We test, then decide.

## THE CORE MODEL (so metrics/knobs follow from it)
Survival and offense are the SAME act: **break → setup → chain**, riding the stop-time/shake
invincibility window. Garbage on your board is cleared as a **byproduct** of chains.
- **Garbage BREAKING matters** — breaking garbage triggers the clear, opens stop-time, and is how a
  chain consumes garbage. The bot MUST break garbage well (as part of offense).
- **DIGGING — RE-SCOPED (user ruling 2026-06-16; reviewers + data all agreed).** Dig-for-COUNT /
  clear-for-room in NORMAL play is still BS (corpus: ~0% standalone breaks; garbage clears via chains).
  BUT **emergency room-making when NO chain is available** (stalled/buried board, meter expiring, wrong
  reveals) is a real SURVIVAL fallback — KEEP it, gated to the critical regime only. Reject dig-COUNT as a
  goal; keep emergency defensive-recovery as a last resort. *(data retracted its "dig is BS" over-claim —
  the corpus is survivor-biased: it can't contain the top-outs an emergency dig prevented.)*

## DIMENSIONS (v3 — rebuilt after Round-1 adversarial review; UNDER REVIEW by data + B)
**The game is WON, not stat-maximized — won by topping the opponent out FIRST.** Both Round-1 reviewers
independently found v2's fatal flaw: it measured "WIN" against a non-reactive, immortal garbage **faucet**
(corpus rate/pattern). You can't kill a recording → it becomes a *survival drill*, the optimal bot is a
**TURTLE** that passes every number while being weak, and it deletes the whole *interactive* skill layer
(timing, counter-attack, comeback, reading). v3 fixes this: **the opponent must be KILLABLE and REACTIVE.**

**① WIN — the integral.** Win-rate **+ lead-margin** (frames-of-lead at top-out) vs a **killable, reacting
opponent**: a *league* of past bot checkpoints + the handicapped tiers, and/or human-input-driven boards that
can top out. NOT a fixed-rate faucet. This restores the race, counter-play, and comeback.

**Performance (measured CONTESTED vs the reacting opponent — score EFFECT, never rates):**
- **② Effective pressure** — **un-dug garbage actually delivered to a *defending* board** (volume × quality ×
  timing collapsed into "did it bury a real defender"). Raw blocks/min = diagnostic only, never a target.
- **③ Tactical timing** *(NEW — Round-1 gap)* — killing-frame hit rate (garbage arriving while the opponent's
  invincibility meter is LOW + stack high) + counter-window hit rate (sends into the opponent's `chainEnded`/
  vulnerable frames). Garbage absorbed inside opponent invincibility counts as WASTED.
- **④ Survival** — vs the reacting opponent's worst bursts, **p10** incl. adversarial buried/stalled seeds.
  Clean-board-indefinite = a binary **sanity gate**, not a score. **Turtling penalized:** survival only counts
  coupled to a minimum contested-offense floor (can't score by under-sending).

**Capability GATE (necessary, NOT sufficient — certifies technique inventory, tests ZERO interaction):**
- **⑤ Mechanics** — ~100% of 235 puzzles **+ a held-out/randomized set** (catch memorization-overfit). Load-
  bearing categories for winning: `openers`, `clear_puzzles` (chain-into-garbage). Minus frame-perfect air-catches.

**Reliability:**
- **⑥ Robustness** — **p10 of ① over HELD-OUT, adversarially-varied opponents/seeds** (not the tuned-against set).

**NATIVE EDGE / handicap lever (NOT a ceiling axis):**
- **Execution** — APM + accuracy (define: intended-swap-executed rate; null/oscillating swaps ≈ 0; wasted-action
  penalty). The tune-down dial ONLY. Never a win-proxy (APM is the most Goodhart-able metric here).

**STYLE (clones only, NOT ceiling axes):** combo-width mix, swaps/clear, danger-dwell, **chain/combo distribution-
match** (moved here — distribution-matching is a clone target, not a strength axis).

**OPEN / flagged (named, not silently dropped):**
- **⑦ Adaptation / reading** — read+counter an opponent it hasn't seen; shift plan mid-set. Superhuman-at-WINNING
  partly lives here; hardest to build; needs ①'s reactive opponent. Flag as OPEN.
- **Opener tempo** — time-to-first-N-chain from the standard start (first-strike equity). Small, cheap, real.

## ARCHITECTURE PREMISE — RECEDING-HORIZON / MPC planner (user clue, 2026-06-16)
Hitting ②–④ superhuman needs a real planner, not knob tuning (greedy 1-ply caps ~8 sends/min, ~7% puzzles;
only `puzzleSolveTimed`'s sequence-search solved inserts). The right FORM is **receding-horizon control (MPC)**:
each frame, plan the break→setup→chain sequence over a *bounded lookahead horizon*, execute only the FIRST move,
then RE-PLAN from the new state next frame. Why it fits this problem precisely:
- **Real-time tractable** — bounded horizon + re-plan stays within the 60Hz budget (you never solve the whole game).
- **Dynamic-opponent-native** — re-planning each frame against the opponent's CURRENT state IS counter-play and
  timing (dimensions ③/⑦): it naturally fires into the opponent's vulnerable frames and rides your own stop-time
  window, instead of committing to a stale plan. This is the mechanism that makes the interactive axes reachable.
- **Subsumes B's work** — `puzzleSolveTimed` is a one-shot *finite*-horizon plan; receding-horizon makes it LIVE.
- The KNOBS below become the planner's **cost function**, not a greedy heuristic.

**MPC build constraints (from B — EARNED on `puzzleSolveTimed`, not theoretical):**
- **Carry a BEAM across frames — don't commit frame-1's single best move.** Pure greedy MPC walks into local
  optima (one wrong catch-column poisons the chain). Keep K candidate break→setup→chain plans alive; re-plan
  from each; let dead-ends fall out. Single-committed-plan-per-frame makes ③ tactical-timing brittle.
- **Sim horizon ≥ one full cascade (~60–78f @ L10); commit short.** A catch's payoff lands one cascade later;
  a short horizon = back to greedy 1-ply (the ~8/min cap). **Cost-function sim-horizon ≠ commit cadence** —
  simulate long, commit the next move only. (Catch timing is bimodal: W≈0–2 or W≈60–78, never the middle.)
- **Re-derive catches each replan from the LIVE board — don't replay stored `(W,r,c)` as scripts** (`W` is
  relative to the live cascade the opponent perturbs). Stored `insert_catches.json` = regression fixtures +
  a move-gen ordering prior, not fixed tactics.
- **`W` IS the ③ tactical-timing lever:** tune it so the send lands in the opponent's low-invincibility window.
  Feed BOTH edge streams into the cost function — my-board `chainEnded` (my stop-window opens → set up inside it),
  opponent-board `chainEnded` (the counter-window to fire INTO). ③ then falls out of the same search.

## ✅ TWO ROUND-1 FINDINGS — RESOLVED by user (2026-06-16)
**① DIG → RE-SCOPED** (everyone agreed; reflected in CORE MODEL: emergency defensive-recovery kept, dig-COUNT
rejected). **② STRICT-BETTER → WIGGLE ROOM** on the interaction axes (③/⑦): aspire to strict, accept Pareto-
dominate where unmeasurable, revisit as we test (reflected in NORTH STAR "BAR"). *Detail of the two findings below.*

1. **"DIGGING is BS" → re-scope, don't delete.** Reviewer 1: emergency *room-making when NO chain is available*
   (stalled/buried board, meter expiring, wrong reveals) is a real SURVIVAL sub-skill, distinct from "dig for a
   garbage-count." The corpus that "proves dig unnecessary" is **survivor-biased** — it can't contain the topouts
   that emergency digs *prevented*. Proposal: keep a **defensive-recovery** capability gated to the stalled/critical
   regime; measure on adversarial buried seeds (⑥ p10). (Still reject dig-for-count.)
2. **"STRICTLY better on every axis" → holds for THROUGHPUT, unproven for INTERACTION.** Both reviewers: envelope-
   dominance is valid for ②④⑤ (flawless execution shifts those out), but NOT obviously for ③/⑦ (timing/reading are
   read-and-respond, where speed alone doesn't help without an opponent model) — and the data track's measured
   offense↔survival Pareto frontier is real. Reviewers recommend: **Pareto-dominate (≥ all, > where demonstrated)**,
   strict-better as the aspiration per axis where provable. (You overruled this once; reviewers give a NEW reason — the
   interaction axes, not the throughput tradeoff. Your call again.)

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
- **data track:** ☑ **APPROVE v3** — the win-vs-reacting-opponent / anti-turtle rebuild is correct; v2's
  faucet-survival framing was the right thing to kill. Three data notes (none blocking):
  1. **Survivor-bias hit on my Audit 2: ACCEPTED, and it corrects my own over-claim.** My "~0%
     standalone-3 breaks → digging is BS" only shows what *surviving* players did in *normal* play — a
     corpus of completed games CANNOT contain the top-outs an emergency dig would have prevented. So my
     data supports **"don't optimize dig-COUNT / don't dig in normal play"** but does **NOT** prove
     emergency room-making is useless in a stalled/critical/wrong-reveal state. Agree with Round-1
     finding #1: keep a **defensive-recovery** capability gated to the critical regime; reject dig-for-count.
  2. **Scope of what the corpus CAN benchmark for v3 — important:** my static replays measure ⑤ mechanics
     (technique/chain-depth/combo-width dists), **STYLE** (clone targets), and **throughput DIAGNOSTICS**
     (blocks/min etc. — now correctly demoted). They **cannot** benchmark the contested axes ①②③④⑥⑦
     (win/effective-pressure/tactical-timing/contested-survival/robustness/reading) — those need the
     bot's reacting-opponent *league*, not my replays. So don't expect human numbers from me for the
     interaction axes; I supply mechanics + style + diagnostics.
  3. **Round-1 finding #2 (strict-better unproven for INTERACTION ③/⑦): the new reason is stronger than my
     original Pareto one** — and it compounds a measurement reality: I can't even establish a *human*
     benchmark for read-and-respond from static replays. So on ③/⑦, "strict-better than human" is both
     hard to build AND hard to measure. User's call on the bar; flagging the measurement gap. Signed off. — data
- **B track:** ☑ **APPROVE v3** — with 4 concrete notes from the receding-horizon solver I just built
  (`puzzleSolveTimed.lua`, HORIZON/BEAM modes). These are *earned*, not theoretical — I hit each one.

  **1. RECEDING-HORIZON is the right architecture — confirmed empirically.** The user's "think 3 ahead,
  re-plan, repeat" reframe is exactly what cracked the deep insert lines for me conceptually: a depth-3
  re-plan loop reaches depth-9 play at ~3×(depth-3 cost) instead of 14⁹. `puzzleSolveTimed` is the
  finite-horizon one-shot; the doc's "receding-horizon makes it LIVE" is correct and it genuinely
  subsumes my work. ✅

  **2. ⚠️ DON'T hard-commit frame-1's single best move — keep a BEAM.** The sharpest lesson: pure greedy
  MPC (re-plan, commit the ONE best-progress move, repeat) walks into local optima — it commits down a
  line that *looks* like progress (panels dropping) and dead-ends, because one wrong catch-column poisons
  the rest of the chain. Fix that worked: keep K candidate boards alive (beam), re-plan from each, let
  dead-ends fall out. **Architectural ask:** the live MPC loop should carry a small beam of candidate
  break→setup→chain plans across frames, NOT collapse to a single committed plan each frame. Otherwise ③
  tactical-timing will be brittle — the first plausible-looking send wins and the better-timed one is
  never explored.

  **3. ⚠️ The horizon MUST span ≥ one full cascade (~60-78f @ L10), or you're back to greedy 1-ply.** The
  whole reason 1-ply caps at ~8 sends/min (doc's number) is that a catch's payoff lands one cascade later
  and a short horizon can't see it. My corpus proves catch timing is **bimodal**: a swap fires either
  immediately (W≈0-2) or after one full cascade (W≈60-78), *never* the dead middle. So the planner's
  lookahead has to reach ~78 frames of *simulated* play to value a setup, even though it only commits the
  next move. Cost-function horizon ≠ commit cadence — set the sim horizon long, commit short.

  **4. How live offense consumes the `(W,r,c)` lines + `chainEnded` edges** (your ASK):
  - **Don't replay stored `(W,r,c)` lines as scripts** — `W` is *relative to the live cascade*, which the
    opponent's garbage perturbs. RE-DERIVE the catch each replan from the live board (same event-driven
    candidate gen: only consider swaps on frames where the board signature just changed). The stored lines
    in `bot/fixtures/insert_catches.json` are best used as (a) regression fixtures and (b) a prior to SEED
    move-gen ordering, not as fixed tactics.
  - **`W` is your ③ tactical-timing lever.** Mine extends my own chain; live, the same `W` shifts *when my
    chain fires*. So the planner tunes `W` against the OPPONENT's `chainEnded`/vulnerable edge — pick the
    catch timing that lands my send in their low-invincibility window, not just the one that maximizes my
    chain. That makes ③ fall out of the same search, exactly as the doc claims.
  - **Feed both edge streams into the cost function:** my-board `chainEnded` = when my stop-time window
    opens (setup *inside* it); opponent-board `chainEnded` = the counter-window to fire INTO. The bimodal-W
    prior keeps move-gen inside the 60Hz budget.

  **No blocking changes.** On the two ⚠️ USER-rulings (re-scope dig; strict-better-on-interaction): both are
  the user's call, not mine — but I agree with the *substance* of Round-1 finding #2 (timing/reading is
  read-and-respond; from the solver side, "strict-better" on ③/⑦ is the part that needs the reacting-opponent
  league to even measure, which my puzzle bench can't provide). Signed off. — B

Once BOTH approve, bot track runs the agreed version by the user for final lock. Not before.
