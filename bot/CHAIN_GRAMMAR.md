# CHAIN grammar — the chip language for cascades

CHAIN chips are **cascades**: one swap fires a sequence of 3-clears, each fed by the fallout of the last, and the
whole board clears. They are not a big static catalog — they are **one building block, composed by rules**. This doc is
the language; `bot/getChainShapes.lua` bakes the verified instances.

## Notation (relative colors — only the colors that *matter*)

- `A` `B` `C` = **any distinct colors** (a chip cares which cells share a color, not the actual color)
- `.` = empty / don't-care
- `[XY]` = the swap (swap these two cells)
- A chain needs **only 2 colors** — see the alternation rule.

## The building block: FEED

Every link is the same atom: **a 3 clears → the gap it leaves drops panels → they land as the next 3.** A clear "feeds"
the clear above it. The only difference between primitives is the *orientation* of each 3:

```
STEP  (row feeds a row)        TOWER / CONVERT  (tower feeds a row)
. B B .                        . . B .
A A B A   [swap 3-4]           . . A .
                               . . A .
A clears flat, B's drop        . B B A   [swap 3-4]
into a B-row, one over         A stands as a column, clears, B drops into a B-row
```

## Rule 1 — two colors, alternating

By the time link `k+2` fires, link `k`'s color is already gone, so it is **free to reuse**. Every chain is just
**`A B A B A B…`** up the stack. You never need more than 2 colors (a fork/side-feed may borrow a 3rd).

## Rule 2 — feed up

Each clear is one row higher than the one that fed it. Fire the bottom swap and the reaction **climbs the stack** —
link 1 at the floor, link 2 one row up, link 3 up again. You build the tower upward; it fires bottom-to-top.

## Rule 3 — the connection table (what may feed what)

A chain is a **walk through this graph**. `R` = a row clears, `T` = a tower clears.

| feeds → | **Row** | **Tower** |
|---|---|---|
| **Row clears** | ✓ STEP | ✓ rise (rarer) |
| **Tower clears** | ✓ CONVERT | ✗ forbidden |

**Only `T→T` is illegal** — two towers back-to-back pre-match before the first can fire. Every other join is legal, so
towers and rows are one connected system: `R→R→R` (staircase), `T→R` (convert), `T→R→T→R` (woven), etc.

## Rule 4 — the staircase, and the fold

Stacking `STEP` shifts **one column right + one row up** per link. The board is 6 wide, so the rightward walk maxes at
**chain-4** (the 4th color lands in column 6). For deeper chains the staircase **folds back up-left** (mirror the step) —
that is how `CHAIN_5` and `CHAIN_6` are built. ~2 rows per link → a pure chain caps around 6 in a 12-row field.

## The baked chips (`getChainShapes.lua`, all engine-verified: pure-3, one swap, fully clears)

| kind | what it is | chain |
|---|---|---|
| `CHAIN_2` | the STEP atom (`R→R`) | 2 |
| `CHAIN_3`..`CHAIN_6` | STEP stacked (staircase + fold), 2 colors alternating | 3–6 |
| `CHAIN_TOWER` | the CONVERT atom (`T→R`) | 2 |

To go further: extract the remaining primitives (earthquake, from-tower) the same way, and add fork/merge (one clear
feeding two branches — a 3rd color). See [[chain_primitives]].
