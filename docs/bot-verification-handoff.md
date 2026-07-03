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
| `useChips` (catalog chip recognition) | `bot/useChipsTest.lua` (FIXED this session — crashed on default invocation, missing `DEFAULT_PRIORITIES` export) | VERIFY mode 100% precision by construction; **coverage only 58%** (23/40 puzzle boards yield nothing playable) — a real, open gap |

### NOT yet individually verified (the finishing-swing list, priority order)

1. **`catchPrimitive.stageContact`** — no dedicated real-engine test. Fixed twice this
   session by sweep-trace (anti-ping-pong donor guard, tied-column scan) but never proven
   in isolation: "given board X, staging converges to a cocked contact trigger in N swaps,
   monotonically, on the real engine."
2. **`catchPrimitive.stageTrigger`** — same. Its TRIGGER_TARGET overshoot fix (2-pass count)
   is code-audit-only, never exercised.
3. **`catchPrimitive.catchSlide`** — the completability gate added this session is verified
   only by sweep deltas. Needs an isolated test: donor exists → converges & catch fires on
   real engine; no donor → returns nil immediately.
4. **`BoardSim.digPlan`** — wired into the LIVE sealed-dig branch this session with no
   dedicated test. Needs: boards where a known 2-3 swap dig exists → digPlan's moves,
   played on the real engine, actually break garbage.
5. **`useChips.planMove` end-to-end** — re-measure with the FIXED quiescence-based
   `PA_PLANVERIFY` (the old numbers are void). One `DID-NOT-MATERIALIZE` at
   framesWaited=33 appeared in the re-measure sample; unexplained, uninvestigated.
6. **`useChips` coverage gap** — 42% of puzzle boards return no chip even unverified.
   Understand why (template set too narrow? search band? touchable gating?).
7. **POP-NOW guard** (`EnvelopeBrain` sealed branch) — semantically justified, never
   observed firing. Either construct the board state that exercises it or accept it as
   dead code and remove it.
8. **Lull shield + stageContact protections** (`EnvelopeBrain` lull branch) — verified only
   by sweep aggregates (cocked-at-landing 1/10 → 6/10), not in isolation.

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

- Work branch: `claude/bot-building-hpom4o`, fully pushed.
- Everything is merged into **`bramp/multi-player`** (the fork's mainline — `beta` is the
  upstream default but shares NO git history with this fork's branches; do not merge there).
- All suites green at HEAD; survivalStress DETERMINISM and CONSTRUCTION PARITY both PASS.

## Task tracker

- #3 (10-seed median → 5 min) — BLOCKED by design until the piece list above is green.
- #7 (catch completion rate) — the live umbrella task; the "NOT yet verified" list is its
  current concrete content.
