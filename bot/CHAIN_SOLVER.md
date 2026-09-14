# Deep-chain system — design & handoff

A cheap **chain evaluator** (its chain *depth* matches the engine; cascade *timing* is the engine's job) + a
**deep-board designer**, in `bot/chainSim.lua`. It answers two questions the bot has never been able to answer directly:

1. **"What is the deepest chain I can fire right now?"** — `bestChain(liveBoard)` → the swap + an exact-facts bundle.
2. **"What does a board that chains deep even look like?"** — `designDeep{}` packs a board and hill-climbs it.

The headline result that motivated this: a **full 6×12 board, packed, one swap → engine-verified 15–19 chains** on
every seed we tried. (Not a fluke — 5 independent seeds all landed 15–18 engine-verified; a 6th hit 19.) That reframes
chains: the depth was never in hand-baked chips, it's in **how the whole board is packed.**

## Verified findings (engine = ground truth)

| | depth |
|---|---|
| my old bottom-up "stack a unit" tower | 6 |
| full board, random packing | ~10 |
| full board, hill-climbed | **15–19**, engine-confirmed |
| theoretical ceiling (72 cells / 3) | 24 |

The fast grid sim (`simChain`) **matches the engine on chain depth** — verified 5/5 on the multi-seed test and on a deep
board (19 = 19). An earlier apparent "over-count" was a too-short engine run, not a sim flaw. Cascade *timing* can only
be estimated, so it's not reported in the bundle at all — `engineChain` returns it exact when needed.

## API (`bot/chainSim.lua`, engine-free except `engineChain`)

grid convention: `grid[r][c]`, r=1 bottom, c=1 left, 0 empty, 1..7 color, 9 wall.

- `M.gridFromStack(stack)` → pull a planning grid out of a live engine stack.
- `M.simChain(grid, sr, sc)` → `depth, panelsLeft` — fire one swap, cascade, count chain links. **Cheap primitive.**
- `M.deepestSwap(grid)` → `depth, r, c` — the deepest chain any single swap fires (cheap ranking).
- **`M.bestChain(grid)` → the full metadata bundle for that deepest swap. The brain's one call.**
- `M.chainInfo(grid, sr, sc)` → the same bundle for a *specific* swap.
- `M.hasMatch(grid)` → board already has a standing 3 (illegal chain start).
- `M.designDeep{colors=5, iters=300, seed=N}` → `grid, depth, r, c` — iterated local search; reliably 15–18, more iters → deeper.
- `M.engineChain(grid, sr, sc)` → `chain, finishFrame` — real depth **and exact cascade duration** on the engine. **Ground truth, slower.**

The **metadata bundle** (`bestChain` / `chainInfo`) — every **exact** fact the sim computes, so the brain re-derives nothing:

| field | meaning |
|---|---|
| `depth, r, c` | chain length + the swap |
| `cleared`, `left` | panels removed / remaining |
| `heightBefore`, `heightAfter` | stack height before vs after — *the drop is the escape* (e.g. 12 → 5 = 7 rows freed) |
| `headroom` | rows of slack to the 12-ceiling right now |
Every field is **exact** — the sim computes it precisely, and `depth` matches the engine. **Timing is deliberately NOT in the bundle**: cascade duration is only estimable, so it's left out entirely. If the brain needs how-long-it-plays-out, it calls `engineChain`, which runs the real engine and returns the exact `finishFrame`. The brain reads exact facts here; the *judgment* (fire vs pack, is the risk worth it) is all that's left to it.

## What a brain can do with it — signals only; states/timing are the brain's

`chainSim` is **stateless**. It provides numbers about a board and owns nothing else — no states, no priority, no
"when to fire," no danger handling, no cascade timing. All of that (RAISE / DANGER / OFFENSE / ORGANIZE, the spine, the
risk/timing calls) belongs to whoever runs the brain (`bot/EnvelopeBrain.lua`). The list below is **only what the tool
offers a brain to decide with — suggestions, not prescriptions.**

- **"Deepest chain available right now, with all its facts"** — `bestChain(gridFromStack(stack))` → the full
  metadata bundle (depth, swap, the height drop, `headroom` — all exact). A brain's offense reads
  it and routes the cursor to `(r,c)`. Replaces matching a fixed chip catalog that rarely lines up with the live board.
  (Cost: ~60 swaps, each fully cascaded — **unprofiled**; cache between board changes.)
- **A board score** — the bundle's `depth` is one number = "chain potential." A brain's organize can prefer moves that
  raise it on the predicted next board instead of drifting. (Could close the known organize gap — the lookahead is the brain's.)
- **Hypothetical scoring** — `simChain`/`chainInfo` are engine-free + deterministic, so a brain can score candidate boards
  *before* acting: the evaluator the continuous-planner wants.

**Facts vs decisions.** The tool carries every **exact** fact it can compute — how far the chain drops the stack, how
much headroom is left, what clears — so the brain never re-derives them. (Cascade *duration* it does NOT carry in the
bundle — that's estimable only; `engineChain` returns it exact when asked.) What the tool also does NOT do is the
**decisions**: deciding you're in danger, deciding whether firing now beats packing one more row, ordering priorities, or
sitting through the cascade. Note deep chains and danger are the *same axis* (a deep chain needs a near-full board, and
firing it is the escape — see the 12→5 drop above), so those calls are real and entirely the brain's. The tool hands
over the facts; the judgment is the only thing left.

**The reframe it *enables* (the brain's to adopt or not):** chains can be treated as a continuous score — chain
potential — rather than a static chip catalog to recognize. If a brain takes that view, the baked `CHAIN_*` chips become
reference shapes, not the mechanism. That's an option the tool unlocks, not a design it imposes.

## Design / generator use (outside the brain)

`designDeep{}` is a **deep-chain board generator**: puzzles ("solve this 17-chain"), bot stress-tests, training targets,
or seeding the planner with "this is what deep looks like." Engine-verify with `engineChain` before shipping any board.

## Open questions for whoever picks this up

1. **Cost budget for `bestChain` in the live loop** — per-decision is fine; per-frame needs caching (recompute only on
   board change). Measure in `EnvelopeBrain`.
2. **ORGANIZE search depth** — 1-move lookahead (greedy on `bestChain`) vs the planner's deeper search; where's the
   payoff knee.
3. **Reachability** — `designDeep` packs *arbitrary* boards; the brain can only reach states from the live board by
   legal moves + the rising stack. The organize target must be a *reachable* deep board, not any deep board.
4. **Garbage** — the sim is no-garbage. Live boards have garbage; `simChain` treats walls/garbage as blockers (color 9),
   which is safe but ignores garbage that will break. Compose with the CATCH reader (`bot/garbageReveal.lua`) when relevant.
5. **Timing lives only in `engineChain`** — the fast bundle carries no cascade-duration field on purpose (it'd be an
   estimate). If the brain needs how-long-it-plays-out, it pays for the engine call; everything in the fast bundle is exact.

## Files
- `bot/chainSim.lua` — the module (sim + bestChain + designDeep + engineChain + gridFromStack).
- `bot/CHAIN_GRAMMAR.md` — the feed-atom grammar (STEP/TOWER/… ) the baked `CHAIN_*` chips came from; reference shapes.
- `bot/EnvelopeBrain.lua` — where OFFENSE/ORGANIZE live; the integration target.
