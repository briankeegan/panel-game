# Handoff: Endless-mode "swap does nothing on a specific panel" bug

**Status:** Root cause not yet confirmed. Code fully traced; narrowed to 3 possibilities. Needs one live observation to close.

## Symptom (as reported)

- In **endless** mode (possibly the "vs self" variant, possibly with the **no-raise** option on), occasionally a swap **does nothing for one specific panel/cell**.
- Swapping **elsewhere works fine** — move the cursor to another pair and it swaps.
- Key clarification from repro attempts: it was **stuck / persistent**, not a one-frame blip. It stayed dead, did not fix itself after waiting.

## Swap pipeline (controller path)

Files: `common/engine/Stack.lua`, `common/engine/Panel.lua`.

1. `Stack:controls()` — `Stack.lua:715` sets `self.swapThisFrame = swap`.
   - **Rate-limit** at `Stack.lua:717`: if a swap is still queued from last frame (`swapQueued()`), this frame's swap is **silently dropped**. Code cites GitHub issue #624 ("swaps fail when spaced too closely, player not aware why").
2. `Stack:runPhysics()` — `Stack.lua:915` queues the swap at the **current cursor**: `panels[cur_row][cur_col]` ↔ `[cur_col+1]`, via `tryQueueSwap` → `canSwap`.
3. `Stack.lua:1079-1082` executes the queued swap next frame via `Stack:swap(row, col)` — note this **does not re-check `canSwap`**; it's checked only at queue time.

### The gates (`Stack:canSwap`, `Stack.lua:1375-1434`)
Silently returns false (→ `emitSignal("swapDenied")`) when:
- panels not horizontally adjacent / different rows (`:1376`)
- countdown or clock <= 1 (`:1379`)
- puzzle move-limit reached (`:1382`)
- **both panels empty** (`:1385`)
- either panel `not allowsSwap()` (`:1388`)
- **panel directly above cursor is `hovering`** (`:1402`)
- asymmetric-air-while-swapping edge cases (`:1409-1426`)
- WigglePay swap-stalling punishment (`:1429`)

### Per-panel gate (`Panel.allowsSwap`, `Panel.lua:695-714`)
Returns false when:
- `dont_swap` is set (`:698`)
- `isGarbage` (`:701`)
- state not in {normal, swapping, falling, landing} (i.e. matched/popping/popped/hovering/dimmed/dead block swap)

## Persistence analysis — why most causes are ruled out

The symptom is **persistent**, which eliminates everything that runs on a timer:

- **matched / popping / popped / hovering / landing** all decrement a timer to 0 and resolve (`Panel.lua` state `update`/`changeState` fns). Hover can't loop forever: `hoverState.update` decrements unconditionally (`Panel.lua:575`) and the bottom of any hover stack grounds out.
- **`dont_swap` always clears.** It is set *only* inside `Stack:swap` (`Stack.lua:1452-1471`), and only on panels already put into `swapping` state by `startSwap`. Every swap-completion path clears it: `swappingStateFinishSwap` (`Panel.lua:412`), `enterHoverState` (`Panel.lua:457`), and the pop-end `clear()` (`Panel.lua:566`). Even a match interrupting a swap ends in `clear()`. **There is no found path where `dont_swap` survives past the panel's current activity.** (Earlier "stuck dont_swap" theory was investigated and refuted on this basis.)
- **Rate-limit** (`Stack.lua:717`) drops swaps but is not position-specific.

## What remains — 3 persistent, position-specific causes

1. **Garbage in the cell** — `isGarbage` never allows swap (`Panel.lua:701`). A normal panel adjacent to a garbage block can't be swapped *toward* it. Persistent, positional, **by design**.
2. **Both cursor cells empty** — `canSwap:1385`. Cursor parked over a gap → swap does nothing until you move onto real panels. Persistent, positional, mundane.
3. **A genuine wedge (real bug)** — a panel left non-swappable in a way the code says shouldn't happen. If it's neither #1 nor #2, this is it, and **further static reading won't find it** — the panel's runtime state at the stuck moment must be captured.

## Next step (the one observation that decides it)

When it's stuck, identify **what occupies that cell and its neighbor**:
- **Garbage block** touching the cursor → cause #1 (working as designed).
- **Empty space** on a side → cause #2.
- **Two ordinary colored panels, no garbage, no gap** → cause #3, a real bug.

If #3: capture the live state of both cursor panels at the denial. Lightest possible probe — log in the `swapDenied` path (`Stack:tryQueueSwap` else branch, `Stack.lua:1365-1367`) the `row, column, color, state, dont_swap, isGarbage` of `panel1`/`panel2` and the panels at `row+1`. The `logger` is already required in `Stack.lua:4`; client logs land in `logs/client.log`. Reproduce once and the log names the exact gate.

## Open questions for the reporter
- 1P endless, or the 2-player "vs self" variant? (Determines whether garbage is even in play.)
- Was no-raise actually on?
- At the stuck cell: garbage, empty, or two normal panels?

## Key files
- `common/engine/Stack.lua` — `controls()` :680, `canSwap()` :1375, `tryQueueSwap()` :1355, `swap()` :1437, queued-swap exec :1079
- `common/engine/Panel.lua` — `allowsSwap()` :695, state machine :299-683, `dont_swap` set/clear sites (grep `dont_swap`)
