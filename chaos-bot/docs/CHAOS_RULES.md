# Chaos build v3: rules that matter for the bot

Source of truth: Lua extracted from `test-build_v3.zip` → `panel.exe` (fused LÖVE archive).
The loose source on the `chaos_build` branch (commit 4da6c5d) is OLDER than the zip — 30+ Lua files differ.
Baseline for diffs: panel-game `bramp/multi-player` (c924107), which is what Gambit's `pa.c` ports.

## Survival

| Rule | Chaos | Vanilla (bramp) | Where |
|---|---|---|---|
| Health refill | **Never refills.** `self.health = self.health` (no-op) | refills to maxHealth when out of top row | Stack.lua:1027 vs bramp 1069 |
| Health decay | margin_time > 1: `health = max(1, floor(health*0.9))` every 900 frames (with speed +1) | none | Stack.lua:1222-1225 |
| Health drain | -1 per frame with panels in top row, stop_time==0, no rise_lock | same | Stack.lua:1253-1255 |
| Game over | health <= value **and shake_time <= 0**; or margin_time==1 (Off) and incoming queue len >= 50 | | Stack.lua:1928-1937 |
| Death-raise | removed | | |
| Shake time | `18 + 2*w*h` (shake keeps you alive) | | Stack.lua:1539 |
| Rise speed | new `SPEED_TO_RISE_TIME` table, speed +1 every 900 frames, 92+ = 1 frame/row | | consts.lua, Stack.lua:1217 |
| Level 7 health | 30 → floor(*0.9) each 15s → reaches 1 after ~17 intervals (~4:15) | | |

Health is a one-time budget; after ~4 min with margin on, any topped-out frame without stop/shake = death.

## Stop time
`calculateStopTime` (checkMatches.lua:887):
- 3 shocks matched alone: `20 * metal`
- combo>3 or chain: `ceil(Base * 1.05^max(0,combo-4) * 1.1^(chain-2) * 1.25^state * MarginFactor) + 20*metal`, capped 300
  - state: 0 normal, 1 chain, 2 topped out, 3 topped-out chain
  - MarginFactor: Modoki (3) linear to 0 at 5 min; Chaos (4) `(base*(1-t) - queueLen)/(base*(1-t))`, base 50 (30 with ChaosMode)
- game_mode >= 3 (NST, BALL): stop_time forced to 0
- only replaces stop_time if larger

## Attack (what we send)
`pushGarbage` (checkMatches.lua:794):
- **Shocks (metal)**: metalCount m ≥ 3 → (m-2) rows of 6-wide metal
- **All-clear**: if `has_all_clear` and a combo/chain fires: 3,4,5,6,6(metal) wide pieces (5 lines). Must chain into it.
- **Combo n ≥ 4** (COMBO_GARBAGE table is now unused except for `#combo_pieces` row offset):
  - width = `(n-1)%3+3`, pieces = `ceil((n-3)/3)`
  - +4→3w, +5→4w, +6→5w, +7→2×3w, +8→2×4w, +9→2×5w, +10→3×3w …
  - ChaosMode and (not in chain link ≥3): ONE block `width × pieces` tall instead of `pieces` 1-tall rows
- **Chain**: 6-wide, height = links-1, capped at **12** (addChainLink: `min(12, h+1)`)
- Damage per docs: lines = damage; shocks 1.5; chain cap 12

## Garbage timing
- TRANSIT 45 + TELEGRAPH 45 + 1 = staging 91 frames; then LAND_DELAY 60 → ~151 frames from earn to landable
- Chains release only once finalized + staging elapsed
- Queue types (code numbering!): 1 = "modified classic" (combos by width, chains after combos), 2 = modern (FIFO by frameEarned), 3 = chaos (LIFO: newest first)
  - docs say 1=Modern, 2=Classic — **code disagrees; trust code**
- Chaos queue drop rule (Stack.lua:957-965): drops when chain height>1, or after margin maxed and stack idle, or no active panels

## Opponents for benchmarking
- `AttackEngine` (training files in `training_chaos/`, fields `patternName`, `GarbageQueueType`, `ChaosMode`)
- `GarbageEngine` (new): random generator, target GPM 21–27, random queue type and chaos mode, chains 1–6 tall + 3–5 wide combos / metal. Uses `math.random` → seed needed for reproducibility.

## Versus-only
Mercy at 7200 frames (1.5× lines), sudden death at 36000 (Match.lua:575).
