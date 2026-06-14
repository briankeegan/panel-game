# Bot ⇄ Data contract

The interface between the **data track** (replay → training rows; owner: data
agent) and the **bot track** (model `decide()` + `CursorController`; owner: bot
agent). Answers are ground-truth from the engine with `file:line` citations.

Status tags: **[DECIDED]** by data owner (authoritative), **[CONFIRM]** bot agent
please ack, **[DELIVER]** data owner will provide.

Shared imports — **both tracks import these, do NOT re-invent**:
- `client/src/network/PanelStateCodes.lua` — panel state ↔ numeric code.
- `common/data/KeyDataEncoding.lua` — input char ↔ 6-bit decode.

---

## MUST-ALIGN (breaks integration if we differ)

### 1. Index convention  **[DECIDED]**
Coordinates are **engine-native: 1-based, `[row, col]`**.
- **Row 1 = BOTTOM (floor); row 12 = top of play.** (`Stack.lua:120` — "1 being
  the bottommost row in play"; `Stack.lua:969` tops out by checking `panels[height]`.)
- **Col 1 = leftmost, cols 1–6.** Width is 6.
- `board[row][col]` matches the engine's `panels[row][col]`.
- Emitted `board` is a JSON array of rows ordered **bottom→top**: `board[0]` = engine
  row 1 (floor). (0-based array, but element 0 is the floor — stated loudly to kill
  off-by-one.)
- **Swap position = the LEFT cell of the pair** `(cur_row, cur_col)`; the swap is
  `(cur_row,cur_col) ↔ (cur_row,cur_col+1)` (`Stack.lua:916-918`, `:1362`). Reported
  as `[row, col]` 1-based.

### 2. Coordinate frame as the stack rises  **[DECIDED]**
- Grid is a **stable 6×N row frame**. `displacement` is a **pixel** offset (0–15,
  init 16, decrements to rise; at 0 a new bottom row is added and it resets)
  (`Stack.lua:123-126,255,1251`). **It does NOT shift row indices** — a cell keeps
  its row number across frames except on the discrete `new_row` event, where every
  panel shifts up exactly one row (`Stack.lua:1569-1582`).
- So: **row indices are a stable coordinate frame.** `displacement` is emitted as a
  scalar feature (0–15) for sub-row rise phase; the model should treat the grid as
  stable and use `displacement` only as "how close to the next row-push."

### 3. State ↔ action alignment  **[DECIDED]** ← the off-by-one that matters
Per `Stack:run()` (`Stack.lua:864-933`): `setupInput()` reads
`confirmedInput[clock+1]` → `controls()` → physics → cursor/swap/raise → `clock++`.
- A row's **observation = the board at the START of frame N** (clock==N, *before*
  `run()`), and its **action = `confirmedInput[N+1]`** (the input consumed during
  frame N). Running yields the board at frame N+1.
- The parser captures state **before** stepping, reads the about-to-be-consumed
  input as the label, then steps. **`state[N] → action[N] → state[N+1]`.** No off-by-one.

### 4. Perspective  **[DECIDED]**
Every row is from the **acting player's own seat** and is **seat-invariant**:
- `board`, `cursor`, `displacement`, `height/danger` = **that player's stack**.
- `incoming` = garbage **aimed at that player** (their `incomingGarbage` queue).
- Opponent is summarized in a small `opp` block (their height/danger + what they're
  sending), never mixed into `board`. The model never sees the opponent's grid (a
  human can't either — fair).

---

## CONFIRM (data owner answer; bot agent please ack)

### 5. Color & state vocab  **[DECIDED — use shared enums]**
- **Color ints** (`Panel.lua:108-111`): `0`=empty, `1–6`=normal colors, `7`=square,
  `8`=metal/shock, `9`=garbage. (Garbage cells also carry `isGarbage`/`metal`/
  `garbageId`/`width`/`height`/offsets — `Panel.lua:23-34`.)
- **State** emitted as the **numeric code** from `PanelStateCodes.lua` (matches the
  snapshot/wire convention): `normal=0, swapping=1, popping=2, matched=3, landing=4,
  hovering=5, falling=6, dimmed=7, dead=8, popped=9`. This file is the single source
  of truth — both tracks import it.

### 6. Garbage  **[DECIDED]**
- Incoming sized by **width × height in panels** (not linear count); flags
  `isMetal`, `isChain` (`GarbageQueue.lua:10-28`).
- **Timing in frames.** Earned at `frameEarned`; lands at `frameEarned +
  GARBAGE_DELAY_LAND_TIME` (60) after transit/telegraph (`GarbageQueue.lua:33,377`,
  `globals.lua:4-6`). `incoming[i].eta` is **frames until land** at observation time.
- **Landed garbage is in `board` cells** (panels with `isGarbage`+`garbageId`+`metal`+
  block `width/height`+offsets). **Pending garbage is only in `incoming[]`.** No double-count.

### 7. Idle / WAIT  **[DECIDED]**
Idle input = char **`"A"`** = all six bits false (`KeyDataEncoding.lua:19`,
`Stack.lua:941`). That is the **WAIT** class. Bit layout (per `docs/replays.txt`):
`Right=1, Left=2, Down=4, Up=8, Swap=16, Raise=32`; decode via `KeyDataEncoding`.

### 8. Per-row tagging  **[DECIDED]**
Every row carries: `id` (publicId, the key), `gameId`, `engineVersion` (for
version-correct re-sim & filtering), and `outcome` (`won`/`lost` from
`metadata.winnerId`). Frame index `frame`. (Name is intentionally **not** included —
id is the key.)

---

## ASKS (deliverables) — data owner

### 9. Canonical schema + sample records  **[DELIVER]**
One sample row each for: a **chain**, a **garbage-dig**, a **near-topout**, an **idle
stretch** — dropped in `bot/samples/`. Schema below; the bot track builds `decide()`
+ `CursorController` against real rows, not a lone snippet.

### 10. Decision stream vs raw  **[DECIDED — emit BOTH, data owns the collapse]**
The parser emits **both** per frame:
- `action.raw` — the lossless decoded input (swap/raise/up/down/left/right + char).
- `action.decision` — the collapsed class **`{ SWAP@[row,col] | RAISE | WAIT }`**,
  where pure cursor-move frames collapse into the surrounding decision (the
  `CursorController` regenerates navigation, so move frames aren't labels).

Data owns the move→decision collapse; emitting raw too lets us revisit the action
space without re-parsing. **[CONFIRM]** bot agent: is `{SWAP@pos, RAISE, WAIT}` the
final action space, or do you want move primitives kept as classes?

### 11. Validation slice + policy-replay harness  **[DELIVER]**
- A **held-out split** (by `gameId`, time-based cut) kept out of training.
- A **replay-the-policy harness**: re-sim a held-out game, at each decision frame ask
  a candidate policy and measure **frame-agreement** vs the recorded human decision —
  so a model is scored offline before it's wired into the live bot.

### 12. Shared constants  **[DECIDED]**
Index/color/state/input conventions are pinned **here** + the two shared enums
(`PanelStateCodes`, `KeyDataEncoding`). No second copy. If we need a derived helper
(e.g. board→feature-vector), it lives in one module both import.

---

## Emitted row schema (v0)

```json
{
  "id": 935, "gameId": 1087218, "engineVersion": "049", "outcome": "won",
  "frame": 612,
  "board": [ [ {"c":3,"s":0}, ... 6 cols ... ], ... 12 rows bottom→top ... ],
  "cursor": [7, 3],
  "displacement": 11,
  "height": 8, "danger": false,
  "incoming": [ {"w":3,"h":1,"metal":false,"chain":true,"eta":48} ],
  "opp": { "height": 6, "danger": false, "sending": [ {"w":2,"h":1,"eta":70} ] },
  "action": {
    "raw": {"char":"Q","swap":true,"raise":false,"up":false,"down":false,"left":false,"right":false},
    "decision": {"type":"SWAP","pos":[7,3]}
  }
}
```

- `c` = color int (0–9), `s` = state code (PanelStateCodes).
- Coords 1-based `[row,col]`, row 1 = floor. `board[0]` = floor row.
- One row per frame; rows grouped per `gameId`, files under the player `id`.

---

## Open items needing bot-agent ack
- **[CONFIRM] #10** action space: `{SWAP@pos, RAISE, WAIT}` final, or keep move primitives?
- **[CONFIRM] #5/#7** ack importing `PanelStateCodes` + `KeyDataEncoding` rather than redefining.
- Anything in §"Emitted row schema" you need added/renamed before I freeze it.

---

## Sign-off

- **Data track** — drafted; §1–8 answers are ground-truth from the engine
  (`file:line` cited), §9–12 are committed deliverables. Schema v0 is proposed,
  not frozen — awaiting bot-track ack on the three open items.
  — _Claude (data agent), 2026-06-14 23:59 UTC_

- **Bot track** — _pending ack. Respond inline below (edit this file):_
  - #10 action space: …
  - #5/#7 shared-enum import: …
  - schema add/rename: …
  - — _signed:_ ______ , ____-__-__ __:__ UTC
