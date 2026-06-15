# Puzzles as a clean-fundamentals training source

A note for the **bot/model track**: the game ships 235 hand-authored puzzles, each
with its **optimal solution recorded in the same compressed-input format as the
replays**. They're a clean, optional, *technique-tagged* supervised source you can
pull from selectively — "the ones the player uses." This doc explains what's there
and how to choose. (Data track will build the puzzle→rows parser on request; held
for now.)

## Where & format

`client/assets/default_data/puzzles/Puzzles.json` — nested sets:

```
Puzzle Sets[] → (Puzzle Sets[] →) Puzzles[]
  Puzzle Type : "moves" | "chain" | "clear"
  Moves       : N        (for "moves" type; 0 for chain/clear)
  Stack       : color string — the starting board
  Solution    : compressed input string — the optimal way to solve it
```

- **235 puzzles, all 235 have a `Solution`.**
- Types: **moves** (70 — solve in exactly N swaps, N=1–5), **chain** (84 — build a
  chain), **clear** (80 — clear the whole board), +1 edge.

### `Stack` encoding
- Color digits, **read top→bottom, left→right; the LAST char is the bottom-right
  panel.** A full board is 72 chars (6 wide × 12 tall). `0` = empty, `1–6` = colors,
  `7` square, `8` metal, `9` garbage (same vocab as the row schema's `c`).
- Short stacks (e.g. `"3000033030"`) are just the **bottom rows**; the engine pads
  empty rows on top (`Puzzle:fillMissingPanelsInPuzzleString`).

### `Solution` encoding
- **Identical to replay inputs**: run-length compressed base64 input chars
  (`A45` = 45 idle frames, `Q1` = one swap, letters = cursor moves), decode with
  `common/data/InputCompression.lua` + `common/data/KeyDataEncoding.lua` — the same
  tools the parser already uses. So a puzzle re-sims exactly like a replay:
  `Puzzle → Match → feed Solution → step frame-by-frame → (board → move) rows`,
  emitted in the **frozen DATA_CONTRACT schema** with `source: "puzzle"` added.

## The selection key: technique-tagged sets

This is what makes "pull the ones the player uses" work — the sets are named by the
**technique** they teach, across skill tiers:

| Tier | Technique sets (counts) |
|------|--------------------------|
| classic | 6 sets × 10 (general intro) |
| beginner | combos (6), chains (4) |
| novice | combos (8), chains (4), convert_horizontal_chains (4), earthquake_chains (9), deeper_earthquake_chains (9), horizontal_chain_from_tower (3), clear_puzzles (17) |
| intermediate | chains, extended_horizontal_chains, chains_from_huge_tower, horizontal_chain_from_side, pre_setup_combo_chains, combo_chains, pre_setup_inserts, change_side_inserts, inserts (9), combo_chain_inserts, removes, openers, clear_puzzles |
| advanced | shoguns (10), transitions_1/2, clear_puzzles_1–6 (44) |

So: identify which techniques the **target player** actually uses, then pull the
matching sets.

## How to pick "the ones the player uses"

Two complementary signals, both derivable from the player's parsed corpus:

1. **Skill tier** — pull the tier matching the player's level (all our corpus is
   L10, i.e. strong → lean intermediate/advanced sets; beginner/novice as warmup).
2. **Technique fingerprint** — measure, from the player's rows, *how* they play and
   match it to technique sets. Cheap proxies from the data we already emit:
   - **Chain frequency/depth** → `chain`-type sets, `*_chains`, `earthquake_chains`.
     (Signal: runs of `matched/popping` board states spanning multiple clears; the
     `incoming`/`opp.sending` `chain:true` flag.)
   - **Combo usage** (big simultaneous clears) → `*_combos`. (Signal: many panels
     `matched` in one frame.)
   - **Insert/convert play** (swapping into a setup) → `inserts`, `convert_*`.
   - **Defensive clearing / digging garbage** → `clear_puzzles`. (Signal: SWAPs over
     garbage cells, like the `garbage_dig` sample.)

   A small script can score each player's corpus on these and rank the technique
   sets by relevance — then you pull the top sets only.

## How to use them (recommended)

- **Tag, don't blend.** Emit puzzle rows with `source:"puzzle"` so they never get
  silently mixed into a player clone.
- **Different distribution — use deliberately.** Puzzle boards are *frozen* (no rise,
  no incoming garbage, no opponent). Great for teaching *mechanics* (how to build a
  chain, how to clear), wrong for teaching *when to act under pressure*. Best as a
  **warmup/pretrain** signal or an upweighted "correct fundamentals" set, then
  fine-tune on the player's real games for style + pressure handling.
- **Small but pristine.** ~235 puzzles ≈ ~25k frames vs. millions of real frames —
  value is quality, not volume. Upweight accordingly if used.

## Asks / handoff

- Tell the data track **which technique sets** (or "score & pick top-K by the
  player's fingerprint") and we'll parse just those into `bot/data/puzzles_<tier>/`
  (or merged with `source:"puzzle"` tags), same schema, ready to mix at training.
- Default suggestion if you want a starting set: **advanced `chains` + `combos` +
  `clear_puzzles`** (matches strong L10 play) as a fundamentals warmup.
