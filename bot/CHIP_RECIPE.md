# Chip Family Recipe — how to add a new kind of chip

A **chip** = a recognizable board template + the swap(s) to play, engine-verified to fire 100%. We build each *family*
in the same four steps. This is the reusable plan.

## The 4 steps (per family)

1. **Get all the canonical solutions** — every board that is **one swap** from clearing the target, brute-forced and
   engine-verified, deduped by canonical shape, floor-anchored (no elevated duplicates).
   → `getComboShapes` (COMBO_N), `getSplitShapes` (COMBO_3_3 two-color 6).

2. **Get "1 away" (the 2-swap solve)** — reverse-construction: take each canonical solution, **displace one panel**
   with a FIRST swap inside a cursor radius; keep only boards that genuinely need BOTH swaps.
   → `getComboSetups` (COMBO_N_SWAP_2_MOVE_K), `getSplitSetups` (COMBO_3_3_SWAP_2).

3. **Get cascades** — a swap fires a trigger match; it clears; panels **fall**; a second wave fires. Reverse-construct
   from the wave-2 (post-fall) target by inserting/raising a trigger so the target breaks, then engine-verify the chain.
   → `getCascadeShapes` (COMBO_N_CASCADE_M), `getSplitCascadeShapes` (COMBO_3_3_CASCADE_3).

4. **Get "1 away" of the cascades** — apply step 2 to step 3: displace one panel of each cascade shape → the 2-swap
   solve of a cascade.
   → `getCascadeSetups` (COMBO_N_CASCADE_M_SWAP_2_MOVE_K), `getSplitCascadeSetups` (COMBO_3_3_CASCADE_3_SWAP_2).

Naming composes: `COMBO_<N>[_<N2>][_CASCADE_<M>][_SWAP_<S>_MOVE_<K>]`.

## Build big clears by COMPOSITION, never brute force

A single-color line longer than the board (7+) can't fit, and brute-forcing N-panel placements explodes
(C(48,7) ≈ 73M for N=7 — don't). **Build off what we already know:** a clear of size `N` is a two-color **split**
of `a + b = N` made by composing a known `a`-run with a known `b`-run.

- `getSplitShapes.enumerate(sa, sb)` is parametrized by run sizes → kind `COMBO_<sa>_<sb>`. It places a straight
  `sa`-run of one color next to a straight `sb`-run of another, undoes the boundary swap, and engine-verifies the swap
  fires exactly `sa + sb`. Its `produce()` bakes the size pairs we want (e.g. `{3,3}`=6, `{3,4}`=7).
- Example: **7 = 3 + 4** → `COMBO_3_4` (8 shapes), composed from the 3-runs and 4-runs we enumerate — no brute force.
- Run the same 4 steps on the split: shapes → 2-swap → cascade → cascade-2-swap, all parametrized by `(sa, sb)`.

So to "do N": pick a decomposition `a + b = N`, add the pair to the split generators' `PAIRS`, done.

## The gates (what makes a chip valid)

- **No pre-existing match** on the puzzle board.
- **Fires exactly the target** (engine truth — counts of each color cleared, e.g. N, or 3+3, or 3+3+3).
- **No-shortcut / win-gate** (steps 2 & 4 only): reject a board if **any single swap clears the WHOLE target**.
  A *partial* clear (e.g. one swap makes a 3-run that doesn't solve the puzzle) is FINE — it doesn't win, so the
  puzzle still needs both swaps. Gate on "single swap wins", never on "single swap makes any 3-run".
- **Cursor radius** bounds the setup swap (Manhattan distance from the fire); `_MOVE_K` records the cost.

## The shared machinery (don't reinvent)

- `bot/chipBake.lua` — the ONE authoring + writer. `author(g,sr,sc,kind,absSwaps)` → chip; templates are
  swap-anchor-relative, color classes for real colors (1–4), filler (≥5) is don't-care, and the empty fall-path below
  a swap target is marked must-be-empty. `writeAll` / `upsert` write **both** `chipCache.lua` (bot loads) and
  `chipCatalog.txt` (human view), deduped + stable-sorted → always 1:1.
- `bot/chipRegistry.lua` — generators self-register a `produce()`. `loadAll("bot")` scans `bot/get*.lua`.
- `bot/buildChipCache.lua` — the full build: `loadAll` then bake every registered `produce()`. **DYNAMIC** — never
  hardcode a generator here.

## To add a new family: write `bot/get<Family>.lua` with

1. `enumerate(...)` → records `{ g = board, sr, sc = fire anchor, kind, [s1 = setup swap] }`. (Steps 1–4 above.)
2. A CLI guarded by `arg[0]:match("get<Family>")` that prints the catalog **and self-bakes** its family:
   `bake.upsert("^<KIND PREFIX>", chips)`.
3. `produce()` → bake-ready records `{ g, sr, sc, kind, absSwaps = {{r,c}..} }` and
   `require("bot.chipRegistry").register{ name = "...", produce = produce }`.

That's it — the dynamic build, cache, and catalog pick it up automatically. Catalog symbols: `digit`=color ·
`.`=must-be-empty · `*`=don't-care · `[ ]`=swap; multi-swap chips render as ordered steps (setup → fire).

See memory `chip_dynamic_registry` and `combo_shape_catalog`.
