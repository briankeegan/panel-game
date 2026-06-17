# Plan: garbage-break cache (B-track, 2026-06-16)

**Why it matters:** breaking garbage is the core of **survival under pressure** (the benchmark Brian wants) —
and it's also offense (a break opens stop-time → ride it with a chain). So the garbage-break cache is the
survival-critical sibling of the combo/chain cache.

## The mechanic
Garbage clears only when a **color match happens adjacent to it** — the match *breaks* the garbage, which
reveals colors that can then chain. Three ways, by frequency:
1. **3-match break** — the bread-and-butter: a 3-in-a-row of a color made next to garbage. ~most breaks.
2. **3+ break (4/5/6)** — a bigger combo adjacent to garbage breaks MORE garbage at once. Higher value
   (more stop-time, bigger clear). Same shape family, just larger.
3. **chain-into-garbage** — a chain whose cascade reaches the garbage. Less common, harder; this is the
   chain-mode / deepFit territory, biased toward reaching the garbage.

## The cache design (it's the combo cache + a garbage-adjacency layer)
The break pattern is just a **near-match positioned next to garbage**. So reuse everything from the combo
cache (`shapeCache` canonicalizer: color same/diff mask, position-free, mirror-folded) and add ONE layer:
- **KEY** = participating-color same/diff mask **+ a parallel GARBAGE-ADJACENCY mask** (which cells of the
  region touch garbage). Color-blind, position-free, mirror-folded — same normalization, so it collapses.
- **ANSWER** = the swap(s) that fire the match against the garbage (relative, rise-invariant frame). Same
  form as combo answers.
- **EFFECT tag** = how much garbage it breaks (1 row / N cells) → drives priority.

So an entry reads: *"a near-match shaped like THIS, with garbage on THIS side → swap HERE → breaks N garbage."*

## Variants → how each is cached
- **3-match:** author exactly like combos, but the matched run is adjacent to garbage. Cheap, high coverage.
- **3+ (bigger):** same, larger participating mask; tag the bigger EFFECT (breaks more) so priority prefers it
  when there's time.
- **chain-into-garbage:** use **chain-mode extension** (the fall-constrained one-ahead pattern-match) but bias
  each extension toward the move that breaks more garbage / reaches deeper into it. Falls out of the chain work.

## Authoring source (we already have the answers)
**The `clear_puzzles` sets ARE garbage-break puzzles** (novice/intermediate/advanced), with recorded solutions.
Author the garbage-break cache from them exactly like combos-from-combo-puzzles: replay the solution, find the
cells that break garbage, extract the (color mask + garbage mask) pattern → store the swap sequence. Plus the
earthquake sets (garbage shake). No new search needed — the answers exist.

## Live use (the survival loop)
Under pressure (garbage on the board): **scan for garbage-break patterns → recall → fire.** The cheap
pattern-match (no search) is exactly what survival-under-pressure needs — fast reactions. Priority/timing:
- **Don't just break for room** (framework: dig-for-count is BS). Break to **open stop-time, then ride it with
  a chain** (break → setup → chain). So a break that *also* starts a chain ranks above a bare break.
- When **critical** (about to top out), take the nearest safe break (survival over value).
- Bigger break (3+) preferred when there's time (more stop-time + clears more).

## Open questions / caveats
- **Reveal colors:** when garbage breaks it reveals specific colors (known pre-break via the engine). A smart
  break sets up to *chain off the revealed colors*. v1 cache can ignore reveals (just break); v2 keys on them.
- **Multi-cell garbage geometry:** big garbage blocks span cells; the adjacency mask must capture "which edge."
- **Timing:** breaking too early (no chain ready) wastes the stop-time window. Priority must weigh "break now
  to survive" vs "wait and break into a setup." Ties to the survival-vs-offense benchmark.

## Build order
1. (now) finish the combo/setup puzzle cache (proves the cache mechanism).
2. garbage-break cache v1: author 3-match + 3+ breaks from `clear_puzzles` (color mask + garbage mask).
3. wire the live scan (under pressure → match → recall) for survival.
4. chain-into-garbage via chain-mode extension; reveal-color keying (v2).
