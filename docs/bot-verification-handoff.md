# Bot Verification Handoff — 2026-07-02

## Goal (do not lose this)

The bot needs to survive longer against the "large_garbage" practice mode. The
explicit, standing instruction from the project owner is:

> Before tweaking numbers or running sweeps, go through EVERY mechanic
> ("knob") one by one and verify it actually does what it's supposed to do,
> using hard single-seed instrumentation — not statistics, not curve-fitting.
> Only once every individual piece is verified correct do we move to
> generalization/tuning (sweeping seeds, chasing median survival time).

Do **not** jump to running 10-seed sweeps or tuning parameters until the
piece-by-piece verification below is complete. This has been explicitly
re-stated by the owner multiple times when an in-progress sweep was
interrupted.

## How to reproduce / tools

- Single-seed real-engine trace: `luajit bot/survivalStress.lua <maxFrames> <injectPeriod> <numSeeds> "" hard 6 12`
  with `PA_SEED_BASE=<seed>` to pin one seed, plus diagnostic env vars (see below).
- Key diagnostic env vars already wired into the code:
  - `PA_MECH=1` — per-seed mechanic counters (reveals, breakEvents, catchDone, rebreakLat)
  - `PA_ROUTEDIAG=1` — prints `breakRoute`'s eligible-column list with cost/ready/t each decision
  - `PA_BREAKDIAG=1` — prints board state when `breakRoute` finds nothing to do
  - `PA_CATCHDIAG=1` — prints catch decisions incl. `active=`/`chaining=`/`nap=` (cascade state)
  - `PA_CATALOGDBG=1` / `PA_CATALOGDBG2=1` — catalog scan (`chips.recognize`) fit/verify/accept deltas
  - `PA_GUARDDIAG=1` — cross-column reservation guard output
  - `PA_ROLLBACKDIAG` / `PA_INPUTDIAG` / `PA_VERIFYDIAG` — chipVerify rollback correctness
  - `PA_DEATH=1` — prints the death board/frame
  - `PA_GRID=1` — prints full board grid each `breakRoute` call
- Do NOT run tests through `love`; server/bot logic here runs under plain `luajit`.

## Current git state

- Branch: `claude/bot-building-hpom4o` (pushed up through commit `b462d959`)
- **Uncommitted change**: `bot/catchPrimitive.lua` — the `breakRoute` rewrite described below is
  sitting in the working tree, NOT committed. Verify it (see "Next step" below) before committing.

## What's been verified correct so far (with evidence)

1. **`EnvelopeBrain:chipVerify` rollback mechanism** — FIXED, committed in `b462d959`.
   - Root cause: was calling `Stack:rollbackToFrame(clock0)` per-stack, which sets
     `lastRollbackFrame = currentFrame` (the pre-rollback clock). That makes
     `BaseStack:behindRollback()` true, so `Match:run` tries to fast-forward the stack back up
     using `confirmedInput` — which chipVerify had just truncated away, causing
     `bad argument #1 to 'unpack' (table expected, got nil)`.
   - Fix: use `Match:rewindToFrame(clock0)` instead — it sets `lastRollbackFrame = clock` (the
     target frame), so `behindRollback()` is immediately false, and it also resets
     `Match.clock` itself and rewinds every stack in lockstep (the correct "test then fully
     undo" primitive, vs. `rollbackToFrame`'s "rewind then resimulate forward" primitive meant
     for real netcode rollback).
   - Verified via `PA_INPUTDIAG`/`PA_ROLLBACKDIAG`/`PA_VERIFYDIAG`: 0 crashes, 0 rollback
     failures, 0 board-state mismatches across every real `verify()` call in a full seed-1010 run.

2. **Catalog scan (`chips.recognize` / `findCatch`)** — verified structurally correct, no bug.
   - Instrumented `chips._dbg` (`recCalls`, `fitsCalls`, `fits`, `notTouch`, `verRej`, `accept`)
     directly around the `findCatch` call. Confirmed it DOES fit/verify/accept real combos.
   - The apparent "never credits a catch" behavior is correct by design: it only credits a
     catch when a combo becomes possible *because of* the drop (`if after and not before`), not
     when the same combo already existed independently. Not a bug — legitimate rarity on the
     traced seed.

3. **TOPOFF "ready" pair mechanism** — verified structurally correct, no bug.
   - Traced an apparent "ready pair getting disrupted" — initially hypothesized cross-column
     swap interference (see item 4 below). Added `active=`/`chaining=`/`nap=` to `PA_CATCHDIAG`
     (from `stack:hasActivePanels()`, `stack:hasChainingPanels()`, `stack.n_active_panels`) and
     proved the real cause was a large ongoing cascade (50+ active panels) naturally shifting
     colors as material fell — not the bot's doing. Since "ready" only ever issues WAIT, this is
     harmless.

4. **Cross-column reservation guard** — implemented as a defensive fix, verified correct, committed
   in `b462d959`. Not directly responsible for any observed bug (see item 3), but is a real
   correctness improvement for a genuine hazard class: before choosing a catch action for column
   X, the code now scans every other open column for an already-completed ("ready") pair and marks
   its 2 cells as not-touchable via a lazy metatable overlay (`guardTouchable` /
   `reservedCellsFrom` in `EnvelopeBrain.lua`), so column X's search can never accidentally route a
   swap through a finished pair in another column.

5. **`breakRoute` column-priority sort ignored slide distance** — REAL BUG FOUND AND FIXED,
   **not yet committed**, partially verified (see "Next step").
   - Traced seed 1005 (`PA_SEED_BASE=1004`): after one successful break, the bot committed to
     column 6 (`ready=2`, only needing 1 more matching row) whose only same-color source panel was
     5 columns away. It then spent 125 frames (~2s) walking the cursor one column at a time,
     never completing the slide, while garbage buried the board. Died at 25.6s having broken
     garbage only once. A *closer* (if less "ready") column existed and was never considered,
     because the old sort ranked purely by `ready` count with no regard for slide distance.
   - Fix: rewrote `M.breakRoute` in `bot/catchPrimitive.lua` to compute, for every eligible +
     finishable column, the total slide `cost` (sum of column-distances needed to pull in each
     missing same-color panel), then sort ascending by `cost` (tie-break by lowest row `t`)
     instead of descending by `ready`. Code is in the working tree now (`git diff
     bot/catchPrimitive.lua` to see it).
   - Verified so far: `luajit -bl bot/catchPrimitive.lua` syntax-checks clean. Re-ran seed 1005
     with `PA_ROUTEDIAG=1 PA_MECH=1`: the trace now shows `cost` correctly decreasing each
     decision (5→4→3→2) as the slide makes real progress (a genuine improvement in
     observability/correctness over the old trace, which showed no progress metric at all).
     Confirmed `col6` was the **only** eligible column throughout — there was no faster
     alternative available in this particular seed, so the fix (correctly) made no difference to
     this seed's outcome: `SURVIVAL: median 25.6s` identical before and after.
   - **Open question, not yet resolved**: right after `cost` reached `2`, the very next
     `ROUTEDIAG` line printed `elig=[]` (no eligible columns at all) — column 6 dropped out of
     eligibility entirely rather than continuing down to `cost=1` then `0`/complete. This has
     **not yet been root-caused**. Possible explanations, untested:
     (a) the board's `topRow`/height for column 6 changed (garbage grew, changing `t`),
     (b) the target color `X` at the top of column 6 changed (something disrupted it, maybe
     another cascade like item 3 above),
     (c) it genuinely became unfinishable (a needed same-color source panel got consumed/moved
     out of reach), or
     (d) it's a red herring and the seed's death is actually driven by something unrelated to
     `breakRoute` at that point (e.g., a subsequent injection buried the board before any more
     decisions were needed).
   - **This is the very next thing to investigate** — see "Next step" below.

## Not yet verified at all (still "fires but internals untraced")

These mechanics have only been confirmed to *fire* (via substate histograms showing non-zero
counts across multiple seeds: BRACE_CONTACT, BRACE_PAIR, BRACE_TRIGGER, BREAK_ROUTE, CLEAR,
FLATTEN, DIG_TRIGGER, RAISE, HEARTBEAT, PLAN all show up) — that is a baseline "not dead code"
sanity check only, not a correctness verification. Still need the same single-seed,
instrumented, root-cause treatment given to `chipVerify`, the catalog scan, TOPOFF-ready, and
`breakRoute`:

- `catchPrimitive.stageContact` / `stageTrigger` — the "brace for incoming garbage" staging logic
- `catchPrimitive.flattenMove` — board-flattening move selection
- `catchPrimitive.buildPair` — pair-building for setup
- `catchPrimitive.rowBreak` — the "already have a full matching row" fast path inside `breakRoute`
  (called before the eligible-column scan; not yet independently traced)
- The `PLAN`/`useChips.planMove` fallback path (only relevant outside DIG-ONLY mode, lower
  priority since large-garbage mode gates the brain to DIG-ONLY per task #6)

## Immediate next step for whoever picks this up

1. Re-run seed 1005 with `PA_ROUTEDIAG=1 PA_GRID=1 PA_DEATH=1 PA_MECH=1` (add `PA_CATCHDIAG=1`
   too, to get `active=`/`chaining=`/`nap=` at the same moment) and look at the board state at
   the exact frame where `elig=[]` first appears right after `cost=2`. Compare column 6's
   `topRow`, top color, and the row-3/row-2 contents against the previous `cost=2` decision to
   see which of explanations (a)-(d) above actually happened.
2. Once `breakRoute`'s behavior at that transition is understood and confirmed correct (or fixed
   again if it's a real bug), commit the `breakRoute` change with a root-cause commit message
   (matching the style of `b462d959`: explain the bug, the fix, and cite the before/after
   evidence) and push to `claude/bot-building-hpom4o`.
3. Continue the one-by-one verification through the "not yet verified at all" list above, in the
   same style: pick one seed, add targeted diagnostics, trace a real failure or confirm correct
   behavior, fix if broken, verify the fix with the same seed before moving on. Do this without
   pausing to ask which piece to check next — the owner has explicitly asked for continuous
   progress through all pieces, not checkpoint-by-checkpoint sign-off.
4. Only after every mechanic above is verified (or fixed) should work move to task #3
   (generalize: 10-seed sweep vs 6x12, target median 5 min survival) and task #4 (freeze the
   6x4 protocol, confirm verify suites + CI). Do not sweep/tune before that.

## Task tracker state (as of this handoff)

- #1 completed — baseline + death diagnosis, seed 1001 vs 6x12 large garbage
- #2 completed — seed-1001 deep dive, 16.8s → 64.3s best line, physics + levers documented
- #3 in_progress — generalize to 10 seeds vs 6x12, target median 5 min (BLOCKED on verification pass above)
- #4 pending — freeze 6x4 protocol + verify suites/CI (BLOCKED on verification pass above)
- #5 completed — per-mechanic outcome instrumentation (catch completion rate, reseal→re-break latency)
- #6 completed — gate brain to dig-only mechanics for big garbage
- #7 in_progress — fix CATCH execution until completion rate is high, then long survival (this is
  the umbrella task the current verification pass falls under)

## Files touched this session

- `bot/EnvelopeBrain.lua` — chipVerify rewrite, catalog diagnostics, cross-column reservation
  guard, CATCHDIAG cascade-state fields. **Committed** (`b462d959`).
- `bot/catchPrimitive.lua` — `M.topRow` export, `findTopOff`/`findCatch` touchable-awareness,
  catalog diagnostics (committed in `b462d959`); `breakRoute` distance-aware rewrite
  (**uncommitted**, in working tree now).
- `bot/survivalStress.lua` — `PA_DECDUMP`, `PA_VERIFYDIAG` diagnostics. **Committed** (`b462d959`).
