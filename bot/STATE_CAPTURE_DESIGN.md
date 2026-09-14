# Design spec: complete, versioned, event-aware state capture (capture once, derive forever)

**Status:** proposal — needs data-track sign-off (shared `DATA_CONTRACT` / `FeatureEncoder` / corpus).
**Owners:** track A (live bot consumption + eval), data track (schema, FeatureEncoder, corpus re-parse),
track B (event stream feeds the timing work). **Author:** A, 2026-06-16.

## Problem
`bot/BoardState.extract` is the single conversion `engine Stack → struct`, consumed by THREE things:
the live bot (`BotClient`), the corpus parser (replays re-sim'd through the same engine), and the model
(`FeatureEncoder` → training features). It is **hand-curated, snapshot-only, and lossy**:
- Missing decision-critical STATE: `shake_time`, `peak_shake_time`, `rise_timer`, **`health`** (top-out
  grace), the bot's OWN `outgoingGarbage`, `garbageLandedThisFrame`, `speed`/`nextSpeedIncreaseClock`.
- Missing the entire EVENT stream: `matched`, `newChainLink`, **`chainEnded`**, `garbageMatched`,
  `panelLanded`, `swapDenied`, … — the bot reads levels, never edges.
- Every gap propagates to bot + corpus + model at once, and every fix forces a full corpus **re-parse**.

We discovered this the hard way: shake was missing, then health, then events — caught only ad-hoc.

## Principles
1. **Capture COMPLETE, not curated.** If the engine knows it and a decision could use it, capture it.
   No more "oops, missing X."
2. **Capture EVENTS, not just snapshots.** Per-frame `events[]` from the engine's signals — edges, not
   just levels. `chainEnded` = "window closing, fire now."
3. **Capture-then-DERIVE (the long-term lever).** The captured struct is the LOSSLESS source of truth.
   All features (frozenFrames, critical, danger, riseSoon, shake budget, …) are DERIVED downstream by
   `FeatureEncoder` / the eval — never baked into capture. → A new signal is a downstream re-derive,
   **never another engine re-parse.** Today's re-parse pain happens exactly once more, then never.
4. **Versioned schema.** Bump `DATA_CONTRACT` schema version; the struct self-describes.
5. **One extractor, live == replay.** Same function on the live stack and on re-sim'd replays, so corpus
   and live bot are identical BY CONSTRUCTION (preserves the existing faithfulness principle).

## Schema v-next (the complete captured struct)
Grouped; names indicative — data track owns the final contract.
- **board[r][c]**: `{ color, state, isGarbage, garbageId, reveal }` (reveal = predicted bottom-row color).
- **timers/invincibility**: `stop_time, pre_stop_time, shake_time, peak_shake_time, rise_timer, health,
  speed, nextSpeedIncreaseClock, displacement`.
- **garbage**: `incoming[] {w,h,metal,chain,eta}` AND `outgoing {pieces[], totalArea}` (own attack queue);
  `garbageLandedThisFrame[]`.
- **chain/active**: `chain_counter, n_active_panels, n_prev_active_panels, swapThisFrame, swappingPanelCount`.
- **geometry/cursor**: `width, rows, height, cur_row, cur_col, top_cur_row, columnHeights[], maxColHeight`.
- **clock**: `clock, stopWatch, wasToppedOut, has_risen`.
- **events[]** (THIS frame): each `{type, …payload}` from the signals —
  `matched{comboSize,isChain,metalCount,garbageCleared}`, `newChainLink`, `chainEnded`,
  `garbageMatched{count}`, `panelLanded`, `panelPop`, `panelsSwapped`, `swapDenied`, `newRow`,
  `garbagePushed`.

## Event capture mechanism
A tiny `StackEventRecorder`: on extractor init, `connectSignal` to each engine signal on the stack and
append `{type,payload}` to a per-frame buffer; `extract` drains the buffer into `events[]` and clears it.
Works identically live and on re-sim (the re-sim stack emits the same signals). Weak-keyed subs so it GCs.

## Derive layer (downstream, re-runnable, NO re-parse)
`FeatureEncoder` (model) and the bot's eval read the captured struct and compute features:
`frozenFrames = max(stop,pre_stop,shake)`, `critical = top-row occupied`, `danger`, `riseSoon`,
shake-budget-by-incoming-size, own-pressure, "chain just ended", etc. Changing/adding a feature = edit the
derive layer only. The captured corpus never moves.

## Migration (the one-time cost)
1. Bump `DATA_CONTRACT` schema version (data track).
2. Implement v-next `extract` + `StackEventRecorder` (one extractor, A + data review).
3. **Re-parse the corpus ONCE** to the complete capture (data track owns the run).
4. Port `FeatureEncoder` + the bot eval to derive from v-next.
5. After this: new features never re-parse. Done.

## Coordination / open questions for the data track
- OK to bump the contract version and own the corpus re-parse? Timeline?
- Where should the capture/derive split live — `FeatureEncoder` as the derive layer, or a new `derive.lua`?
- `events[]` size in the corpus — keep raw per-frame, or pre-bin? (raw is lossless; binning is downstream.)
- B's insert-catch timing work consumes `chainEnded`/board-sig-change events directly — same event stream.

## Interim note
Track A added `shakeTime / frozenFrames / critical` to `extract` as a down-payment (working, additive).
v-next SUBSUMES these — they'll be re-expressed as captured-state + derived-feature in the final schema.
