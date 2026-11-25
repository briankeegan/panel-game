# Gambit's numbers to retune for chaos

**THE RULE (the owner, 2026-11-25): every number is dynamic -- read off the level being played, never a constant for one level.**
The bot will play chaos Level 9 and Level 10, so a retuned number is written as a function of the board's own level data, which the
engine already holds every frame (`ca.h` Board): `fHOVER`, `fGARBAGE_HOVER`, `fFLASH`, `fFACE`, `fPOP`, `fGARBAGE_POP` (clear and
fall times), `stopBase` (stop time), `maxHealth`/`health`, `speed` and `caRiseFrames(speed)` (rise), `marginTime`/`marginCounter`,
`queueType`, `colorCount`. Gambit already does this for its horizons (`outcome.c` `AT_LEVEL`: level-11 frames scaled by the level's
break time); every change here follows that pattern, and the benchmark is run at Level 9 and Level 10 (`bench/request.txt` LEVEL)
before a change counts. *(Owner, later: the benchmark is Level 10 only; the numbers stay level-read so 9, 8, 7 work too.)*

Gambit (the frozen copy in `gambit/`) was tuned on vanilla Level 11, where health refills and the server limits inputs. Every number
below was set for that game. Each is changed **one at a time**, judged on the benchmark by whether its deaths go away
(`plans/chaos-goal.md` §2). Status: `done` (changed, run named), `next`, `open`.

## 1. How high the stack is kept (decides survival first)

| Number | Where | Vanilla | Chaos | Status |
|---|---|---|---|---|
| `raise.to` | `profiles/*-rules.json` | 11 (raise to row 11) | run 4: 0 (shut every raise off: a board ran out of panels); run 5: -1 = computed, `decide.c chaosRaiseTo` (height - rows risen within HORIZON - 3) | done, run 5 |
| `keep.material` | rules | >= 40 panels | run 4: none; run 5: >= 36 (half the board, level-free) | done, run 5 |
| `opener` (8/6/4-chain by 600) | rules | on | off | done, run 4 |
| `FINISH_ROWS` 8 | `decide.c` | finish them raises a low stack to 8 rows | to measure | open |
| `LOW_ROWS` 6 | `decide.c` | a stack under 6 rows is raised | to measure | open |
| `OPENING_RAISE` 600, `RAISE_WAIT` 120, `TA_TOP` 10 | `decide.c` | raise timing / time attack's top | to measure | open |

## 2. How far ahead "alive" is judged

| Number | Where | Vanilla | Chaos | Status |
|---|---|---|---|---|
| `HORIZON` 240, `REST` 120 (`AT_LEVEL`, scaled by `LEVEL11_BREAK` 97) | `outcome.c` | level-11 frames | Level 9's break time scales them; whether 240 is the right reach under chaos garbage rates is open | open |
| `planHealth` 1 | profile `setup` | health planned as 1 frame (vanilla refills) | chaos health is permanent: plan with the real health and price what a line spends, or keep 1 | next after run 4 |
| `core/material.h` | `core/` | the life a board has by its panels, measured on vanilla games; >33 panels "full" | run 12 turned its "full board" drive off (`decide.c R->full`): survival fell 6/8 to 4/8, reverted -- kept on | tried, run 12 |

## 3. Attack sizes (what a clear sends)

Chaos combo garbage is `ceil((n-3)/3)` rows, each `(n-1)%3+3` wide (rules.c already uses it). So the combos worth making differ:
6 (one 5-wide), 9 (two 5-wide), 12 (three 5-wide) carry the most per panel; 7 and 10 start a new 3-wide row. Vanilla's
"finish them" asks for combos ==8/9/10 (`gambit-rules.json` attack). Chains cap at 12 rows (`MAXCHAIN` 13 kept).

| Number | Where | Status |
|---|---|---|
| finish them / pressure / build combo and chain sizes | `profiles/chaos-rules.json` attack | open (Step 4: attack only after survival) |
| `FILL_FLIGHT` 151, `FILL_FALL` 15, `FILL_LINK` | `decide.c` | 151 = 45+45+1+60, same in chaos (checked); open for the rest |

## 4. Timing of the hands

| Number | Where | Vanilla | Chaos | Status |
|---|---|---|---|---|
| reaction 12, swapGap 12, cursorMoveFrames 4, ahead 90 | profile `setup` | Gambit's live pacing | kept: the owner chose vanilla hand speed (2026-11-25), though chaos's engine takes a tap every 2 frames and a swap any frame | kept (owner) |
| `WALK_FRAMES` 8, `BREAK_WALK` 20, `PRESS_FRAMES` 3, `OUT_ACT` 8 | `rank.c`, `decide.c`, `search/outlive.c` | charges for actions under the 76/600 allowance | chaos has no allowance; an action costs only its frames | open |
| `STAGING` 91, `LAND` 60, `EARLIEST_LANDING` 151 | `front.c`, `rank.c`, `GambitNative.lua` | garbage timing | identical in chaos (globals.lua 45/45/60) | checked |

## 5. Search shares and widths (last: speed is not the lever)

`ms` 80, `width` 40, `depth` 7, `pool` 250 (profile), the `*_MS`/`*_LINES` shares in `decide.c`. Left as they are until
survival and attack are right.
