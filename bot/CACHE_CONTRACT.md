# Cache I/O Contract (v1) â the ONE spec authoring and recognition must both obey

**Why this exists:** the cache was plugged in WRONG. Authoring stored whole-chain footprints (5â6 rows, the entire
solution) while live recognition extracted tiny single-swap fire-sites â two different shape representations, so keys
never matched (1/30 hits with 74 entries). The fix is not "more entries" â it's that **both sides extract the SAME
shape the SAME way.** This doc is that contract. If authoring and recognition ever diverge from it, the cache breaks.

Brian's framing this rests on: *you can win/survive with very FEW shapes* (a handful of small tactics, even ~4 swaps),
**IF** the bot recognizes them. Small + consistent beats big + unique.

---

## The KEY (the shape) â IDENTICAL extraction on both sides
A cached shape is a **small fixed local window**, never a whole-board or whole-chain footprint.

- **ONE extraction function, used by BOTH sides:** `extractWindow(grid, r, c)` â
  rows `[r-1 .. r+2]`, cols `[c-1 .. c+2]` (clamped to board), centered on the swap at `(r,c)` (which swaps cols c,c+1).
  This is a fixed ~4Ã4 window. **No "participating-cell" guessing** (that needs the solution, which live play lacks).
- **Canonicalize:** `KEY = shapeCache.canonShape(window)` â color-blind (first-appearance same/diff mask),
  position-free (bbox crop), mirror-folded. Garbage = `BoardSim.GARBAGE`; color-9 blockers stay color-9 (NOT garbage).
- **Invariant (the whole contract):** authoring and recognition BOTH call `extractWindow` + `canonShape` with the same
  rule. Same tactic on any board â same KEY. If the two sides ever use different windows, they will not match. Locked.

## The VALUE (the action) â what each KEY maps to
```
STORE[key] = {
  swaps  = { {dr, dc}, ... },   -- window-canonical-relative; place(sw, tf) -> live (r,c)
  kind   = "fire" | "setup",    -- fire = clears/chains now; setup = moves toward a future fire
  effect = { chain=N, clears=N, breaksGarbage=N, stopTime=N },  -- for FSM priority (real numbers)
}
```
`swaps` are in the canonical window frame (post mirror-fold). Recall maps them back with the live `tf` from canonShape.

## AUTHORING (board + recorded solution â entries) â per-swap, NOT per-chain
For EACH swap in the recorded solution:
1. `key, tf = canonShape(extractWindow(boardBeforeThisSwap, r, c))` â the local window at that swap.
2. record the swap in canonical-relative coords; tag `kind` (did THIS swap clear? fire : setup) + `effect`.
3. `STORE[key] = {swaps=..., kind, effect}` (keep the highest-value entry on collision).
So one chain solution yields SEVERAL small per-swap shapes (setup steps + the fire), each independently recognizable â
NOT one giant footprint. This is the change from the broken v0.

## RECOGNITION (bare board â plan) â same window, by construction matches
For each candidate swap `(r,c)` in the active band (top ~6 rows):
1. `key, tf = canonShape(extractWindow(grid, r, c))` â the SAME window rule as authoring.
2. `e = STORE[key]`; on hit, `place(e.swaps, tf)` â live swaps. Prefer FIRE; among fires prefer higher `effect`.
3. Miss on every candidate â return nil â caller falls back to live search.

## Shape kinds â fire AND setup (Brian: "add setup shapes so it knows how to MOVE things into place")
- **FIRE** â the window's swap clears/chains/breaks garbage NOW. The payoff.
- **SETUP** â the window's swap moves panels toward a fire (no immediate clear). Authored from solution swaps that
  don't clear but precede one. This is what lets the bot CONSTRUCT from a small library, not just finish.

## The contract in one line
`extractWindow` + `canonShape` is the shared language. Authoring writes small per-swap windows; recognition reads small
per-swap windows; they match because it's literally the same function. Few shapes, recognized everywhere. â B

---

## v2 direction â MULTI-MOVE shapes (Brian, 2026-06-17): "there's always a solve in 2-3 moves"
**Correction to v1:** a cache entry is NOT one swap â it's a PLAY. KEY = the pattern you see; VALUE = a **move
sequence** ("see this shape â swap, move up, swap"). v1 single-swap entries only catch immediate fires/breaks; the
real tactic is multi-move (slide a color to the garbage, make the 3-match). There's almost always a solve given
enough blocks (sparse boards = the "not enough blocks" caveat, handled later).

**Grounding (engine-measured, runtime colorGrid path):**
- FIRE reachable in: 1 move **47%** | â¤2 **60%** | â¤3 **60%** | noneâ¤3 **40%** (235 puzzle boards).
- BREAK reachable in â¤3: only 14/91 garbage boards â but that's the SPARSE-board caveat (curated puzzles, few
  blocks near garbage); fuller gameplay boards reach far more.
- Mid-play authoring (single-swap, v1.5): **825 shapes (638 fire, 187 break)** from 44.6k solution states â the
  current committed library. Captures every tactic that appears mid-construction.

**The tension to resolve (why v2 keying is the hard part):**
- Shallow plays (â¤3 moves) are also findable by a cheap LIVE search â so the cache's UNIQUE value is the DEEP
  sequences (5-8 move chains) too deep to search live. But deep chains have large, near-unique footprints (don't
  recur). So: shallow = searchable (cache optional), deep = unique (cache can't generalize). The bet (Brian's) is
  that a SMALL set of multi-move PLAYS recurs across boards â the v2 build must prove that with a minimal key that
  maps a recurring pattern â a verified sequence.

**Proposed v2 entry:** `KEY = canonShape(participating cells across the sequence)` â `VALUE = { seq = {{dr,dc}..},
kind, effect }`. Author by: for each board, short-search (â¤3) a fire/break sequence; key the minimal pattern the
sequence operates on; store the sequence. Verify each on the real engine. Open question for Brian: key on the
START pattern (recognize early, commit to the play) vs the END pattern (the match) â that's the design call.

---

## v2 BREAKTHROUGH â sliding minimal templates (Brian's cursor-spiral model, 2026-06-17). VALIDATED.
**The recognition was the bug, not the bet.** v1 keyed a FIXED WINDOW at each position â all surrounding junk had to
match â setups looked unique (8% recurrence). Brian's model: a shape is its **participating blocks only**; slide it
over the board (spiral out from the cursor â close, then Â±1, Â±2 â¦), match ONLY the template's cells, **everything else
is don't-care**. When it fits at an offset, the play = "move cursor there â run the sequence."

**MEASURED (held-out, sliding minimal templates, junk=don't-care):** 74 templates â **97% of held-out boards have a
template that fits somewhere** (was 8% with fixed windows). Corroborates data's Audit-5 setup recurrence (70-87%).

**The model (locked):**
- TEMPLATE = participating cells as relative `{dr, dc, colorClass}` (first-appearance same/diff), NO bbox window, NO junk.
- MATCH = slide the template over the board; at each offset check ONLY its cells satisfy the same/diff classes; rest ignored.
- RECALL = the offset gives the cursor move ("4 left"); the stored sequence gives the play from there.
- `bot/slideMatchProto.lua` is the validated prototype.

**Next:** (1) confirm the matched template's PLAY actually FIRES at the offset (recognition=97%, fire-given-match TBD),
(2) rewrite `planCache.match` to slide templates instead of keying fixed windows, (3) extend to multi-move sequences +
breaks. The recognition mechanism that blocked everything is solved.

---

## The CHIP model (Brian, 2026-06-17): shapes carry their own metadata; the BRAIN prioritizes later
A cache entry is a **CHIP**: a self-contained play with everything the brain needs to choose it.
```
CHIP = {
  template = {{dr,dc,colorClass}..},   -- the sliding pattern (participating blocks only, rest don't-care)
  seq      = {{dr,dc}..},              -- the move sequence, relative to the template anchor
  inputs   = "<frames>",               -- timing template (verbatim replay, cursor overridden at swaps)
  effect   = { chain=N, clears=N, breaksGarbage=N, stopTime=N },  -- what it GETS you
  timeCost = <frames/moves to execute>,-- how LONG the play takes  (Brian: brain weighs this)
  kind     = "fire" | "chain" | "break" | "setup",
}
```
**Division of concern:** B builds + VALIDATES the chips (they recognize + their play fires, every scenario). The BRAIN
(later) decides WHICH chip to play from `effect` + `timeCost` + situation. NOT building the brain/priority/game now.

## Scenario validation status (the current job â make every scenario WORK)
- **COMBO / single fire:** sliding template recall + move fires. Recognition 97% recall; precision improves with the
  swap-partner cell (29%â59%) â mechanism sound. â works
- **CHAIN (multi-move):** chip authored from one board, recognized held-out, replayed sequence â **chain fired 2/3
  (67% of recognized)**. Recognition lower (chains recur less). â mechanism validated
- **BREAK (garbage):** â garbage-ANCHORED chip (garbage = fixed anchor, Brian) -> ~100% precision; mid-play authoring 77 chips -> 31% held-out recall (grows with more touching-configs). Garbage breaking > chaining in priority.
- **SETUP (2-move):** ✅ engine-verified -> 100% precision (19/19 played fire). BoardSim mispredicts 2 garbage-heavy boards; the engine-verify REJECTS those phantoms (bot plays nothing, never misfires) per Brian "100% or remove it". setupPlay(grid,rows,verify) iterates BoardSim candidates, returns first the engine confirms.
Once all scenarios are validated chips, tuning/priority is trivial (Brian).

---

## Chains â THREE types (Brian, 2026-06-17). Don't rush; steady-build is parked.
1. **OBVIOUS / one-shot** â whole chain visible in one shape; you know the moves. â a CHIP, played opportunistically
   when it shows up. (Validated: recallâreplayâchain fires 2/3.) Keep as-is.
2. **SETUP chain** â slightly off; a few EXTRA moves to align it, then it falls together. â the SETUP scenario (shared
   with breaks-that-need-a-setup). Recognize "almost-a-chain here" â the extra moves to complete it.
3. **STEADY BUILD** â NOT a shape, a MODE. Clock "start the chain" â enter CHAIN-STATE â then cycle the cursor's local
   neighborhood (~5 blocks) looking ONLY for the next move that CONTINUES the chain, ignoring everything else. This is
   the timing-FSM "continue" half. **PARKED until all the chip scenarios are out** (Brian's call).

**Current focus = get the OTHER scenarios working as chips first** (combo â, obvious-chain â, BREAK â needs garbage-edge
alignment, SETUP to do). Then the steady-build mode.

---

## STEADY-BUILD chain mode (Brian unparked it after setup hit 100%, 2026-06-17) — grounding
A MODE, not a chip. **Chain-state signal = `st.chain_counter`** (engine-measured: climbs 1→2→3 as links resolve;
`st:hasChainingPanels()` true during the cascade). Real chain-puzzle solutions peak chain_counter 2–3, built over
200–440 input frames (raises + swaps) — steady, not one-shot.
- **Enter** the mode when a chain starts (chain_counter ≥ 1 / a fire that will chain).
- **While in it:** search ONLY the cursor's local ~5-block neighborhood for the swap that creates the NEXT link, and
  land it inside the chain-continuation window (new match forms while prior panels still settle → chain_counter++).
- **Exit** when no continuation exists in the window.
**Next concrete step (B):** validate the CONTINUATION mechanism — fire a chain, and during the chaining frames apply a
local swap that extends chain_counter beyond its natural peak. That's the timing-sensitive core; once shown, the mode
is just: detect chain-state → continuation-search → land in window → repeat. (Setup's engine-verify pattern reused.)
