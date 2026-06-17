# Cache I/O Contract (v1) — the ONE spec authoring and recognition must both obey

**Why this exists:** the cache was plugged in WRONG. Authoring stored whole-chain footprints (5–6 rows, the entire
solution) while live recognition extracted tiny single-swap fire-sites — two different shape representations, so keys
never matched (1/30 hits with 74 entries). The fix is not "more entries" — it's that **both sides extract the SAME
shape the SAME way.** This doc is that contract. If authoring and recognition ever diverge from it, the cache breaks.

Brian's framing this rests on: *you can win/survive with very FEW shapes* (a handful of small tactics, even ~4 swaps),
**IF** the bot recognizes them. Small + consistent beats big + unique.

---

## The KEY (the shape) — IDENTICAL extraction on both sides
A cached shape is a **small fixed local window**, never a whole-board or whole-chain footprint.

- **ONE extraction function, used by BOTH sides:** `extractWindow(grid, r, c)` →
  rows `[r-1 .. r+2]`, cols `[c-1 .. c+2]` (clamped to board), centered on the swap at `(r,c)` (which swaps cols c,c+1).
  This is a fixed ~4×4 window. **No "participating-cell" guessing** (that needs the solution, which live play lacks).
- **Canonicalize:** `KEY = shapeCache.canonShape(window)` — color-blind (first-appearance same/diff mask),
  position-free (bbox crop), mirror-folded. Garbage = `BoardSim.GARBAGE`; color-9 blockers stay color-9 (NOT garbage).
- **Invariant (the whole contract):** authoring and recognition BOTH call `extractWindow` + `canonShape` with the same
  rule. Same tactic on any board → same KEY. If the two sides ever use different windows, they will not match. Locked.

## The VALUE (the action) — what each KEY maps to
```
STORE[key] = {
  swaps  = { {dr, dc}, ... },   -- window-canonical-relative; place(sw, tf) -> live (r,c)
  kind   = "fire" | "setup",    -- fire = clears/chains now; setup = moves toward a future fire
  effect = { chain=N, clears=N, breaksGarbage=N, stopTime=N },  -- for FSM priority (real numbers)
}
```
`swaps` are in the canonical window frame (post mirror-fold). Recall maps them back with the live `tf` from canonShape.

## AUTHORING (board + recorded solution → entries) — per-swap, NOT per-chain
For EACH swap in the recorded solution:
1. `key, tf = canonShape(extractWindow(boardBeforeThisSwap, r, c))` — the local window at that swap.
2. record the swap in canonical-relative coords; tag `kind` (did THIS swap clear? fire : setup) + `effect`.
3. `STORE[key] = {swaps=..., kind, effect}` (keep the highest-value entry on collision).
So one chain solution yields SEVERAL small per-swap shapes (setup steps + the fire), each independently recognizable —
NOT one giant footprint. This is the change from the broken v0.

## RECOGNITION (bare board → plan) — same window, by construction matches
For each candidate swap `(r,c)` in the active band (top ~6 rows):
1. `key, tf = canonShape(extractWindow(grid, r, c))` — the SAME window rule as authoring.
2. `e = STORE[key]`; on hit, `place(e.swaps, tf)` → live swaps. Prefer FIRE; among fires prefer higher `effect`.
3. Miss on every candidate → return nil → caller falls back to live search.

## Shape kinds — fire AND setup (Brian: "add setup shapes so it knows how to MOVE things into place")
- **FIRE** — the window's swap clears/chains/breaks garbage NOW. The payoff.
- **SETUP** — the window's swap moves panels toward a fire (no immediate clear). Authored from solution swaps that
  don't clear but precede one. This is what lets the bot CONSTRUCT from a small library, not just finish.

## The contract in one line
`extractWindow` + `canonShape` is the shared language. Authoring writes small per-swap windows; recognition reads small
per-swap windows; they match because it's literally the same function. Few shapes, recognized everywhere. — B

---

## v2 direction — MULTI-MOVE shapes (Brian, 2026-06-17): "there's always a solve in 2-3 moves"
**Correction to v1:** a cache entry is NOT one swap — it's a PLAY. KEY = the pattern you see; VALUE = a **move
sequence** ("see this shape → swap, move up, swap"). v1 single-swap entries only catch immediate fires/breaks; the
real tactic is multi-move (slide a color to the garbage, make the 3-match). There's almost always a solve given
enough blocks (sparse boards = the "not enough blocks" caveat, handled later).

**Grounding (engine-measured, runtime colorGrid path):**
- FIRE reachable in: 1 move **47%** | ≤2 **60%** | ≤3 **60%** | none≤3 **40%** (235 puzzle boards).
- BREAK reachable in ≤3: only 14/91 garbage boards — but that's the SPARSE-board caveat (curated puzzles, few
  blocks near garbage); fuller gameplay boards reach far more.
- Mid-play authoring (single-swap, v1.5): **825 shapes (638 fire, 187 break)** from 44.6k solution states — the
  current committed library. Captures every tactic that appears mid-construction.

**The tension to resolve (why v2 keying is the hard part):**
- Shallow plays (≤3 moves) are also findable by a cheap LIVE search — so the cache's UNIQUE value is the DEEP
  sequences (5-8 move chains) too deep to search live. But deep chains have large, near-unique footprints (don't
  recur). So: shallow = searchable (cache optional), deep = unique (cache can't generalize). The bet (Brian's) is
  that a SMALL set of multi-move PLAYS recurs across boards — the v2 build must prove that with a minimal key that
  maps a recurring pattern → a verified sequence.

**Proposed v2 entry:** `KEY = canonShape(participating cells across the sequence)` → `VALUE = { seq = {{dr,dc}..},
kind, effect }`. Author by: for each board, short-search (≤3) a fire/break sequence; key the minimal pattern the
sequence operates on; store the sequence. Verify each on the real engine. Open question for Brian: key on the
START pattern (recognize early, commit to the play) vs the END pattern (the match) — that's the design call.
