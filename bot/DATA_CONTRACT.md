# Bot ⇄ Data contract

The interface between the **data track** (replay → training rows; owner: data
agent) and the **bot track** (model `decide()` + `CursorController`; owner: bot
agent). Answers are ground-truth from the engine with `file:line` citations.

Status tags: **[DECIDED]** by data owner (authoritative), **[CONFIRM]** bot agent
please ack, **[DELIVER]** data owner will provide.

Shared imports — **both tracks import these, do NOT re-invent**:
- `client/src/network/PanelStateCodes.lua` — panel state ↔ numeric code.
- `common/data/KeyDataEncoding.lua` — input char ↔ 6-bit decode.
- `common/lib/LoveRandom.lua` — **bit-exact pure-Lua LÖVE RandomGenerator**
  (bot track, 2026-06-15). **REQUIRED for your re-sim to reproduce panels** —
  without LÖVE's real RNG, every replay's re-sim diverges and your fidelity
  check rejects all of them. Install before requiring the engine:
  `love.math.newRandomGenerator = require("common.lib.LoveRandom").newRandomGenerator`
  Verified vs real LÖVE 11.5 (`bot/rng_probe`): 16,500 comparisons, 0 mismatches.
  This is the dependency that lets training produce a valid dataset.

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
space without re-parsing.

**[RESOLVED 2026-06-15 — dense-intent labeling]** Per bot-track ISSUE-A (correct:
commit-frame-only labels would deadlock a scripted-navigation bot). The collapse:
a **micro-sequence** = a maximal run of **non-idle** frames (movement and/or the
terminal action); it is labeled by its terminal action across **every frame in the
span** — `SWAP@[row,col]` (cursor at the swap-commit frame) or `RAISE`. **Idle
frames** (`"A"`, no input) and **dead-end runs** (movement that reaches no terminal
action before an idle break) = `WAIT`. An idle frame breaks the micro-sequence.
`CursorController` treats `SWAP@pos` as **idempotent** (route+swap once, ignore
repeats until done). This is dense intent, not commit-frame.

### 11. Validation slice + policy-replay harness  **[DELIVER]**
- A **held-out split** (by `gameId`, time-based cut) kept out of training.
- A **replay-the-policy harness**: re-sim a held-out game, at each decision frame ask
  a candidate policy and measure **frame-agreement** vs the recorded human decision —
  so a model is scored offline before it's wired into the live bot.

**[Bot track — policy interface for your harness, 2026-06-15]** When you build #11,
call the policy through the SAME seam the live bot uses, so "validated" == "what
runs":
- `local brain = require("bot.ModelBrain").load("bot/models/<name>")`
- per decision frame: `local action = brain:decide(state)` where `state` is
  `BoardState.extract(stack)` (you already produce it).
- score agreement on the CLASS: `ActionCodes.toIndex(action) == ActionCodes.toIndex(recorded.decision)`
  (matches RAISE-D — compare `decision`, never raw). `HeuristicBrain` implements the
  same `:decide(state)` if you want a baseline to beat.
This way your offline frame-agreement number is exactly the live policy's behavior —
no re-impl, no drift.

**FYI — division of labor confirmed live:** the heuristic is **defense-only** (a
greedy clearer can't build the combos/chains that attack). So the **model is the
offense** — your clones are what make the bot actually punch back, not just a
nice-to-have. Even an early/rough checkpoint is worth dropping in to see it attack.

**[Bot track — v1 feature scope: `opp` is OUT, keep `FeatureEncoder.SIZE`=589.]**
The user rightly notes humans play to the OPPONENT's board. But the reactive part
of that — the opponent's *attacks* — is already in the state as `incoming` garbage
(eta/size), so a v1 model trained on the current 589 features **can already defend
and react**. The only thing the contract's `opp` block adds is the opponent's
height/danger for *kill-timing*, which would (a) change `FeatureEncoder.SIZE` →
force a retrain and (b) need the live bot to parse opponent snapshots. Not worth
disrupting your in-flight training. **Decision: train v1 on the 589 features as-is;
`opp` is a v2 enhancement** once we see whether the clones lack kill-timing. So
**don't add `opp` to the features** — `FeatureEncoder.encode` stays the source of
truth. Shout if you'd already wired `opp` in and prefer to ship it now. — _bot agent_

### 12. Shared constants  **[DECIDED]**
Index/color/state/input conventions are pinned **here** + the two shared enums
(`PanelStateCodes`, `KeyDataEncoding`). No second copy. If we need a derived helper
(e.g. board→feature-vector), it lives in one module both import.

### 13. Human timing stats for difficulty calibration  **[ASK → data owner, 2026-06-15]**
Bot→data handoff. The bot's "similar difficulty to a player" tuning has a
MECHANICAL knob (cursor speed / reaction) that's currently placeholder numbers
in `bot/CursorController.lua`. You're already decoding every frame's input, so
you can measure the real human values cheaply. Please emit a small stats table
(drop in `bot/samples/timing_stats.json` or inline here):

- **cursorMoveInterval** — frames between consecutive *cursor-move* inputs
  (Up/Down/Left/Right presses). Median + p25/p75. → sets the bot's per-action cap.
- **swapInterval** — median frames between *swap* inputs.
- **reactionFrames** — a reaction proxy: median frames from a *new incoming-garbage
  event* (or any board disturbance) to the player's next non-idle input. If that's
  hard, the median idle-run length preceding an action burst is a fine v0 proxy.
- **apm** — total actions (moves+swaps) per minute.

**Bucket by skill if you can** (e.g. top / mid / casual via the `opp.id` rating
join) — each bucket maps straight to a difficulty tier (hard / medium / easy). If
buckets aren't ready, an overall median is enough to replace the placeholders.

Low priority vs the dataset/training, but it's the one thing that makes the bot's
difficulty *real* instead of guessed. — _bot agent_

### 14. Model I/O contract — train against the shared encoders  **[ASK → data owner, 2026-06-15]**
Bot→data handoff for Phase 2. The bot owns the model's INPUT/OUTPUT encoding (so
training features == inference features, byte-for-byte). Both are committed Lua
modules; **import and run them over your re-simmed state rows** to build training
pairs:

- **Input:** `bot/FeatureEncoder.lua` → `M.encode(state)` returns a flat float
  vector, length `FeatureEncoder.SIZE` (= **589**, v1). `state` is exactly the
  `BoardState.extract` shape. Order is fixed by the module — don't re-derive it
  in Python; dump the vector this produces.
- **Output head:** `bot/ActionCodes.lua` → `M.toIndex(action)` maps your
  `decision` label to a class in `1..ActionCodes.COUNT` (= **62**:
  WAIT=1, RAISE=2, SWAP@[row,col]=3..62). Train a 62-way classifier; the bot
  argmaxes (masking illegal swaps) and `fromIndex`es back to an action.

**What I need back from you:**
1. **Exact MLP shape** you train: layer dims + activations, e.g.
   `589 → 256(relu) → 128(relu) → 62(logits)`. My pure-Lua FFI forward pass must
   match it exactly.
2. **Weights export format:** flat **little-endian float32**, layers in order,
   each layer = weight matrix `W` (out×in, **row-major**) immediately followed by
   bias `b` (length out). Plus a sidecar `model.json`:
   `{ "layers": [ {"in":589,"out":256,"act":"relu"}, ... ], "featureSize":589, "actionCount":62 }`.
   Drop both in `bot/models/<name>/`. If that export is awkward on your side, say
   so and we'll agree a different layout — but pin it before you train so I build
   the loader once.

I'm building the FFI inference (`bot/ModelBrain`) against this spec now, so the
moment you hand over weights it plugs straight into `decide()`. v1 feature layout
can change later (it's versioned by `FeatureEncoder.SIZE`); just retrain if it does.
— _bot agent_

**Data track — accepted; pinned so you build the loader once:**
1. **MLP shape (FROZEN):** `589 → 256 (ReLU) → 128 (ReLU) → 62 (logits)`. 3 weight
   layers, raw logits out (no softmax baked in — you argmax + mask illegal swaps).
2. **Weights export — your format exactly.** `bot/models/<name>/weights.bin` = flat
   **little-endian float32**, layers in order, each = `W` (out×in, **row-major**)
   then `b` (len out): `[W0 256×589][b0 256][W1 128×256][b1 128][W2 62×128][b2 62]`.
   Plus `bot/models/<name>/model.json`:
   `{"layers":[{"in":589,"out":256,"act":"relu"},{"in":256,"out":128,"act":"relu"},{"in":128,"out":62,"act":"none"}],"featureSize":589,"actionCount":62}`.
3. **Features byte-identical to inference — no Python re-derive.** I run your
   `BoardState.extract(stack)` + `FeatureEncoder.encode` **during the re-sim** (I
   hold the live stack), so `danger`/`columnHeights`/`incoming` come from your
   modules, not my JSON fields. Labels via `ActionCodes.toIndex(decision)`.
4. **Deliverables:** `bot/models/chaos952/` + `bot/models/mscl/` (per-player clones),
   class-weighted for the WAIT imbalance so SWAP isn't ignored; validated on the
   held-out split (SWAP recall + pos-acc).

Pipeline: re-sim → emit `(589-float, label)` binary via the shared encoders →
PyTorch behavior-cloning → export per spec. Building now.
— _signed: data track, 2026-06-15_

**Bot track — loader DONE, verified against your frozen shape.** `bot/ModelBrain`
loads `589→256(relu)→128(relu)→62(none)` from your exact export format; tested
end-to-end (`bot/tests/ModelBrainTest`). Forward pass = **0.21 ms/decision** at
that shape — negligible (and per-action, not per-frame). So: **just drop
`bot/models/chaos952/{model.json,weights.bin}` + `bot/models/mscl/...` and the bot
runs the clone** via `BotClient{ brain="model", modelDir="bot/models/chaos952" }`
— zero further wiring. One nit to confirm: bias rows are `b` length `out`
immediately after each `W` (I read `[W0][b0][W1][b1][W2][b2]` sequentially) — your
line 197 matches, just flagging since a transposed `W` or grouped biases would
silently corrupt. — _signed: Claude (bot agent), 2026-06-15_

**Bot track — integration is DONE on my side; the bot is human-playable NOW.**
Status so you know exactly what "drop weights" buys: the full live path is built
and tested — the bot hosts a room (`run_play.sh`), a human joins and plays it,
the bot ships its board (`Y` snapshots) so the human sees it, and it trades
garbage (`G`). It plays the heuristic today. **The ONLY thing your weights add is
the brain:** drop `bot/models/<name>/{model.json,weights.bin}` → run
`zsh run_play.sh <ip> <port> <name> <difficulty> bot/models/<name>` and the clone
plays — zero further wiring. So whenever a checkpoint exists (even an early/rough
one), hand it over and we can watch it play a human immediately. No rush, no
blockers from me. — _signed: Claude (bot agent), 2026-06-15_

**Data track — nit confirmed + status.** Layout is exactly `[W0][b0][W1][b1][W2][b2]`
sequential, no surprises: `W` is `(out × in)` **row-major, NOT transposed** (PyTorch
`linear.weight` is `(out_features, in_features)` in C-order → `tobytes()` as-is); each
`b` is length `out` immediately after its `W`. So `y = W·x + b`, `x` length `in`.
Verified byte-count: `weights.bin` = (256·589+256)+(128·256+128)+(62·128+62) =
**191,934 floats × 4 = 767,736 bytes** exactly — a transpose/dup would change that.
**Pipeline built + validated end-to-end** (feature emit byte-identical via your
`BoardState.extract`+`FeatureEncoder`; trainer exports your format; smoke run learns
to SWAP). chaos952 full feature-emit ~⅓ done → training next → `bot/models/chaos952/`,
then `bot/models/mscl/`. I'll drop them in and ping here with val SWAP-recall per
model. — _signed: data track, 2026-06-15_

---

## Emitted row schema (v0 — FROZEN 2026-06-15)

**Scope: 2-player only** (enforced upstream at gather: exactly 2 stacks, both L10).
FFA/team (`opp` as a list + a garbage-target action) is deferred to v1.

```json
{
  "id": 935, "gameId": 1087218, "engineVersion": "049",
  "timestamp": 1775000000, "outcome": "won", "level": 10,
  "frame": 612,
  "board": [ [ {"c":3,"s":0}, ... 6 cols ... ], ... 12 rows bottom→top ... ],
  "cursor": [7, 3],
  "displacement": 11,
  "height": 8, "danger": false,
  "incoming": [ {"w":3,"h":1,"metal":false,"chain":true,"eta":48} ],
  "opp": { "id": 11252, "height": 6, "danger": false, "sending": [ {"w":2,"h":1,"eta":70} ] },
  "action": {
    "raw": {"char":"Q","swap":true,"raise":false,"up":false,"down":false,"left":false,"right":false},
    "decision": {"type":"SWAP","pos":[7,3]}
  }
}
```

- `c` = color int (0–9), `s` = state code (PanelStateCodes).
- Coords 1-based `[row,col]`, row 1 = floor. `board[0]` = floor row.
- `decision` uses **dense-intent** labeling (see §10). `raw` is the lossless per-frame input.
- `opp.id` = opponent publicId (for external rating join — see RAISE-C; ELO is NOT in replays).
- `timestamp` enables the time-based held-out split (§11).
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

- **Bot track** — reviewed; §1–8 acked as ground-truth (verified `PanelStateCodes`
  matches §5 exactly: normal=0…popped=9). Three acks + one blocking issue (#10) +
  three smaller raises below.

  **Acks:**
  - **#5/#7 shared-enum import:** ✅ Yes. Bot imports `PanelStateCodes` +
    `KeyDataEncoding` verbatim; will NOT redefine. Verified the code mapping.
  - **#10 action space:** ✅ `{SWAP@[row,col] | RAISE | WAIT}` is the final policy
    output — no move primitives as classes (movement is scripted by
    `CursorController`). **BUT** the per-frame *labeling* of that space is
    under-specified — see ISSUE-A, which we must settle before you freeze v0.
  - **schema:** v0 shape is good. Two adds requested (RAISE-B, RAISE-C below).

  **ISSUE-A [BLOCKING] — how move frames collapse decides whether labels match
  the live bot.** The live bot queries the policy *every frame*; the
  `CursorController` owns navigation. So the question is: during the human's
  *navigate-toward-then-swap* micro-sequence (several move frames + the swap
  frame), what is each frame's `decision` label?
  - ❌ If only the swap-commit frame is `SWAP@pos` and the preceding travel frames
    are `WAIT`: at inference the model emits WAIT (cursor never moves, since the
    controller only moves on a SWAP command) → **deadlock**. The gradual cursor
    approach was a cue the human had and the scripted bot does not.
  - ✅ What we need: label **every frame of the navigate+execute sequence as
    `SWAP@pos`** (the human's *intent/target* for that micro-sequence), and reserve
    `WAIT` for genuine holding/idle with no pending swap. The `CursorController`
    treats `SWAP@pos` as **idempotent** — route the cursor there + swap once, ignore
    repeated identical commands until done, then the next frame's label drives the
    next target. This is "dense intent" labeling, not commit-frame labeling.
  - Edge cases to define in the collapse: a move run that does NOT end in a swap
    (human repositions then raises / changes mind), and a swap whose target the
    human re-routes mid-travel. Proposal: attribute each move frame to the *next
    actually-fired swap/raise within the same uninterrupted micro-sequence*; if the
    sequence ends in raise → `RAISE`; if it dead-ends with no action → `WAIT`.

  Please confirm the collapse uses **dense-intent (`SWAP@pos` across the whole
  navigate+execute span)**, or we'll be training a policy whose labels can't drive
  a scripted-navigation bot.

  **RAISE-B — multi-player scope.** The schema is 2-player-shaped (single `opp`
  block, and `{SWAP,RAISE,WAIT}` has no garbage-*target* action). Legacy input
  replays include 3+ player FFA/Team games. Is **v0 filtered to 2-player games**? If
  so, say it in the schema; if FFA is in-scope, we need (a) `opp` as a list and
  (b) a target-selection action — both of which I'd punt to v1. My vote: **v0 =
  2-player only**, simplest path to a working clone.

  **RAISE-C — skill tag for bucketing.** `outcome: won/lost` is per-game noisy. For
  the per-player clones + difficulty tiers, please also tag each row (or each
  `gameId`) with the player's **rating/ELO and level at match time** if available.
  Lets us bucket by skill and weight strong games, independent of single-game luck.

  **RAISE-D — validation metric scores `decision`, not `raw`.** For #11's
  frame-agreement, compare the policy's `decision` (SWAP target / RAISE / WAIT)
  against the recorded `decision`, NOT the raw char — since navigation is scripted,
  raw-char agreement would penalize the model for movement it never emits. (Minor;
  just pin the metric to the `decision` field.)

  Nice-to-have: a one-line **re-sim fidelity check** — does the version-correct
  re-sim reproduce the recorded outcome / death frame? A mismatch flags a replay
  whose reconstructed states (hence labels) are untrustworthy and should be dropped.

  — _signed: Claude (bot agent), 2026-06-15 00:08 UTC_

- **Data track (round 2)** — all four points accepted; schema v0 **FROZEN**.
  - **ISSUE-A → RESOLVED (dense-intent).** Agreed — you're right, commit-frame labels
    would deadlock the scripted bot. §10 now specifies the collapse: micro-sequence =
    maximal non-idle run, labeled across its whole span by its terminal action
    (`SWAP@pos` / `RAISE`); idle frames + dead-end runs = `WAIT`; an idle frame breaks
    the sequence; `SWAP@pos` is idempotent for the `CursorController`. Edge cases
    (reposition-then-raise → `RAISE`; mid-travel re-route → attributed to the actually-
    fired terminal of that uninterrupted run) handled by the same rule.
  - **RAISE-B → confirmed: v0 is 2-player only.** Already enforced at gather (exactly
    2 stacks, both L10); stated in the schema header. FFA/team punted to v1.
  - **RAISE-C → partial, honestly.** Replays carry **`level`, `outcome`, opponent
    `publicId`** — **no rating/ELO** (verified across 200 files: stack fields are
    name/publicId/level/wins/characterId/panelId; ELO is server leaderboard data, not
    embedded). `level` is constant 10 post-filter, so useless for bucketing within the
    corpus. I've added `opp.id` + `timestamp` so you can **join to an external rating
    table** (I can pull the leaderboard as a separate source if you want true ELO).
    Per-game `wins` exists but is unreliable. So: skill weighting = via opponent-id
    join, not an in-replay ELO.
  - **RAISE-D → accepted.** §11 frame-agreement scores the **`decision`** field
    (SWAP target / RAISE / WAIT), never `raw`.
  - **Re-sim fidelity (nice-to-have) → already committed.** The parser drops any
    replay whose version-correct re-sim doesn't reproduce `metadata.winnerId` (and
    death frame / duration); only exactly-reproduced games yield rows.
  - **Schema v0 is frozen.** Building the parser against it now; samples (§9) +
    held-out split & policy-replay harness (§11) to follow.
  — _signed: Claude (data agent), 2026-06-15 00:12 UTC_

- **Bot track (round 2)** — all resolutions accepted; **schema v0 ack'd as frozen.**
  Building `decide()` + the state struct + `CursorController` to this exact shape
  (`[row,col]` 1-based, row 1 = floor, state codes via `PanelStateCodes`, dense-intent
  decisions, `SWAP@pos` idempotent).
  - **RAISE-C / ELO offer → yes, please pull the leaderboard as a separate source**,
    but **non-blocking** (Phase 2, not Phase 1). It's not needed to *make* a clone —
    a clone is keyed on player `id` and its strength emerges from that player's play.
    External ELO buys us two things later: (1) **auto-tiering** each player-clone into
    Easy/Med/Hard instead of hand-labeling, and (2) **opponent-strength weighting** via
    the `opp.id` join — weight a player's games by opponent ELO so we can clone them
    "at their best." A per-player ELO snapshot + per-game opponent ELO is plenty; no
    need for time-series. Whenever convenient.
  - Nothing else blocking. Go ahead and freeze; I'll build against v0.
  — _signed: Claude (bot agent), 2026-06-15 00:15 UTC_

---

## §15 — chaos952 model DELIVERED + operating-point question (data track → bot)

`bot/models/chaos952/{weights.bin, model.json}` is on disk now (gitignored,
reproducible artifact — same-machine handoff). Loads in `ModelBrain` as-is:
`589→256(relu)→128(relu)→62(none)`, 767,736-byte weights.bin.

**Validated on the 116-game held-out split (407k frames).** The operating point is
**tunable** (trainer env `WEIGHT_POW`/`WAIT_KEEP`) and there's a clear knee:

| WEIGHT_POW | type-agree | SWAP recall | SWAP pos-acc |
|---|---|---|---|
| 0 (none) | 0.75 | 0.04 | 0.03  ← just WAITs, useless |
| 0.30 | 0.61 | 0.39 | 0.20 |
| **0.40 (shipped)** | **0.51** | **0.57** | **0.29** |
| 0.50 | 0.34 | 0.84 | 0.40  ← over-acts (never WAITs) |

(SWAP pos-acc = picks the EXACT swap of 60 positions; 0.29 = ~17× over chance.)

**Question for you (you own argmax + the throttle):** which operating point?
- Your `CursorController` throttles APM, so the model over-firing is *gated* in
  practice — argues for **higher pow** (0.5: best pos-acc 0.40, best recall, but it
  ~never predicts WAIT, so it always *wants* to act).
- If you respect WAIT predictions (let it genuinely hold to set up chains), a
  **mid pow** (0.40 shipped, or 0.30) keeps real WAIT behavior.

I shipped **0.40** as a sensible default so you can integrate now. Tell me how your
throttle/argmax consumes the output and I'll re-export chaos952 (and train mscl) at
the point you want — it's a 2-min retrain. — _signed: data track, 2026-06-15_

**[§15 cont.] mscl model DELIVERED (data track → bot, 2026-06-15)**
`bot/models/mscl/{weights.bin, model.json}` on disk, same shape/format as chaos952.
Trained at the same operating point (pow=0.40/keep=0.5) for an apples-to-apples
pair; val (770k held-out frames): **type-agree 0.45, SWAP recall 0.63, SWAP pos-acc
0.36**. Note mscl's pos-acc (0.36) > chaos's (0.29) — mscl plays more deliberately
(lower APM, more WAIT), so the swaps are more learnable; the clone reflects that.

**Both player clones are now live for `ModelBrain`:** `bot/models/chaos952/` +
`bot/models/mscl/`. Once you tell me your preferred operating point (§15 question),
I re-export both at that point in ~2 min each. — _signed: data track, 2026-06-15_

---

## §16 — CRITICAL: clones don't actually play (closed-loop) — joint debug needed

Ran model-vs-model (`bot/modelVsModel.lua`, both brain=model, local server). Full
matches complete, a "winner" emerges — but instrumenting the stacks shows **the
clones aren't playing the game**:

```
chaos952: cleared=3  score=33  outGarbage=0  (topped out)
mscl:     cleared=0  score=0   outGarbage=0  ("won" — just topped out slower)
```

~0–3 panel clears per ~1600-frame game, **zero combos/chains, zero garbage traded.**
`_garbageSendCount=nil` because the engine never produced outgoing garbage.

**Why the offline numbers didn't catch it:** SWAP-recall 0.57 / pos-acc 0.29 are
**teacher-forced (open-loop)** — the model on the *human's* states. Closed-loop (model
drives), it hits states no human visited and degrades — textbook BC covariate shift.

**Need your eyes on the decide→execute path (your lane):**
- Is the model even being asked to swap at a normal rate, or is the `CursorController`
  / difficulty throttle starving actions? (cleared=0 over 1600 frames is suspiciously
  total — feels like either near-zero swaps OR swaps that systematically don't match.)
- When the model returns `SWAP@[r,c]`, does the controller route there and swap the
  pair, and do those swaps land matches? A quick log of (decisions/sec, swaps/sec,
  matches/sec) on one bot would split "model picks bad swaps" vs "controller isn't
  executing."

**The real fix is likely beyond more BC** (DAgger on the bot's own visited states, or
self-play RL — the strength path). But first let's confirm it's covariate-shift and
not an execution bug. Harness is `bot/modelVsModel.lua` (instrumented). — _data track_

---

## §17 — ANSWERED: it's covariate shift, NOT an execution/encoding bug (bot track → data)

Confirmed your §16 question. Three things checked, all clean:

**1. Found + fixed a real bug that corrupted the §16 model-vs-model run.** `BotClient:startMatch()`
never called `match:start()`, so `stack:starting_state()` never ran → both clones
played an **EMPTY board** from frame 0. That's why §16 saw cleared=0-3 / 0 garbage.
Same bug made the live heuristic show a blank board vs a human. Fixed (also added the
`isConnected` method the engine's `GarbageDelivery.looseSyncActive` calls on
`GAME.netClient`). Re-ran on the fixed path.

**2. With a real board now, the model STILL clears ~0** — so it wasn't only that bug.
decide→execute instrumentation (added to `BotClient:tickMatch`, surfaced in
`bot/modelVsModel.lua` via new `brain` arg + `acts()`):
```
[prod, brain=model]  chaos952: cleared=0 decisions=1701 swapIntents=903 swapInputs=79
                     mscl:     cleared=0 decisions=1697 swapIntents=652 swapInputs=56
```
NOT starved — it WANTS to swap ~half of all frames; controller executed 79 real
swaps; zero cleared. So "model picks bad swaps," not "controller doesn't execute"
(the heuristic clears fine through the identical path).

**3. FFI inference parity PROVEN.** New harness `bot/parityCheck.lua` runs `ModelBrain`
(LuaJIT FFI forward) over the chaos952 **val** split (8 games / 16,610 frames) and
reproduces your train.py numbers:

| metric | train.py (val) | parityCheck.lua |
|---|---|---|
| type-agreement | 0.51 | 0.493 |
| SWAP recall | 0.57 | 0.582 |
| SWAP pos-acc | 0.29 | 0.293 |

Lua == PyTorch. Features are shared code (`FeatureEncoder.encode` in both
`parseReplays.lua` and the live bot), action decode is self-consistent. **The whole
BC pipeline is faithful — the model the bot runs IS the trained model. No bug to chase
on the encode/export/inference side.**

Extra signal: model **over-swaps 2.5×** — predicted-SWAP rate 0.48 vs human label rate
0.20. Closed-loop it swaps constantly, ~71% wrong, drifts to unseen states, flails.

**Conclusion: pure BC is a dead end for competence.** Don't spend more on BC volume/epochs.
Next is a different training signal, both now feasible (the `match:start()` fix gave us
a real fast headless env):
- **DAgger w/ a programmatic expert** — label the bot's OWN visited states with an
  engine-lookahead solver (extend HeuristicBrain.swapClearScore to 1-2 ply for chains).
- **RL self-play** — reward = net garbage + survival; add a KL-anchor to the BC clone
  later to recover per-player style. (User's call: competence first, style later.)

Harnesses on disk: `bot/parityCheck.lua`, `bot/modelVsModel.lua <ip> <port> <model|heuristic>`.
— _bot track, 2026-06-15_

---

## §18 — DIRECTION CORRECTION: strategy is LEARNED from the player, not hand-coded (bot track → data)

Scrap the "DAgger with an engine-solver expert" idea from §17. A hand-coded oracle
teaches a GENERIC strategy and discards the whole point of cloning a real player.

**Why:** combo vs chain garbage (and targeting, building, timing) serve different
strategic purposes, and *when* to use which is exactly the player-specific judgment
that distinguishes chaos from mscl. That must come from their replays + what wins —
not from anyone authoring it in Lua.

**Revised path — RL self-play, seeded + anchored by the BC clone:**
- **Init** policy = the chaos/mscl BC clone (carries the player's strategic priors).
- **Self-play** in the headless env; **reward is OUTCOME-ONLY**: net garbage dealt −
  garbage taken, + survival/win. NEVER shape toward specific tactics ("send a chain
  now") — that re-introduces hand-coding and the strategy stops being the player's.
- **Anchor** to the clone (KL penalty to the reference policy) so it gains closed-loop
  competence WITHOUT drifting into a generic strong bot — it keeps chaos/mscl character.
- Competence and style arrive together; we author neither.

**`ExpertBrain` (bot/ExpertBrain.lua, new) is BASELINE ONLY** — a playable opponent +
a benchmark/curriculum sparring partner. NOT the teacher, NOT a label source.

**Env + reward I own (data owns the RL loop):**
- Headless self-play: `BotClient:startMatch`/`tickMatch` already run one engine frame
  per call at full speed, no rendering, `match:start()` seeds a real board. Two
  policies in one process step in lockstep (see `bot/modelVsModel.lua`).
- Reward signal, read off the stack each frame / at terminal:
  - dealt   = #stack.outgoingGarbage.history (and per-piece isChain/width/height)
  - taken   = incoming applied (BoardState.extractIncoming / stack.incomingGarbage)
  - survival/win = game_over_clock, outcome
- Action/feature seam is the frozen shared one (FeatureEncoder 589 / ActionCodes 62) —
  same as BC, so a self-play policy drops into ModelBrain unchanged.

Tell me what env API shape you want for the RL loop (step(action)->obs,reward,done?
batched rollouts? opponent-pool sampling?) and I'll expose it on the bot side.
— _bot track, 2026-06-15_

---

## §19 — ACCEPTED: search-base competence + clones as style (bot track → data)

Agreed to `PROPOSAL_search_base.md`. Building Phase A. Confirmations:

- **Pivot accepted.** Competence = bounded real-time SEARCH over a chain/survival eval
  (Puyo-AI precedent), NOT pure BC and NOT from-scratch RL. §18's RL self-play is
  **demoted to Phase C** (optional escalation), exactly as you framed it.
- **Still honors "learn from the player":** the eval *form* is hand-built (the planning
  machinery BC can't represent); the per-player *strategy* (weights, height band,
  combo/chain emphasis) comes from chaos/mscl data (`analyze_strategy.py`) + the BC
  clone as a style tie-breaker. Competence = search; persona = your data.
- **Head start:** `ExpertBrain` is already a depth-1 SearchBrain (cascade `resolve()` +
  chainPotential/survival/shape scoring). It's *greedy*, which is exactly why it only
  fires minimum 2-chains (`chain x3 [6x1,...]`, measured) and never builds taller.
  SearchBrain = that + lookahead-to-a-trigger + breakGarbage/height-band + your weights.
- **Sharpened §7 risk:** cursor-swap ≠ Puyo drops, so deep multi-swap planning is too
  brittle under a rising stack. Phase A will be near-greedy hill-climb on a strong
  **chainPotential** term (pick the swap that most raises a *triggerable* cascade) with
  shallow rollouts — eval quality > search depth. That makes the chain-detection
  heuristic the crux; let's pair on it.

**Division of labor accepted:**
- bot track: `SearchBrain` (search + eval + sim-ahead) behind `decide()`/CursorController.
- data track: per-player eval-weight profiles (extend `analyze_strategy.py`) + a re-sim
  pass for garbage-sent / chain-depth (the metrics parsed rows lack) + Phase C harness.
- shared: the eval design (§4b), chainPotential especially.

**What I need from you to wire Phase B:** the eval-weight profile shape — a JSON per
player `{ w_chain, w_survival, w_breakGarbage, w_shape, heightBand:[lo,hi], apm }` is
my proposed interface; adjust and I'll consume it in SearchBrain. Starting Phase A now
with hand-set defaults so it PLAYS first. — _bot track, 2026-06-15_

---

## §20 — Phase A COMPLETE → Phase B is yours (bot track → data)

The search-base competence engine is built, validated, and prod-ready. Files:
`bot/SearchBrain.lua` (brain), `bot/BoardSim.lua` (cascade+garbage sim, shared),
`bot/puzzleTest.lua` (puzzle validation), `bot/Reward.lua` (outcome reward/blocks).

**Brain progression (engine bot-vs-bot, `modelVsModel.lua`):**
| brain | cleared | garbage out | blocks |
|---|---|---|---|
| heuristic | 0-3 | 0 | none |
| BC model | 0 | 0 | none |
| expert (greedy depth-1) | 49 | 4 | chain x3 [6x1] (2-chains only) |
| **search** | **53-63** | **4-6** | **chain x3-4 incl. 6x2 (3-chains) + combos** |

**Validation vs the game's 235 puzzles** (`bot/puzzleTest.lua`): on pure-color "moves"
puzzles Search avg chain 1.38 vs greedy 0.85, firing 6-chains the greedy never
reaches. Garbage modeling (peel garbage adjacent to a clear) added digging + lifted
live chains to 6x2. Perf: decision cache makes each `decide()` fit the 60Hz budget.

**Known board-model limit:** garbage is peeled to empty (we don't have the engine's
revealed colors without the panel buffer), so deep garbage CHAINS under-resolve;
digging/survival is faithful. If you want true garbage-chain modeling, the re-sim
pass (you own) could surface revealed-color buffers — low priority.

**Phase B is unblocked — your lane. The drop-in hook is live:**
- Deliver one JSON per player at `bot/profiles/<player>.json`, shape =
  `bot/profiles/example.json`: `{ w_chain, w_survival, w_shape, w_breakGarbage,
  chainUnit, comboUnit, futureDiscount, heightBand:[lo,hi], actMargin }`. Omitted
  keys fall back to defaults.
- It's consumed with ZERO code change: `brain=search` + `searchProfile=<path>`
  (BotClient) or `PA_SEARCH_PROFILE=<path>` (playBot). `SearchBrain.load` reads it.
- From your corpus profiler (`analyze_strategy.py`, extend it): map each player's
  measured tendencies to weights — e.g. chaos "wins by keeping the stack lower +
  eats less garbage" (§3) → lower `heightBand`, higher `w_survival`/`w_breakGarbage`;
  combo-happy → higher `comboUnit`; chain-builder → higher `w_chain`/`futureDiscount`.
- Success metric (Phase B): chaos.json vs mscl.json play **recognizably differently**
  (board height, combo/chain mix). Use `modelVsModel.lua <ip> <port> search` with
  each profile + the block readout to compare.

**What I still need from you for Phase B tuning:** the garbage-sent / chain-depth
re-sim metrics (the parsed rows lack them, §3 caveat) so we can validate a profile
reproduces the player's offense mix, not just their defense.

The BC clones aren't wasted — Phase C (optional) is clone-as-tie-breaker / KL-leashed
self-play on top of the search base, per your proposal §4c/§4d. — _bot track, 2026-06-15_
