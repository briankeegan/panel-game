# Bot Verification Handoff — 2026-07-02 (updated)

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

- Single-seed real-engine trace: `luajit bot/survivalStress.lua <garbageEveryFrames> <maxFrames> <numSeeds> "" hard 6 12`
  with `PA_SEED_BASE=<seed-1>` to pin one seed (seed = PA_SEED_BASE + i, i starting at 1), plus diagnostic env
  vars (see below). **Arg order note (corrects the previous version of this doc):** arg1 is
  `garbageEveryFrames` (injection period), arg2 is `maxFrames`, arg3 is `numSeeds` — NOT
  `<maxFrames> <injectPeriod> <numSeeds>` as an earlier draft of this doc said. The frozen 6x12
  large-garbage protocol is `600 3600 <seeds>` (inject every 600f/10s, cap at 3600f/60s).
- Key diagnostic env vars already wired into the code:
  - `PA_MECH=1` — per-seed mechanic counters (reveals, breakEvents, catchDone, rebreakLat)
  - `PA_ROUTEDIAG=1` — prints `breakRoute`'s eligible-column list with cost/ready/t each decision
  - `PA_ELIGWHY=1` — **new**, prints WHY a column dropped out of `breakRoute`'s eligible list:
    distinguishes a genuine dead end (no source color anywhere in the row) from a column that's
    really finishable but its one candidate source panel is mid-animation this exact frame
    (`touchOK` false) — the latter is transient/harmless, see item 5 below.
  - `PA_ROWBREAKDIAG=1` — **new**, prints `rowBreak`'s row/color/column-triple each time it finds a
    candidate horizontal-3 (before the touch/adjacency checks that decide the actual swap).
  - `PA_BUILDPAIRDIAG=1` — **new**, prints `buildPair`'s `topPairCount` each call and the column/swap
    it picks when it acts.
  - `PA_STAGEDIAG=1` — **new**, prints `stageTrigger`'s full-board cocked count each call plus which
    column it routes, and `stageContact`'s tied-max-height-column list whenever more than one column
    shares the board's tallest colored top.
  - `PA_FLATDIAG=1` — **new**, prints `flattenMove`'s per-column tops, the chosen tall/short pair, and
    the computed swap row each time it acts.
  - `PA_PLANDIAG=1` — **new**, prints `useChips.planMove`'s candidate count, chosen swap, score, and
    commit/reject decision each call.
  - `PA_PLANGRID=1` — **new**, prints the full color grid whenever `planMove` commits a swap that
    predicts an immediate clear (`reward>0`) — pairs with `PA_PLANDIAG`.
  - `PA_PLANVERIFY=1` — **new**, ground-truth check wired into `EnvelopeBrain.lua`: stashes a `PLAN`
    swap's predicted `total`/`chain` when committed, then ~90+ frames later (once the real engine has
    had time to execute and settle it) compares against the actual `stack.panels_cleared` delta on
    the SAME live run — prints `MATCHED` or `DID-NOT-MATERIALIZE`. This is how items 11/12 below were
    found: not a synthetic re-check, the real engine's own clear counter on the exact run being played.
  - `PA_PLANVERIFY2=1` — companion to `PA_PLANVERIFY`: prints `stack.clock`/`stack.in_countdown` at
    the moment a `PLAN` swap commits (rules out the pre-game countdown as the cause when it isn't).
  - `PA_PLANSTATE=1` — companion to `PA_PLANVERIFY`: dumps the RAW panel state codes (not just colors)
    for the whole board at the moment a `PLAN` swap commits, to check for stale matched/popping/popped
    cells that the plain color grid doesn't distinguish from normal at-rest panels.
  - `PA_CURSORDIAG=1` — **new**, in `CursorController.lua`: prints every `RISE-SHIFT` (a locked
    target's row bumped to follow the passive rise), `FIRE` (the cell a swap actually executes at),
    and `ABANDON` (a fired swap was refused/didn't clear and the lock let go) event.
  - `PA_FIRECHECK=1` — **new**, in `CursorController.lua`: at the EXACT frame a `PLAN` swap fires,
    recomputes `BoardSim.simSwap` on the board as it is AT THAT INSTANT and prints the prediction —
    the key tool for telling real bugs (still predicts a clear at fire time, yet it doesn't happen)
    apart from genuine staleness (predicts nothing — the board changed since the decision). Requires
    `state.board` to be populated, so run alongside `PA_PLANVERIFY`.
  - `PA_BREAKDIAG=1` — prints board state when `breakRoute` finds nothing to do
  - `PA_CATCHDIAG=1` — prints catch decisions incl. `active=`/`chaining=`/`nap=` (cascade state)
  - `PA_CATALOGDBG=1` / `PA_CATALOGDBG2=1` — catalog scan (`chips.recognize`) fit/verify/accept deltas
  - `PA_GUARDDIAG=1` — cross-column reservation guard output
  - `PA_ROLLBACKDIAG` / `PA_INPUTDIAG` / `PA_VERIFYDIAG` — chipVerify rollback correctness
  - `PA_DEATH=1` — prints the death board/frame
  - `PA_GRID=1` — prints full board grid each `breakRoute` call
- Do NOT run tests through `love`; server/bot logic here runs under plain `luajit`.

## Current git state

- Branch: `claude/bot-building-hpom4o`, pushed through commit `bd51b0fa` (stageTrigger/stageContact
  fixes + flattenMove verification + a catchVerify.lua test-harness fix). This session's *new*
  changes (two foundational `BoardSim.lua` fixes plus the `planMove` verification that found them —
  see items 11/12 below) are uncommitted as of writing this — commit them right after this doc lands.

## What's been verified correct so far (with evidence)

1. **`EnvelopeBrain:chipVerify` rollback mechanism** — FIXED, committed in `b462d959`. (unchanged
   from previous handoff — see git log for full writeup.)

2. **Catalog scan (`chips.recognize` / `findCatch`)** — verified structurally correct, no bug.
   (unchanged from previous handoff.)

3. **TOPOFF "ready" pair mechanism** — verified structurally correct, no bug. (unchanged from
   previous handoff.)

4. **Cross-column reservation guard** — implemented as a defensive fix, verified correct, committed
   in `b462d959`. (unchanged from previous handoff.) Note: this guard is wired into `tryCatch`'s
   TOPOFF path only, NOT into `breakRoute` (confirmed by reading call sites in `EnvelopeBrain.lua`
   — `breakRoute` is always called with the plain `BoardSim.touchableGrid` mask, never the guarded
   overlay). Relevant to item 5's resolution below.

5. **`breakRoute` column-priority sort ignored slide distance** — FIXED, committed in `d9db36cb`.
   The previous handoff left one open question: right after a column's `cost` reached `2`, the very
   next `ROUTEDIAG` line sometimes showed `elig=[]` (no eligible columns at all) instead of
   continuing down to `cost=1`. **This is now resolved.**
   - Root cause, confirmed with the new `PA_ELIGWHY` diagnostic on seed 1005 (`PA_SEED_BASE=1004`,
     `600 3600 1 "" hard 6 12`): at the frame where `elig=[]` appeared, `ELIGWHY` printed
     `col=5 X=4 row=3 X-found-but-TOUCH-BLOCKED` — the column's one candidate source panel (color
     4, row 3) existed and was the right color, but `touchOK` rejected it because the panel was
     mid-animation (falling/settling, `BoardSim.touchableGrid` requires panel state `s==0 or s==4`)
     at that exact frame, almost certainly because another mechanic's swap on the immediately
     preceding frame was still resolving. This is explanation "the source panel got consumed/moved
     out of reach" from the original list, refined: it's not consumed or moved away, just
     momentarily untouchable.
   - This is **transient and harmless by design**, not a bug: `breakRoute` correctly can't propose a
     swap through a cell mid-animation (the engine would reject or misbehave on it), so returning
     nil for one frame and falling through to another substate (stageContact/stageTrigger/buildPair)
     is exactly right. The very next frame the trace confirms the column reappears in `elig` with
     cost unchanged or lower (`cost2` → `cost1`), i.e. no progress is lost, no oscillation.
   - `PA_ELIGWHY` is left in the codebase (gated, off by default) as a permanent diagnostic — same
     convention as the other one-off investigation flags in this file — since it cleanly
     distinguishes "genuinely stuck" from "transiently blocked by animation," which will keep coming
     up in future single-seed digs.

6. **`rowBreak`** (the "already have a full matching row" fast path inside `breakRoute`, called
   before the eligible-column scan) — verified structurally correct via single-seed trace, no bug
   found.
   - Added `PA_ROWBREAKDIAG` (prints row/color/column-triple each time a horizontal-3 candidate is
     found). Swept seeds 1001-1010 with it on: `rowBreak` only fired on seed 1005 in this window
     (it needs 3 same-colored, garbage-touching cells in one row — rare by design, matches the
     existing code comment).
   - On seed 1005 it printed a clean, monotonically-converging sequence: `cols=[1,4,6]` →
     `cols=[2,4,6]` → `cols=[3,4,6]` (color 5) — the "outer" panel at column 1 stepped rightward one
     column per call toward the fixed middle panel at column 4, exactly as the "tightest triple,
     slide the ends toward the middle" design intends. Once the left end reached column 3 (adjacent
     to the middle at 4), the very next branch (moving the column-6 end toward the middle) fired,
     and the row cleared — this lines up exactly with the run's `breakEvents=1` / `garbageBroken=72`
     (a full block popped from one match). No oscillation, no dead columns picked, no stuck state.
   - Also manually verified the "tightest triple" selection logic (`bi`/`bspan` computed only over
     consecutive-index triples in the sorted column list): this is provably sufficient — the
     minimum-span 3-subset of a sorted array is always 3 consecutive elements — so it isn't skipping
     a tighter combination by only checking consecutive indices.

7. **`buildPair`** — **REAL BUG FOUND AND FIXED**, uncommitted in the working tree now (see "Files
   touched" below).
   - Added `PA_BUILDPAIRDIAG` (prints `topPairCount` each call, plus the column/swap chosen). Traced
     seed 1001 (`PA_SEED_BASE=1000`): the diagnostic log showed `topPairCount` oscillating at `2`
     forever instead of climbing to `PAIR_TARGET=3`, with columns 5 and 6 (both top color `3`)
     alternately proposing the exact same physical swap `(1,5)` back and forth, one after the other,
     with no other event between them (`uniq -c` on the log showed each alternating line appearing
     exactly once — a genuine ping-pong, not "same decision re-proposed because the cursor hasn't
     arrived yet").
   - Root cause: column 5 and column 6 shared the same top color. Completing column 5's pair meant
     pulling that color out of column 6's row-1 cell; but column 6's OWN top color was the same
     color, so as soon as column 5's swap landed, column 6 saw its own gap fillable from the exact
     cell that swap had just vacated-into (column 5's row 1) — and pulled it right back, un-pairing
     column 5. Each column was cannibalizing the other's just-completed pair to (at best) relocate
     the same single pair sideways forever, burning cursor moves without ever reaching
     `PAIR_TARGET`. (This is the same failure class `catchSlide`'s doc comment already calls out —
     "only ever touches a cell that doesn't yet match, so repeated calls converge monotonically...
     instead of oscillating" — `buildPair` was missing that guarantee.)
   - Fix: added `ownsIntactPair(grid, H, nc, r)` — before taking a color from a neighbor column's
     cell, check whether that neighbor's OWN top pair is already complete and includes the row being
     taken from; if so, skip that donor (never cannibalize an already-intact pair to maybe build
     another — a wash at best, infinite thrash at worst). Applied to all four donor checks
     (a-side/b-side, from-left/from-right).
   - Verified via `PA_BUILDPAIRDIAG` on the same seed 1001: the ping-pong is gone (`uniq -c` shows
     every proposed swap exactly once, no repeats), and `topPairCount` now climbs to `3` (hits
     target) multiple times over the run instead of getting stuck at `2`. Re-ran the full 10-seed
     `600 3600 10` sweep afterward: identical per-seed survival/garbage-broken/swap numbers to
     before the fix (seeds 1001-1010: 11.8/31.4/27.5/12.4/19.5/11.6/11.6/11.6/11.6/21.0s) — this bug
     was idle-frame-only waste in these particular seeds, not itself a death cause here, but it's a
     genuine correctness fix (no more infinite cursor-move waste) and could matter on other seeds or
     after tuning `PAIR_TARGET`/board layouts where the shared-top-color adjacency comes up more.

8. **`stageTrigger`** — **REAL BUG FOUND AND FIXED** (latent — see verification caveat below).
   - Added `PA_STAGEDIAG`'s independent full-board recount of cocked columns, run alongside the old
     scan-and-act-in-one-pass logic (no behavior change yet at that point). Swept all 10 seeds
     (1001-1010, `600 3600 10`): the independent recount confirmed the counting mechanism behaves as
     read from the code, but `fullBoardCocked` never exceeded `2` in this window (bot dies before
     reaching `TRIGGER_TARGET=3`), so the overshoot scenario below was never actually exercised by
     these particular seeds.
   - Bug (found by code audit, mechanism confirmed correct via the diagnostic above): the old code
     counted `cocked` and decided whether to route a swap IN THE SAME left-to-right pass, so the
     `TRIGGER_TARGET` cap only held if every already-cocked column happened to sit at a LOWER column
     index than any uncocked-but-pairable one. An uncocked pairable column at index 2 with 3 (already
     at target) cocked columns at indices 4,5,6 would still get routed — staging a 4th column past the
     cap — because the scan returns before ever reaching 4,5,6 to count them.
   - Fix: split into two passes — count cocked columns across the WHOLE board first (extracted into
     `isCockedTrigger`), bail immediately if already at target, otherwise scan (same left-to-right,
     nearest-candidate-first priority as before) for the first uncocked routable column.
   - **Verification caveat, stated plainly**: unlike the other fixes in this file, the overshoot this
     fixes was **not observed actually happening** in the 10-seed sweep (cocked count topped out at 2,
     never reached the target of 3 where the bug would bite) — it's a proven-by-code-reading latent
     bug, confirmed via instrumentation to have the exact counting mechanism described, but not yet
     caught in the act. It's fixed anyway (cheap, provably correct, zero risk to the already-verified
     paths) because it will start mattering the moment other fixes extend survival time far enough to
     sustain 3+ simultaneously-cocked columns — which is the entire point of this effort. Re-ran the
     10-seed sweep after the fix: byte-identical per-seed results to before (this particular fix's
     branch condition never diverged from the old code's decision on these seeds, as expected since
     `cocked` never reached target either way).

9. **`stageContact`** — **REAL BUG FOUND AND FIXED, with measured impact**.
   - Added `PA_STAGEDIAG`'s tied-max-height-column list (fires whenever more than one column shares
     the board's tallest colored top) alongside the old logic (no behavior change yet). Swept all 10
     seeds with it on: zero tie print-outs anywhere — in the *old* code's trajectories, this particular
     board state (two+ columns tied for tallest) apparently never arose in any of these 10 seeds'
     (short) lifetimes.
   - Bug (found by code audit): the old code did `return nil` for the WHOLE function the instant it
     found the FIRST max-height column already cocked, abandoning any check of OTHER tied max-height
     columns that might still need staging (no pair yet, or a pair but not cocked) — unlike
     `stageTrigger`'s more careful design (which at least continues scanning other columns via `goto
     nextcol`).
   - Fix: changed the early `return nil` into a per-column skip (`if not alreadyCocked then ... end`,
     falling through to the next tied column) — `return nil` now only fires after the whole loop finds
     nothing actionable anywhere, matching `stageTrigger`'s pattern.
   - **This fix has a measured, positive effect**, isolated by testing three variants (both fixes /
     only the `stageTrigger` fix / neither): re-running the 10-seed `600 3600 10` sweep, **seed 1008**
     went from 11.6s survival / 0 garbage broken (with the old `stageContact` logic, confirmed by
     reverting just this fix and re-running) to **23.0s / 72 broken** with the fix applied — a real,
     reproducible improvement, not sweep noise (bisected: keeping `stageTrigger`'s fix alone reproduces
     the old 11.6s/0 result; only `stageContact`'s fix changes the outcome). Traced seed 1008 alone
     with `PA_STAGEDIAG=1` on the FIXED code and found tied max-height columns are actually **very
     common** on this seed once its trajectory diverges from the buggy path (dozens of ties across the
     run, e.g. `maxT=4 tiedCols=[1,2,3,4,5,6]` — all six columns tied at one point) — so the old bug,
     once triggered, was likely discarding real staging opportunities routinely, not in a rare corner
     case. (The other 9 seeds' final numbers were unchanged, since their old trajectories apparently
     never reached a tie before dying either way — consistent with how chaotic/cascading a small
     board-state change can be frame-to-frame.)
   - Median across the 10-seed sweep moved from 12.1s to 15.9s (mean 17.0s → 18.1s) purely from this
     fix; re-ran the sweep twice to confirm the new numbers are stable/deterministic.

10. **`flattenMove`** — verified structurally correct via single-seed trace; one minor defensive fix
    applied (not a live bug, but a real edge case in the code as written).
    - Added `PA_FLATDIAG` (prints per-column `tops`, the chosen tall/short pair, and the swap row).
      Traced seed 1001: successive decisions showed `bestDiff` shrinking within each local region it
      worked on (e.g. `4 → 3 → 2` around the same tall/short pair across calls, once other events in
      between are accounted for), consistent with the documented "propagates tall→short across the
      whole board" design — no oscillation, no stuck state, no invalid swap proposed.
    - Found (by code audit, not by triggering it) that `bestDiff, bestC = 0, 0` combined with the
      `bestDiff < (PA_FLAT_MIN or 2)` guard meant if someone ever ran with `PA_FLAT_MIN=0` (not a
      realistic sweep value — the doc comment even says "PA_FLAT_MIN=1 = perfectly flat" as the
      lowest sane setting — but nothing stops it), a fully-flat board (`bestDiff` stays `0`) would
      fail the `< 0` check and fall through to use `bestC=0` as a column index — `tops[0]` is `nil` in
      Lua, and the very next line compares it, which would error. Fixed defensively: `bestDiff`
      initialized to `-1` instead of `0`, plus an explicit `bestC == 0` guard, so this can't happen
      regardless of what `PA_FLAT_MIN` is set to. Zero behavior change for any realistic setting
      (confirmed via the 10-seed sweep: identical results before/after this one-line guard).

11. **`useChips.planMove`** — **CORRECTS A MISTAKE IN THE PREVIOUS VERSION OF THIS DOC**, and led to
    the two most significant fixes of the session (items 11b/12 below).
    - The previous handoff said `planMove` was "gated OFF in the large-garbage DIG-ONLY brain path
      ... lower priority." **This was wrong** — re-reading `EnvelopeBrain.lua`'s `self._bigGarbageGame`
      branch (the DIG-ONLY path actually used by the large-garbage practice mode) shows `planMove` IS
      called there, twice (the sealed-garbage "ASSEMBLE a clear via setup swaps" fallback, and the
      lull-posture fallback), plus 3 more call sites in the non-DIG-ONLY paths. Confirmed empirically
      with `PA_BEHAV`'s substate histogram on the 10-seed sweep: `PLAN` fires more often than almost
      any other substate in most seeds (e.g. 22 times in seed 1006, more than every other substate
      combined) — it is a first-class, heavily-used mechanic, not a rare fallback.
    - Verification method (per the owner's "hard instrumentation, not a synthetic re-check" standard):
      added `PA_PLANVERIFY` to compare `planMove`'s prediction against the REAL engine's own
      `panels_cleared` counter on the SAME live run — no standalone/offline reproduction used for the
      actual verdict (an isolated real-engine reproduction via `Puzzle`/`Match`/`Stack`, same pattern
      as `bot/tests/boardSimVerify.lua`, was used only once, to sanity-check that `BoardSim.simSwap`'s
      math itself was correct in isolation, before concluding the live-run divergence must be
      elsewhere).
    - On seed 1006 (`PA_SEED_BASE=1005`), traced 5 `PLAN` commits: 2 `DID-NOT-MATERIALIZE` beyond the
      first (countdown) one. Root-caused both — see items 11b and 12.

11b. **Pre-game countdown swap attempts — NOT a bug.** The very first `PLAN` commit of the run
    (`swap=(4,5)`) sat for 215 frames before `PLANVERIFY` reported `DID-NOT-MATERIALIZE`.
    `PA_PLANVERIFY2` showed why: `clock=0 in_countdown=true` — the swap was proposed during the
    match's own pre-game countdown (`consts.COUNTDOWN_LENGTH=180` + `COUNTDOWN_START=8` frames), during
    which `Stack:canSwap` unconditionally refuses every swap (`self.in_countdown ... return false`)
    regardless of what any mechanic proposes. This is correct, universal engine behavior (a human
    player can't swap during the countdown either) — not something any bot fix should or can address.
    Confirmed by checking every OTHER `DID-NOT-MATERIALIZE` case: all had `in_countdown=false`.

12. **Two real, foundational bugs found and fixed in `bot/BoardSim.lua`** — both discovered while
    root-causing `planMove`'s remaining (non-countdown) mispredictions, both affect every mechanic
    that reads `BoardSim.colorGrid`/`touchableGrid` (i.e. all of `catchPrimitive.lua` too), not just
    `planMove`.
    - **(a) `touchableGrid` was missing a real `Stack:canSwap` rule.** The engine refuses a swap if
      the panel directly ABOVE either swap cell is `hovering` (state 5) — `common/engine/Stack.lua:1402`,
      "neither space above us can be hovering" — independent of the swap cells' own state.
      `BoardSim.touchableGrid` only ever checked each cell's OWN state, never its neighbor above.
      Fixed: `touchableGrid` now also requires the cell directly above to not be hovering. Verified
      the real rule by reading `Stack:canSwap` directly, confirmed `hovering=5` against
      `client/src/network/PanelStateCodes.lua`. **Caveat**: this fix, while independently correct and
      kept, did NOT turn out to be the cause of the specific seed-1006 stall it was written to explain
      (that one was the countdown, item 11b) — re-verify wasn't wasted since it's a real gap closed,
      but the attribution in the first draft of this fix was wrong; always check ground truth (which
      is exactly what caught the mistake here) rather than stopping at "a plausible-sounding cause."
    - **(b) `colorGrid` didn't filter out already-resolving panels — this is the big one.** A panel
      that's already `matched`(3), `popping`(2), or `popped`(9) from an EARLIER, unrelated match still
      carries its stale color in `board[r][c].c` for several frames while it visually clears.
      `BoardSim.colorGrid` read that color unconditionally, so `BoardSim.resolve`'s `findMatches`
      would "discover" that stale run as a FRESH match on every `simSwap` call this frame — crediting
      whatever swap is being scored with a clear it didn't cause and has nothing to do with. Confirmed
      directly: `PA_PLANSTATE` on the seed-1006 `swap=(5,2)` mispredict (predicted total=3, actual=2)
      showed row 3 columns 4-6 reading color `1,1,1` (looks like a live, matchable triple) but state
      codes `9,2,2` (popped/popping/popping — already gone, unrelated to this swap). Fixed: `colorGrid`
      now reports matched/popping/popped cells as empty(0) instead of their stale color — consistent
      with the simulator's existing "instant full settle" approximation (already documented for the
      DEEP-CHAIN PHANTOM case in `BoardSim.resolve`), just applied one step earlier.
    - **Impact, measured on the real engine, same seed**: seed 1006 went from 694 frames / 11.6s / 0
      garbage broken (pre-fix) to **1721 frames / 28.7s / 138 garbage broken** (post-fix) — a single
      foundational fix more than doubling one seed's survival and unlocking its first-ever break in
      this window. Re-ran the 10-seed `600 3600 10` sweep: median 15.9s → 16.5s, mean 18.1s → 18.3s
      (some individual seeds moved down, e.g. 1005 19.5s→11.4s and 1010 lost its 144-garbage-broken
      run — expected: changing an early decision cascades the whole rest of a chaotic run differently,
      sometimes for the worse on a given seed even when the fix is strictly more correct; the point of
      the per-seed median, not single-seed numbers, is to average that out). `bot/tests/catchVerify.lua`
      still reports 8/8 OK. `DETERMINISM: PASS` on the parity check.
13. **Deep-chain phantom (`chain>=2` predictions) — FOUND SYSTEMATIC, FIXED, NOT JUST DOCUMENTED.**
    Checking whether "every mechanic works for sure" before moving on, re-measured `chain>=2`
    predictions with real ground truth rather than accepting the earlier "known limitation" framing:
    **every single `chain>=2` prediction observed (13/13, across seed 1006 alone and the 10-seed
    sweep) was wrong** — several predicted a 9-10 panel clear (`chain=3`) that the real engine cleared
    ZERO of. This is not an edge case, it's a total failure mode for any candidate swap the simulator
    thinks fires a 2+-link cascade, and since `W_IMMEDIATE_CHAIN=400` weights chain depth heavily,
    `planMove` would have been strongly drawn toward these phantom swaps over real options.
    - Root cause matches the pre-existing DEEP-CHAIN PHANTOM comment in `BoardSim.resolve`: the real
      engine settles cascades wave-by-wave with a hover delay between links; the simulator's instant
      full-settle can align links 2+ in ways that never fire for real. The FIRST link doesn't have
      this problem (it's the direct, immediate result of the swap, no wave-timing gap).
    - Fixed: threaded an explicit `maxLinkCap` parameter through `BoardSim.resolve`/`simSwap` (the
      existing `PA_MAXLINK` env var still overrides, for diagnostics), and set
      `TRUSTED_CHAIN_CAP=1` in `useChips.lua`'s `scoreSwap` so `planMove` never scores or rewards a
      cascade past the first link. Re-verified on the same real engine, same seeds: **0 of 84
      `chain>=2` predictions remain** (all correctly capped to `chain=1`) across the 10-seed sweep;
      `chain=1` predictions kept the same reliability as before this fix (still imperfect — see below
      — but that ceiling was already there, this fix didn't move it).
    - **The owner pushed back hard on treating 67% as acceptable ("you're a computer, it should be
      100%") — right to, and it led to one more real, confirmed, fixed bug (item 14 below), not just a
      documentation exercise.**

14. **`BoardSim.applyGravity` silently destroyed color-7/8/9 panels — a second, distinct bug found by
    refusing to accept "inherent staleness" without proof.**
    - Built `PA_FIRECHECK`: at the EXACT frame a `PLAN` swap physically fires (not ~90-130 frames
      earlier at decision time), recompute what `BoardSim.simSwap` predicts on the board AS IT IS AT
      THAT INSTANT. If it still predicts a clear and the real engine still doesn't deliver it, that
      proves the board had NOT changed since the decision — ruling out staleness and proving a real,
      persistent bug. Ran it: **10 of 12 remaining `DID-NOT-MATERIALIZE` cases in a 10-seed sweep
      showed `FIRECHECK` still confidently predicting the clear at the exact moment of firing.** Only
      2 were genuine staleness (`FIRECHECK` itself showed `chain=0/total=0` — the board had legitimately
      changed). This is hard evidence "it's just staleness" was wrong as a blanket explanation.
    - Picked one clean example (`swap=(7,1)`, predicted 3, actual 0, `FIRECHECK` confirmed 3 at fire
      time) and reproduced the EXACT captured board+swap on the real engine (`Puzzle`/`Match`/`Stack`,
      same pattern as `bot/tests/boardSimVerify.lua` — never a standalone reimplementation). Found:
      `Stack:canSwap` returns true, the swap physically executes, and the panel visibly FALLS after
      landing on an empty gap below it — completely correct, expected engine physics. But the panel
      lands one row lower than `BoardSim` predicted, missing the vertical run entirely, because the
      pre-swap board had a color-8 panel sitting in the fall path. Root cause: `applyGravity`'s
      column-compaction loops (both the fast no-garbage path and the slow garbage-aware path) gated
      on `isPlay(color)`, which only covers 1-6. Colors 7/8/9 are real, non-garbage, swappable panels
      that legitimately occur in live gameplay (confirmed directly — this board came from an actual
      seed, not a puzzle) but `isPlay` excludes them for MATCH-FINDING purposes (correct — they're
      "blocker" colors that never form a match). `applyGravity` reused the same narrow check for
      GRAVITY, which is wrong: a blocker panel still physically exists and must still fall/be
      displaced correctly. Because it was neither moved nor protected, a play panel falling past its
      row during the SAME compaction pass silently overwrote it, corrupting the simulated post-swap
      board before `findMatches` ever ran.
    - Fixed: added `fallsUnderGravity(c)` (`c ~= 0 and c ~= GARBAGE`, i.e. broader than `isPlay`) and
      used it in both `applyGravity` loops instead of `isPlay`. Re-ran the exact reproduction:
      `BoardSim.simSwap` now correctly predicts `chain=0/total=0`, matching the real engine's `0`
      exactly.
    - **Measured impact**: 10-seed sweep hit rate went from **66.7% (56/84) to 76.1% (51/67)**.
      `bot/tests/catchVerify.lua`: 8/8 OK, unchanged. `bot/tests/boardSimVerify.lua`: unchanged at
      11/941 (1.2%) — expected, that test only generates colors 1-3, so it never exercises this bug;
      its residual is the separate, already-documented deep-chain phantom.
    - **Kept digging past this fix, as instructed — the honest remaining picture**: re-ran
      `PA_FIRECHECK` after this fix. Of the 12 `DID-NOT-MATERIALIZE` cases remaining, 10 STILL show
      `FIRECHECK` confirming a valid prediction at the exact fire moment (one of those 10 is the
      already-explained pre-game countdown, not a bug). Attempted one more real-engine reproduction
      (`swap=(2,2)`, predicted 3, actual 1, all-normal panel states — ruling out the state-filtering
      fixes above as the cause) and it did **not** cleanly reproduce: the isolated real-engine replay
      cleared 6 panels, neither matching the live run's actual (1) nor the original prediction (3).
      That three-way mismatch means either the board/state reconstruction for this specific capture
      has an error, or the snapshot-correlation script mis-paired diagnostic lines for this case — it
      is NOT confirmed as a new bug, and reporting it as one without a clean reproduction would repeat
      the exact mistake (asserting a cause without hard evidence) this investigation was trying to
      avoid. Stopped here rather than present a shaky finding as fact.
    - **Final honest number**: hit rate is **76.1% (51/67)** after 4 real, independently-verified bugs
      fixed today (items 12a, 12b, 13, 14). A meaningful majority of the remaining ~24% still shows
      `FIRECHECK`-confirmed valid predictions at fire time, meaning **at least one more real bug likely
      remains**, not yet found. This is not "inherent staleness" by the evidence gathered — it is an
      open, unsolved problem, and should be picked up with the same `PA_FIRECHECK` methodology
      (get a clean, correctly-correlated capture, reproduce on the real engine, trace exactly where
      `BoardSim`'s simulation diverges) rather than assumed away.
    - `bot/tests/catchVerify.lua`: 8/8 OK. `DETERMINISM: PASS` (10-seed sweep, both runs).

## Not yet verified at all

Every substate in `catchPrimitive.lua` (`breakRoute`, `rowBreak`, `buildPair`, `stageTrigger`,
`stageContact`, `flattenMove`) and `useChips.planMove` has had the single-seed, real-engine-
ground-truth treatment the owner mandated (items 5-14 above). **This is NOT the same as "planMove's
predictions are fully correct"** — item 14 ends with a real, open, unsolved gap: `planMove`'s hit
rate is 76.1%, and most of the remaining misses are evidenced (via `PA_FIRECHECK`) to be a real bug,
not staleness. Whoever picks this up next should treat that as active, unfinished work, not a
footnote. The deep-chain phantom (item 13's original framing) is fixed, not just documented, as of
today — the open item now is the still-unexplained ~24% `planMove` miss rate from item 14.

## Immediate next step for whoever picks this up

Do NOT treat this as "done, move to tuning." `planMove`'s hit rate is 76.1%, and item 14's
`PA_FIRECHECK` evidence shows most of the remaining misses are a real, unfound bug, not staleness.
Next step: repeat item 14's method — capture a clean, correctly-correlated `PA_PLANGRID`/
`PA_PLANSTATE`/`PA_FIRECHECK` snapshot for a `DID-NOT-MATERIALIZE` case, reproduce it on the real
engine (`Puzzle`/`Match`/`Stack`), and trace exactly where `BoardSim`'s simulation diverges — the
same process that already found 4 distinct bugs today. Only once `PA_FIRECHECK` stops finding
fire-time-confirmed-but-failed cases (or the remaining ones are conclusively staleness, not assumed)
should work move to task #3 (10-seed generalization sweep) and task #4 (freeze the 6x4 protocol).

## Task tracker state (as of this handoff)

- #1 completed — baseline + death diagnosis, seed 1001 vs 6x12 large garbage
- #2 completed — seed-1001 deep dive, 16.8s → 64.3s best line, physics + levers documented
- #3 in_progress — generalize to 10 seeds vs 6x12, target median 5 min (BLOCKED on verification pass above)
- #4 pending — freeze 6x4 protocol + verify suites/CI (BLOCKED on verification pass above)
- #5 completed — per-mechanic outcome instrumentation (catch completion rate, reseal→re-break latency)
- #6 completed — gate brain to dig-only mechanics for big garbage
- #7 in_progress — fix CATCH execution until completion rate is high, then long survival (this is
  the umbrella task the current verification pass falls under). Every mechanic verified/fixed under
  this task as of this handoff: `rowBreak`, `buildPair`, `stageTrigger`, `stageContact`,
  `flattenMove`, `planMove`, plus the two foundational `BoardSim.lua` fixes (item 12).

## Files touched this session

- `bot/catchPrimitive.lua`, `bot/EnvelopeBrain.lua`, `bot/survivalStress.lua` — see `b462d959`,
  `d9db36cb`, `05fce30b`, `9da8515b`, `bd51b0fa` (all committed; see git log for detail).
- `bot/BoardSim.lua` — `touchableGrid` hovering-above-swap fix, `colorGrid` stale-resolving-panel
  fix (item 12). Uncommitted at time of writing.
- `bot/CursorController.lua` — `PA_CURSORDIAG`. Uncommitted.
- `bot/EnvelopeBrain.lua` — `PA_PLANVERIFY`/`PA_PLANVERIFY2`/`PA_PLANSTATE`, `firePlan` wiring for
  all `planMove` call sites. Uncommitted.
- `bot/useChips.lua` — `PA_PLANDIAG`/`PA_PLANGRID`, `planMove` now also returns `total`/`chain` for
  verification. Uncommitted.
- `docs/bot-verification-handoff.md` — this file.
