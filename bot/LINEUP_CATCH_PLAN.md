# CATCH (Lineup) — mode design & handoff

A new brain state that turns **your own breaking garbage** into a chain. As a garbage block on your
board opens, it reveals its colors **right-to-left**; CATCH reads each column as it opens and "tops off"
matching pairs underneath, so the freed panels complete vertical-3s → a chain back at the opponent.

It is a **MODE (brain state), not a static chip family** — its input is the *live* revealing garbage ×
your *live* board, which can't be enumerated offline. It is built almost entirely from brain logic + one
small live primitive (`topOff`).

---

## Fairness rule (hard constraint)

The bot may use **only on-screen information**, same as a human:

- A garbage block's colors are **off-limits while it is SEALED** (falling / sitting unbroken / grey).
- They become fair to read **only once the block is BREAKING and a column has POPPED** — read that column then.
- The **seed / `garbagePanelBuffer` / colors of future garbage are NEVER readable.** Reading them is cheating and is
  explicitly rejected (this was caught and removed during design).

---

## Verified engine mechanics (level 10, engine-measured — not assumed)

Frame constants: **FLASH=28, FACE=10, POP=7.**

When a garbage block is broken:

- The colors are assigned in **data** at the break frame, but the **visual reveal is staggered** — that stagger is what
  a player (and a fair bot) actually sees.
- The bottom row opens **one column at a time, RIGHT → LEFT, 7 frames apart (= POP).**
  Mechanism: `pop_time = POP × (onScreenCount − popIndex)`, with `sortByPopOrder` = right-to-left, bottom-to-top
  (`common/engine/checkMatches.lua`). A column is "open/readable" when its `timer ≤ pop_time`.
- For a 6-wide block: **c6 opens ~f45, then +7f per column leftward, c1 opens ~f77.**
- The freed bottom row **DROPS** (falls onto your stack) at: **drop ≈ f77 + 42 × (height − 1)**  (42 = POP×6 per extra row).
- **Only the bottom row** of a multi-row block converts per break; the rest stays garbage (re-breaks later).

### The budget is a time-gradient by column, with a big height bonus

| column | color readable at | lead before the drop |
|---|---|---|
| c6 (right) | ~f45 | most |
| c1 (left) | ~f77 | **1-row: ~0 · 2-row: ~42f · 3-row: ~84f** |

**Block HEIGHT is the main difficulty knob.** Tall blocks (which *chains* produce) give 40–80+ frames on **every**
column → fully reactive. A **1-row block is the only tight case, and only on its left side.**

**Execution cost** (for sizing): cursor ≈ 1 frame/cell, swap ≈ 3 frames to slide (consecutive swaps on different columns
pipeline). A micro-move ≈ `travel + ~1f`; the windows above fit ~10+ micro-moves; a catch is **1 swap per column**.
**Execution is never the bottleneck — the reveal/decision is.**

---

## The CATCH lifecycle (flow)

```
NORMAL ──garbage lands on your board──► ARMED ──you pop it──► OPENING ──► CATCH ──► FIRE ──► NORMAL
                                          │ organize while sealed
```

- **0 · NORMAL** — brain runs RAISE / DANGER / OFFENSE as today; watch for garbage landing on *your* stack.
- **1 · ARMED** — a sealed grey block sits on your board.
  - **Organize (background):** keep color pairs accessible under the block, *especially the left side* — the only
    columns you can't react to in time.
  - **Decide when to pop:** you control the trigger. Pop when organized enough **and** safe (not in DANGER). Sealed
    garbage is patient — choose the moment.
- **2 · POP** — make a match adjacent → it opens. Read **width + height** → compute the drop budget (above).
- **3 · CATCH** (reactive loop, every frame while opening):
  - read the columns that have **opened** (right→left, fair — popped only)
  - for each opened column showing color X: if a **cheap `topOff`** exists (an X-pair under it, or one swap away) → route it
  - **priority: right columns first** (most lead). Tall block → all columns; 1-row → right side only.
- **4 · FIRE** — block drops; topped-off columns complete vertical-3s → **chain out as counter-pressure**. Settle → NORMAL.

---

## Pieces to build (mostly logic + reuse)

| piece | what it does | new / reuse |
|---|---|---|
| **break detector** | "my garbage is opening" + which columns have popped (the pop ladder) | new, small |
| **column reader** | the visible color of each opened column (fair gate = its pop frame) | new, small |
| **`topOff(col, X)`** | a column has 2 of color X on top → the incoming freed X completes a vertical-3 | **new, small** (live recognition) |
| **scheduler** | right→left, greedy, within the drop budget | new, small |
| **organize** | keep coverage pairs ready (the prep half) | reuse/extend the "group colors toward a setup" search gap |
| **state wiring** | slot CATCH into the brain's priority | new, small |

> Note on `topOff`: this is exactly the **color-release vertical** we prototyped (a freed colored panel topping a
> 2-stack). We *removed* it from the shogun catalog because it was the wrong mechanism for shoguns — but it is exactly
> the right primitive **here**. It belongs as a **live recognition in CATCH**, not a static catalog chip (the color
> comes from the live reveal). Trivial to recognize: `column top-2 == [X,X]` and the opening column reveals `X`.

---

## Decision spine (where CATCH sits)

```
DANGER (don't top out)  >  CATCH (free chain off breaking garbage)  >  OFFENSE (build attacks)  >  ORGANIZE (dead frames)
```

A breaking block is a one-time opportunity — grab it — but **never at the cost of survival.**

---

## Scope guidance for the first pass

- **Target tall blocks + the right side** — that's ~all the value and the easiest mechanically.
- **Punt the 1-row left-side catch** (needs strong prep, low value) until the organize behavior is solid.
- The mode's strength is **gated on the organize behavior** — a known bot gap (the search junks panels with no drive to
  group colors). Building CATCH well naturally forces that forward, which is good.

---

## Implemented (the chip/recognition half — built + engine-verified, ready for the brain to call)

Two modules cover the mechanics/recognition half; the brain wires them into the state machine. Both are
engine-verified against the mechanics above.

**`bot/garbageReveal.lua`** — the fair reader (= break detector + column reader):
- `openColumns(stack)` → `{ [col] = color }` for columns whose breaking garbage has **POPPED** (fair gate
  `timer ≤ pop_time`); sealed / not-yet-popped columns are **absent**. *Verified: leaks nothing while sealed, then
  reveals c6→c1 right-to-left ~7f apart.*
- `breakingRow(stack)` → row the freed panels fall from (nil if nothing is breaking).
- `dropETA(stack)` → frames until the bottom row drops (the catch budget), read live from the block's timers.

**`bot/catchPrimitive.lua`** — the topOff (catch recognition):
- `findTopOff(grid, col, color)` → `nil` | `{already=true}` | `{swap={r,c}}` — can column `col` present 2 of `color`
  on top with **≤1 swap** so the freed panel completes a vertical-3. *Verified: recognition correct (already/swap/nil)
  and the engine confirms the vertical-3 fires in each case.*

| component (from the table above) | status |
|---|---|
| break detector / column reader | ✅ `garbageReveal.openColumns` · `breakingRow` |
| `topOff` | ✅ `catchPrimitive.findTopOff` |
| scheduler (right→left, budget) | ⬜ **brain** |
| organize (coverage prep) | ⬜ **brain** (+ the search organize gap) |
| state wiring (CATCH in the spine) | ⬜ **brain** |

**Brain glue (the loop), roughly:**
```
each frame, if garbageReveal.breakingRow(stack):
  budget = garbageReveal.dropETA(stack)
  for col,color in garbageReveal.openColumns(stack), iterate RIGHT->LEFT:
    t = catchPrimitive.findTopOff(grid, col, color)
    if t and (t.already or budget allows t.swap): route cursor + apply t.swap
```

---

## Open questions for the brain side

1. **Fair-to-read gate:** confirm "I know this column" = its **pop frame** (`timer ≤ pop_time`), not the data-assign
   frame. (Optionally verify the *client* shows color during the flash vs white-flash, to anchor it to f45 vs later.)
2. **Pop-timing strategy:** the ARMED→POP decision — when to trigger the break given organize state + danger.
3. **Color supply:** how the organize phase keeps a *routable reserve* (the real meta-skill behind catch-readiness).
4. **Multi-block / multi-row garbage:** `{3,4}`, `{5,5}`, etc., and successive breaks of a tall block (only the bottom
   row sheds per break — see `COMBO_GARBAGE` in `checkMatches.lua` for the block-size table).

---

## References

- Reveal/pop mechanics: `common/engine/checkMatches.lua` (`matchGarbagePanels`, `sortByPopOrder`, `convertGarbagePanels`,
  `COMBO_GARBAGE`); `pop_time`/`pop_index` in `common/engine/Panel.lua`.
- Brain architecture (state-first RAISE/DANGER/OFFENSE + useChips): `bot/EnvelopeBrain.lua`, `bot/CHIPS_BRAIN_PLAN.md`.
- The CATCH primitive (vertical top-off): `bot/catchPrimitive.lua`. The fair reveal reader: `bot/garbageReveal.lua`.
- Organize gap: the search doesn't group colors toward a setup (a known, separate issue this mode depends on).
