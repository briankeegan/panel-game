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
| `useChips` (catalog chip recognition) | `bot/useChipsTest.lua` (FIXED this session — crashed on default invocation, missing `DEFAULT_PRIORITIES` export) | VERIFY mode 100% precision by construction; **coverage only 58%** (23/40 puzzle boards yield nothing playable) — root-caused 2026-07-03, see item #6 below |
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
6. ~~**`useChips` coverage gap`**~~ — UNDERSTOOD (2026-07-03). The 42% decomposes into two
   distinct causes, neither of which is the search band or touchable gating:
   - **8/40 (20%): recognition finds nothing, but NONE of those boards is dead** — brute
     force shows 2 have a 1-swap clear and 6 have a 2-swap clear. All the misses are the
     same missing template family: **pull-into-empty drop clears** (swap a panel into an
     adjacent empty cell so its column compacts into a 3-match — e.g. board 11: pulling
     the 1 out of c3r1 drops the 4 into a 4-4-4 row). The catalog has no such shape.
   - **9/40 (22%): recognition returns a chip but engine-verify rejects every candidate**
     (NO-VERIFY precision is only 59%). Root-caused examples (boards 21/29/30): the
     recognizer proposes swaps whose own `BoardSim.simSwap` predicts total=0 — templates
     assume a panel stays where it's swapped, but it falls through an empty column. A
     cheap exact post-filter (simSwap on the proposed sequence, engine-proven 0/941)
     would kill these false positives without a full engine verify.
   - Fix candidates (deliberately NOT slipped in; each shifts live behavior and needs its
     own sweep): (a) author the drop-clear template family, (b) simSwap post-filter in
     `chips.recognize`, (c) exact 1-swap fallback scan when the catalog returns nothing.
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

## Where survival stands and why it still dies

10-seed 6x12 protocol (`PA_SEED_BASE=1000, 600 3600 10 "" hard 6 12`): median ~22s,
holdout window (2001-2010) ~22.1s — vs 11.6s at session start. Two failure modes remain:

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
