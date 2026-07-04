# Bot Handoff — 2026-07-03

## The goal (owner's words, do not lose this)

**"Working" means the bot survives INDEFINITELY against big garbage blocks** (the
`large_garbage` practice regime: 6-wide x 12-tall block injected every 600 frames, level-10
hard). The 180s benchmark in `survivalStress` is a milestone, not the goal — a bot whose
mechanics all truly work sustains the dig loop forever. Current 10-seed median: **~22s**.
So the functionality is NOT done, and the remaining work is a finishing swing on
functionality, not tuning.

## The method (non-negotiable, owner has re-stated this repeatedly)

1. **Test each piece INDIVIDUALLY, in isolation**, before any integration work or sweeps.
2. **Verify against the REAL engine ONLY** (`Puzzle`/`Match`/`Stack` — never a standalone
   reimplementation, never a simulator checking a simulator). A test that doesn't construct
   a real engine proves nothing about physics; don't bother with it.
3. **Only after ALL pieces work separately** move to integration (10-seed sweeps, median
   survival, tuning). Sweeps are the LAST step, not a debugging tool.
4. **When measuring the real engine, wait for TRUE QUIESCENCE** — 20 consecutive frames with
   no active/chaining panels and no panel-count change — never a fixed frame budget. This
   session found TWO long-standing "bot bugs" that were actually measurement-timeout
   artifacts (see "Corrected record" below). A deadline-based engine check is worthless.

## Corrected record — the "deep-chain phantom" is DEAD (2026-07-03)

The codebase carried a doctrine that `BoardSim`'s chain predictions past link 1 were
unreliable ("DEEP-CHAIN PHANTOM": engine settles wave-by-wave, simulator full-settles).
This drove a live `TRUSTED_CHAIN_CAP=1` in `useChips.scoreSwap` and a cap in `digPlan`.
**It was false.** Both pieces of "evidence" were the same measurement bug:

- `bot/tests/boardSimVerify.lua` waited only 200 frames / 3 quiet frames for the engine —
  a real 3-link chain's FLASH(28) + per-panel POP stagger takes longer. Its 11/941
  "phantom" residual was measured MID-CASCADE. Fixed to quiescence-wait: **0/941 mismatch,
  uncapped, all depths.**
- The live `PA_PLANVERIFY` diagnostic checked at a flat 90 frames since decision COMMIT
  (before travel+reaction+fire even finish). Its "13/13 chain>=2 predictions wrong" was the
  same artifact. Fixed to quiescence-wait.

`TRUSTED_CHAIN_CAP` and `digPlan`'s cap are retired (PA_TRUSTLINK/PA_MAXLINK remain as
override knobs only). Any doc/comment still citing the phantom as real is stale — the
authoritative statement is in `bot/useChips.lua` above `TRUSTED_CHAIN_CAP` and in
`bot/BoardSim.lua`'s `resolve()`.

**Third strike (2026-07-03):** `useChipsTest.fired()`'s flat 80-frame settle was the same
bug class — 5 frames short of a slow multi-clear's first panel removal — and produced
the "41% recognition false positives / 58% VERIFY coverage" numbers. Fixed to
quiescence; see item #6. Treat ANY fixed frame budget around the engine as guilty until
proven quiescent.

**Consequence for the handoff:** every old "planMove hit rate 76%" / "still-unexplained
miss" number in prior versions of this doc was produced by the buggy 90-frame window and is
void. A quiescence-based re-measure of a 3-seed run showed ~17/18 MATCHED.

## Piece-by-piece status

### Verified on the real engine (green)

| Piece | Test | Result |
|---|---|---|
| `BoardSim.simSwap` (swap→gravity→match→cascade prediction) | `bot/tests/boardSimVerify.lua` | 0/941 mismatch over 40 random boards, uncapped depth |
| `chainSim.simChain` (chain-depth prediction) | `bot/tests/chainSimVerify.lua` (NEW this session — `bestChain` fired live with zero coverage before) | 0/379 mismatch over 40 boards |
| `chainSim.engineChain` (the real-engine repro helper itself) | fixed + exercised by chainSimVerify | had a board-loading bug: fixed-12-row padded puzzle strings scramble PuzzleSource's row mapping; must trim to occupied height |
| catch primitives: `catchRoute`, `findTopOff`, `buildPair`, `flattenMove`, `breakRoute`, `garbageReveal`, `findCatch`, `dropETA` | `bot/tests/catchVerify.lua` | 8/8 OK |
| `CursorController` (decision→input→engine execution) | `bot/tests/executorVerify.lua` | OK (clear fires, plain swap exchanges) |
| `useChips` (catalog chip recognition) | `bot/useChipsTest.lua` (harness settle fixed to quiescence 2026-07-03; simSwap pre-filter added to `chips.recognize`) | **100% precision in BOTH modes; VERIFY coverage 68%** (was 58% — the old number mixed in a harness frame-budget artifact); remaining gap root-caused, see item #6 below |
| `catchPrimitive.stageContact` / `stageTrigger` / `catchSlide` | `bot/tests/stageVerify.lua` (NEW 2026-07-03) | 8/8: convergence, tied-scan, donor guard, TRIGGER_TARGET cap, slide-stage + real fire, both completability gates; mutation-checked |
| `BoardSim.digPlan` | `bot/tests/digPlanVerify.lua` (NEW 2026-07-03) | 4/4 known-depth boards break on the engine; caught + fixed a beam-pruning bug (spread digs) |
| POP-NOW guard (`EnvelopeBrain` sealed branch) | `bot/tests/popNowVerify.lua` (NEW 2026-07-03) | fires CLEAR at stop_time=0, dormant at 90, clear pops on engine; caught + fixed the dead COMBO_3-append |
| Lull shield + contact-first staging | `bot/tests/lullShieldVerify.lua` (NEW 2026-07-03) | exact mask, no staged-cell swaps over live lull play, BRACE_CONTACT preempts clears; under-mining hole documented |

### NOT yet individually verified (the finishing-swing list, priority order)

1. ~~**`catchPrimitive.stageContact`**~~ — DONE (2026-07-03): `bot/tests/stageVerify.lua`
   proves monotone convergence to a cocked contact trigger (2 swaps then idles), the
   tied-column scan, and the anti-ping-pong donor guard, all on the real engine.
   Mutation-checked (disabling the guard / the 2-pass count fails the suite).
2. ~~**`catchPrimitive.stageTrigger`**~~ — DONE (same file): monotone convergence, pair
   never fired early, and the TRIGGER_TARGET cap with cocked columns at HIGHER indices
   than the routable one (the exact overshoot order), plus routing resumes above the cap.
3. ~~**`catchPrimitive.catchSlide`**~~ — DONE (same file): 4 monotone slides stage both
   cells, then a real finisher swap pops the vertical-3 on the engine; no-donor board
   refused immediately; donor behind an unsupported hole refused.
4. ~~**`BoardSim.digPlan`**~~ — DONE (2026-07-03): `bot/tests/digPlanVerify.lua` — known
   min-depth boards (1/2/3 swaps by construction), real garbage via the receive path,
   plans played on the engine with re-planning per swap. **Caught a real bug**: the beam
   pruned spread-out digs (fives at c1/c4/c6 → nil) because the progress heuristic only
   rewarded adjacent pairs, so the first gather slide looked like a pure shuffle. Fixed
   with a tightest-triple span term in `digPlan`'s `progress()`; the depth-3 plan is now
   found and re-plans shrink 3→2→1. 10-seed sweep after the fix: median 22.0s (no change).
5. ~~**`useChips.planMove` end-to-end`**~~ — DONE (2026-07-03): 10-seed re-measure with the
   fixed quiescence `PA_PLANVERIFY` + `PA_FIRECHECK` + `PA_CURSORDIAG`: **44 tracked plan
   commits, 42 MATCHED, 2 DID-NOT-MATERIALIZE (95.5%)**. Both misses are EXPLAINED:
   FIRECHECK shows simSwap itself predicted total=0 for the same swap AT FIRE TIME — the
   board shifted during cursor travel (decision→execution staleness), not a prediction
   bug. The old "unexplained framesWaited=33" signature is exactly this: the stale swap
   fires fast, clears nothing, controller idles ~33f after commit. Every tracked fire
   where FIRECHECK still predicted a clear materialized. Caveat for future readers: 299
   of 429 raw PLAN fires log FIRECHECK total=0, but most are the known decide-cache
   re-fires and mid-animation conservatism (colorGrid marks moving cells RESOLVING), NOT
   tracked commits — do not read that number as a 70% miss rate. A fire-time re-validate
   (abandon PLAN swaps that predict 0 at fire) was considered and deliberately NOT added:
   a transient mid-cascade 0 could abandon a swap that would still clear; needs its own
   isolated study first.
6. ~~**`useChips` coverage gap`**~~ — UNDERSTOOD and PARTLY FIXED (2026-07-03). The
   original "42% / 59%-precision" picture decomposed into THREE causes, none of which is
   the search band or touchable gating:
   - **Measurement artifact (fixed)**: `useChipsTest.fired()` used a flat 80-frame
     settle — 5 frames short of a real COMBO_3_3's first panel-clear (measured k=85 on
     puzzle board 3; 6 matched panels flash+stagger). Every slow multi-clear chip read
     as "didn't fire", inflating false-positive counts AND silently rejecting REAL chips
     in VERIFY mode. Fixed to quiescence (rule 4 — struck a THIRD time; see Corrected
     record). The live `EnvelopeBrain:chipVerify` does NOT have this bug class for
     single swaps (it exits on the `matched` signal, same-frame as detection); its
     20-frame between-swap settle for multi-swap chips is a theoretical under-wait,
     noted as a watch item, no demonstrated failure.
   - **Real recognition false positives (fixed)**: templates that swap a panel into an
     empty column and assume it stays put while it falls to the floor (boards 21/29/30:
     the recognizer's own `BoardSim.simSwap` predicts total=0 for its proposed swap).
     Fixed with an exact pre-filter in `chips.recognize`: simulate the whole swap
     sequence with BoardSim (0/941 vs engine, settling between swaps like the executor)
     and drop candidates whose own sim says nothing clears. Engine verify remains the
     final authority when present — the filter just stops burning live verify calls
     (swap + rewind each) on dead chips.
   - **After both fixes: 100% precision in BOTH modes; VERIFY coverage 58% → 68%**
     (23→27 of 40 boards; per-kind all 100%). The remaining no-chip boards are the
     genuine template-family gap: brute force shows none are dead — the misses are
     **pull-into-empty drop clears** (swap a panel into an adjacent empty cell so its
     column compacts into a 3-match, e.g. board 11) and 2-swap setups of the same shape.
   - **Exact 1-swap fallback (added 2026-07-03, opt-in)**: `useChips` can now scan the
     cursor-ordered cells with `simSwap` when the catalog's COMBO_3 slot comes up empty —
     recognizer CEILING is **85% coverage / 100% precision in both modes** (the last 6
     boards need 2-swap setups). Scope lesson, paired 10-seed sweep: enabled globally it
     fired on exactly ONE live path (findCatch's catalog scan, seed 1003) and came out
     2.2s WORSE there — the catch window is timing-sensitive, so a newly-visible bare 3
     is not automatically a good catch. Now `opts.exactFallback`: ON for POP-NOW (any
     pop beats a still frame at stop 0) and the corpus test; OFF elsewhere. Sweep with
     this scoping: per-seed byte-identical to baseline. Catch-path enablement is a
     recorded tuning-phase candidate; the drop-clear template family (a) remains open
     for the multi-swap shapes.
7. ~~**POP-NOW guard**~~ — DONE (2026-07-03): `bot/tests/popNowVerify.lua` constructs the
   exact state (sealed block, bare stop clock, breakRoute = non-popping routing step,
   plain 3-clear available) and **caught the real reason it never fired**: extractByMeta's
   "COMBO_3 pinned dead-last in every state" was dead code (the isExcluded gate ran
   first), so OFFENSE/DANGER lists never contained the bare 3-clear POP-NOW needs.
   Making COMBO_3 reachable EVERYWHERE was measured WORSE (10-seed median 22.0s→17.4s —
   the bot mines its own break material with cheap 3s), so the fix is a targeted opt-in:
   POPNOW_PRIORITIES (ready-first + COMBO_3 last) used ONLY by the guard. Verified:
   stop_time=0 → CLEAR fires and pops on the engine; stop_time=90 → BREAK_ROUTE, guard
   dormant. Sweep after fix: median 22.0s (baseline restored).
8. ~~**Lull shield + stageContact protections**~~ — DONE (2026-07-03):
   `bot/tests/lullShieldVerify.lua`. The shield builder is extracted as pure
   `EnvelopeBrain.lullShield` and unit-tested: masks EXACTLY the intact top pair + its
   cocked trigger cell. Behaviorally: 6 successive live lull decisions never swap a
   staged cell, and BRACE_CONTACT preempts a ready clear and cocks the contact column in
   one step with the pair intact. **New KNOWN HOLE found**: the shield is cell-level
   only — lull PLANs may clear panels UNDER the pair column, dropping the whole stage by
   gravity (observed live in the test: pair rode down 3 rows, never swapped). The 6/10
   cocked-at-landing sweep number includes this hole; extending the shield to the pair
   column's support cells is a candidate improvement needing its own sweep validation.

### Deliberately non-engine (do NOT mistake these for physics verification)

`bot/tests/BoardStateTest.lua` (garbage-queue field mapping) and
`bot/tests/GarbageApplyTest.lua` (network G-message routing) use mocked inputs on purpose —
they test data plumbing, make no claim about engine physics, and are kept.

## Tuning-phase opening analysis (2026-07-03, post-verification)

PA_MECH baseline at HEAD, dev seeds 1001-1010 + holdout 2001-2010 (20 seeds):

- **9/20 seeds die with reveals=0 — the first block is NEVER broken** (dev: 1001/1004/1005/1006; holdout: 2001/2003/2004/2009/2010). These are all
  first-landing deaths (garbInjected=1). Catch-completion tuning cannot touch them; the
  first-break problem strictly dominates.
- On seeds that do break: catch completion 50-100% (dev), 0-75% (holdout); re-break
  latency is 4-7f when the catch completes vs 91-185f when it doesn't — confirming
  "catch completion rate is the game" for the seeds that get past landing one.
- **Seed-1001 anatomy (hard proof)**: at death the block sat on column heights
  5,5,2,3,4,5 (c3/c4 mined hollow during the lull). digPlan correctly returned nil at
  every depth 1-6, and an EXHAUSTIVE whole-board search (all rows, not just digPlan's
  window) proves **no ≤3-swap break existed at all**. The post-landing mechanics are
  innocent; the lull delivered an unbreakable board.
- Causal chain: lull PLAN under-mining (the shield hole documented in item #8) →
  hollow/jagged landing board → no break exists → death ~90f after landing.
- **Primary metric for the next interventions: zero-reveal seed count (now 9/20).**
  Candidates, in leverage order: (1) extend the lull shield to the staged pair's column
  SUPPORT cells; (2) a per-COLUMN material floor in the lull (avgH gates let two columns
  go hollow while the average looks fine); (3) catch-path exactFallback (recorded
  earlier). Each gated by paired dev+holdout sweeps.

**Candidate (1) MEASURED (2026-07-03) — mechanism proven, landed as a default-OFF knob
(`PA_LULLSUPPORT=1` / `EnvelopeBrain.LULL_SUPPORT_SHIELD`):**

| variant | dev zero-reveal | dev median/mean | dev broken | holdout zero-reveal | holdout median/mean |
|---|---|---|---|---|---|
| baseline | 4/10 | 22.0 / 22.2 | 72 | 5/10 | 20.5 / 24.4 |
| support shield, every pair | 1/10 | 21.9 / 22.3 | 138 | 5/10 (set changed) | 18.0 / 16.9 |
| support shield, contact col only | **0/10** | **25.6 / 25.7** (p10 16.9!) | **141** | 5/10 (set changed) | 15.2 / 18.4 |

The contact-column variant eliminates dev first-landing deaths entirely and doubles
garbage broken — the seed-1001 causal chain is confirmed end to end. But BOTH variants
regress the holdout window. **Seed-2006 root cause (2026-07-03)**: pair mask + support
mask together make the contact column COMPLETELY untouchable, so the rise grows it into
a runaway tower — 2006 died at first landing on heights 4,5,1,4,6,7 with the block
resting on the lone c6 tip (OFF-baseline survives 48.2s there; mining was the tower's
relief valve). A **v2 spread release** (column fully released once maxT ≥ second+2,
`lullShieldVerify` PIECE 1b) fixes the total lockup but NOT the regression:

| variant (knob ON) | dev med/mean (broken, zero-reveal) | holdout med/mean (broken, zero-reveal) |
|---|---|---|
| baseline (knob OFF) | 22.0 / 22.2 (72, 4) | 20.5 / 24.4 (69, 5) |
| v1 contact-only support mask | 25.6 / 25.7 (141, **0**) | 15.2 / 18.4 (36, 5) |
| v2 + spread release | 24.5 / 22.1 (138, 2) | 16.6 / 18.7 (36, 6) |

Even with the release, 2006 arrives at injection with spread=3 and avgH=5.0 — the
masked lull clears less overall, so the board rides HIGHER and lands jagged anyway.
Conclusion: hard NO-GO masking of the stage conflicts with the flat-low posture on
tall-lull seeds. The default stays OFF (baseline byte-identical, verified).

**Mode 2 (transit-only lock, PA_LULLSUPPORT=2) also MEASURED (2026-07-03): a no-op.**
Locking the stage only while a block is announced (pendingBig ≥ 3, the ~120-frame
transit+telegraph window) produced sweeps byte-identical to baseline on dev, holdout
AND seed 2006 — the stage-sinking mining happens EARLIER in the lull, before the
announcement, so a transit gate locks the barn after the horse. The cheap-variant
space is now exhausted; what remains is real design work:
(a) soft cost in PLAN/CLEAR scoring for stage/support cells instead of hard masks —
    keeps clear throughput while steering mining elsewhere; the most promising.
(c) per-column material floor (candidate 2) — attacks the hollow-columns half
    (seed-1001 class) without touching stage protection at all.
Both need planMove-internal changes (scoring), not another mask variant.

**Mode 3 (SOFT sink cost, option a) MEASURED 2026-07-04 — WINS, now the DEFAULT.**
Implementation: `useChips.planMove` takes `opts.sinkCols/sinkW` and charges sinkW per
row a candidate board drops a protected column (never forbids the swap); lull CLEAR
tries the support-locked mask first and FALLS BACK to the plain pair shield, so a
clear is never lost, only steered; `lullShield` returns its locked contact columns as
a 2nd value (nil under the spread release, so the soft cost obeys the same overheight
relief valve). Unit-proven in `lullShieldVerify` PIECE 4 (cost flips a strictly-better
sinking chain clear to the rival; the only-clear board still fires at default weight).

| variant | dev median/mean (zero-rev, broken med) | holdout median/mean (zero-rev, broken med) |
|---|---|---|
| mode 0 (old baseline) | 22.0 / 22.2 (4/10, 72) | 20.5 / 24.4 (5/10, 69) |
| mode 1 hard mask | 25.6 / 25.7 (0/10, 141) | 15.2 / 18.4 (5/10, 36) |
| **mode 3 soft, sinkW=120** | **25.5 / 26.9 (3/10, 105)** | **22.9 / 24.0 (4/10, 105)** |

First variant with a dev win and NO holdout regression: zero-reveal 9/20 → 7/20 (the
primary metric), both medians up, holdout mean flat. Seed 2006 lands at 30.3s (down
from its 48.2s mode-0 outlier but no longer collapsing the window; it breaks 138 and
gets 2 reveals — not a zero-reveal death). sinkW swept {60,120,250}: a flat plateau
on both windows (dev 23.9/25.5/23.9, holdout 22.9/22.9/21.6 median) — the mechanism
(losing ties, keeping wins) does the work, not the weight. `PA_LULLSUPPORT=0` recovers
the old baseline byte-identically (verified pre-flip on a 3-seed sweep); the env-unset
default was verified to reproduce the measured mode-3 sweep exactly.
**Candidate (c) PLAN-side floor MEASURED (2026-07-04): NO-GO.** The remaining 7/20
zero-reveal seeds under mode 3 split into hollow/jagged injection postures (1006:
7,7,6,1,3,3; 2001: 4,4,3,2,5,6; 2003: 6,5,2,5,4,5; 2010: 7,6,3,3,3,5) and rides-high
(2009: avgH 6.5) — so the floor had real targets. Implemented as `opts.floorH/floorW`
in the same planMove soft-cost slot (absolute deficit, so refilling pays; knobs
`PA_LULLFLOOR`/`PA_FLOORW`, default OFF; unit piece 5): floor=2 was BYTE-IDENTICAL to
mode 3 on both windows (never flips a decision), floor=3 REGRESSED both (dev median
25.5 → 19.1: seeds 1003/1007 collapsed to zero reveals; holdout 22.9 → 18.0: 2006
30.3s → 12.6s). Same signature as the mode-1 hard mask: taxing every clear near short
columns starves lull throughput. Lesson recorded: PLAN-side scoring pressure on
material retention consistently backfires; the win pattern is CLEAR TRY-ORDERING
(prefer-then-fallback, zero throughput cost). `PA_FLOORCLEAR=N` (default OFF) is that
variant for short columns — mask columns at height <= N in the lull CLEAR's first
attempt only (`EnvelopeBrain.floorMask`, unit piece 6).

**PA_FLOORCLEAR MEASURED (2026-07-04): byte-identical NO-OP at floors 2 AND 3, both
windows** — the preferred (short-column-sparing) clear is always the same chip the
unmasked call picks anyway. Combined verdict on the floor family: the hollow injection
postures are NOT created by lull CLEAR chip choice, and PLAN-side retention pressure
only starves throughput. The hollow columns must come from elsewhere — cascade
side-effects of legitimate clears, FLATTEN routing, or simply never being filled
(RAISE adds uniform rows; nothing preferentially rebuilds a low column). **Next step
recorded: hollow-column PROVENANCE trace** — instrument seeds 1006/2003 (clear
hollow-at-injection cases) with a per-decision column-height delta log attributing
each drop of an already-low column to the substate that caused it (CLEAR/PLAN/FLATTEN/
cascade), then design against the actual mechanism instead of guessing a third time.
All three floor knobs stay (default OFF) as measured negative results.

**PROVENANCE TRACE RUN (2026-07-04, `PA_HOLLOW` in survivalStress):** seed 1006's
fatal hollowing (c4 4→1, injection tops 7,7,6,1,3,3) is a lull **PLAN** clear at
f580-594 — 6-20 frames BEFORE the f600 injection. The culprit substate is PLAN
throughout (not CLEAR chips — consistent with PA_FLOORCLEAR's no-op), and the fatal
window is PRE-announcement. Follow-ups measured:
- `PA_TRANSITHOLD=1` (keepMaterial in the lull PLAN while pendingBig ≥ 3): NO-OP,
  byte-identical both windows. Structural: harness blocks land ~40-50f after
  announcement, so no lull decision ever sees pendingBig ≥ 3 before a first landing.
  This also fully explains shield mode 2's no-op.
- `PA_TRANSITHOLD=2` (keepMaterial ALL lull long in a big-garbage game): seed-1006
  probe — c4 stays filled (4 not 1) but the board rides to avgH 7.0 (vs 4.5) and dies
  SOONER (13.4s vs 16.1s). Devaluing immediate clears starves the rise-fight.
**Standing conclusion:** pre-announcement strip-mining cannot be fixed by scoring-level
material retention (three knob families now agree); the first-landing hollow problem
needs CONTEXT-AWARE targeting — e.g. only tax a clear when the board is short enough
that the rise-fight doesn't need it, or make the lull PLAN prefer clears whose panels
come from ABOVE-average columns at equal reward (a tie-order, not a tax; the win
pattern from mode 3). Both untried. The rides-high failure class (seed 2009, avgH 6.5
at injection) is the OPPOSITE failure and any material-retention change must be
sanity-checked against it.

## Where survival stands and why it still dies

10-seed 6x12 protocol (`PA_SEED_BASE=1000, 600 3600 10 "" hard 6 12`): dev median 25.5s
(mean 26.9), holdout window (2001-2010) median 22.9s (mean 24.0) — vs 11.6s at the
2026-07-03 session start (numbers as of the 2026-07-04 mode-3 default flip). Two
failure modes remain:

1. **First-landing deaths (~4/10 seeds)**: at the moment the block lands, the board offers
   no pop and no ≤2-swap break; with garbage over the top, health drains every still frame
   at stop_time 0, so the bot dies ~50-150f after landing mid-setup. Partially mitigated by
   the lull shield (staged pairs survive to landing on 6/10 seeds now), but a cocked
   trigger doesn't reliably convert (collateral clears mid-telegraph, mid-pop holes).
2. **Sustain rate**: survivors break ~1 garbage row per ~250 frames; indefinite survival
   needs ~1 per 50. The loop is break → reveal → CATCH → re-break; when the catch completes,
   re-break latency is 5-30f (self-sustaining); catch completion per reveal is only
   33-100% depending on seed. **Catch completion rate is the game** (task #7).

Physics constraint that shapes everything (level 10, maxHealth=1): with garbage over the
top row, ONE still frame at stop_time 0 kills. Survival = keep something popping every
frame. Plain 3-clears don't bank stop time; only 4+ combos and chains do.

## How to run (headless, real engine, no love needed)

```sh
luajit bot/tests/boardSimVerify.lua        # BoardSim vs engine
luajit bot/tests/chainSimVerify.lua        # chainSim vs engine
luajit bot/tests/catchVerify.lua           # 8 catch primitives
luajit bot/tests/executorVerify.lua        # controller execution
luajit bot/tests/stageVerify.lua           # stageContact / stageTrigger / catchSlide (NEW 2026-07-03)
luajit bot/tests/digPlanVerify.lua         # digPlan plans break garbage on the engine (NEW 2026-07-03)
luajit bot/tests/popNowVerify.lua          # POP-NOW guard fires on a bare stop clock (NEW 2026-07-03)
luajit bot/tests/lullShieldVerify.lua      # lull shield mask + contact-first staging (NEW 2026-07-03)
luajit bot/useChipsTest.lua 40             # chip recognition precision/coverage
luajit serverTestRunner.lua                # full server suite (unrelated but keep green)
# integration sweep — LAST, only after pieces pass:
PA_SEED_BASE=1000 luajit bot/survivalStress.lua 600 3600 10 "" hard 6 12
```

Diagnostics: the `PA_*` env vars are catalogued in git history of this file (previous
revision) and inline where each is read; the important ones are `PA_MECH`, `PA_PLANVERIFY`
(now quiescence-based), `PA_STAGEDIAG`, `PA_CATCHDIAG`, `PA_ROUTEDIAG`, `PA_GRID`,
`PA_DEATH`, `PA_CURSORDIAG`, `PA_FIRECHECK`.

Pitfalls that burned this session — check these before "discovering" a bug:
- Fixed frame budgets when watching the engine (use quiescence, rule 4 above).
- Puzzle strings must be trimmed to occupied height (padding scrambles row mapping).
- `Stack.chain_counter` starts at 2 for the first cascade link (0 = plain combo); a
  simulator "depth" that counts the first match is off-by-one against it at depth 1.
- The pre-game countdown (~188f) refuses ALL swaps; the decide-cache re-fires the same
  cached move ~8x through it. Cosmetic, known, not a bug.

## Git state

- Work branches: `claude/bot-building-hpom4o` (previous session) and
  `claude/bot-verification-handoff-w7b53s` (2026-07-03 session, this doc's items #1-#8),
  both fully pushed.
- Prior work is merged into **`bramp/multi-player`** (the fork's mainline — `beta` is the
  upstream default but shares NO git history with this fork's branches; do not merge there).
- All suites green at HEAD (now 8 bot suites — see run list above); 10-seed sweep at
  HEAD: median 22.0s (unchanged from session start; this session was verification, not
  tuning).

## Task tracker

- The 2026-07-03 finishing-swing list (#1-#8 above) is COMPLETE: every piece is either
  proven in isolation on the real engine or root-caused with fix candidates recorded.
- #3 (10-seed median → 5 min) — UNBLOCKED. The verified-piece prerequisites are met;
  integration/tuning sweeps are now the legitimate next step.
- #7 (catch completion rate) — the live umbrella task. Highest-leverage recorded leads:
  the useChips drop-clear template family + simSwap post-filter (item #6), and the lull
  shield under-mining hole (item #8).

**Drop-clear template family RE-EXAMINED (2026-07-04): lead is DEAD under measured
policy — do not build it.** Catalog-only corpus coverage is 27/40; the 13 misses split
7 one-swap drop clears (all covered by `exactOneSwap` where opted in) + 6 two-swap
setups. Tracing the consumers: (1) POP-NOW already gets every 1-swap drop via
exactFallback, and 2-swap setups can't serve POP-NOW (the first swap doesn't pop);
(2) OFFENSE/DANGER deliberately exclude bare-3 kinds (measured 22.0→17.4s when
allowed — the bot mines its own break material), and a drop-clear kind is bare-3
material by construction: named `COMBO_3_*` it's policy-excluded everywhere, named
anything else it leaks into OFFENSE/DANGER against that measurement; (3) the catch
path measured 2.2s worse with fallback-surfaced bare 3s. So templates would improve a
recognizer-ceiling metric (corpus coverage) with NO live consumer. The corpus 85%
number already reflects the ceiling via the test's own exactFallback opt-in.
