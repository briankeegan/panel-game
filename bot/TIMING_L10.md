# Invincibility timing @ Level 10 (from PdP_data.ods, user-provided)

The bot plays L10. All values in FRAMES (60fps). Three invincibility sources — while ANY is
>0 the stack can't rise / top out. **They do NOT stack:** `newValue = max(existing, new)` (shake
is peak-based, same idea). So you MAINTAIN the meter by refreshing it before it depletes, each
refresh ≥ current.

## 1. SHAKE — earned when garbage LANDS (falling→normal). Scales with block size:
| garbage | shake frames |
|---|---|
| 4–5 combo | 18 |
| 6 combo | 24 |
| 7 combo / x2 chain | 42 |
| x3 / x4 chain | 66 |
| **x5 chain+ (4+ thick), up to 12-thick** | **76 (cap)** |

→ A big block landing hands you up to **76 free invincible frames** to set up in.

## 2. STOP TIME — earned by combos/chains. L10, NON-critical:
- Combo: `stop = 2·comboLen + 22` → 4c:30, 5c:32, 6c:34, 7c:36, 8c:38 … 12c:46
- Chain: `stop = 2·chainLen + 56` → x2:60, x3:62, x4:64, x5:66, x6:68, x7:70, x8:72, x9:74, x10:76, x11:78, x12:80, x13:82

## 3. STOP TIME — **CRITICAL** (panels OR garbage at least partially in the TOP ROW = you're buried/high). L10:
| clear | critical stop | vs non-critical |
|---|---|---|
| 4–8 combo critical | **60** | (2× the 4-combo's 30) |
| 9–10 combo critical | 62 | |
| x2 critical | **90** | (vs 60) |
| x3 critical | 92 | (vs 62) |
| x4 critical | 94 | (vs 64) |
| **x5+ critical (capped, treated as x6)** | **98** | (vs 66) |

### THE KEY INSIGHT
**Critical stop time >> non-critical.** The engine pays you the MOST invincibility *exactly when
you're about to die* (stuff in the top row). A critical x2 = 90 frames; a critical 4-combo = 60.
So the optimal defensive move when buried is to ATTACK — chaining there buys the biggest freeze.
The live bot currently does the OPPOSITE: `offenseScale = buriedOffense (<1)` SUPPRESSES offense
when buried. That's backwards. Buried is when chaining pays the most. (Move-1 counterPressure was a
step toward this; the data says go further — AMPLIFY offense when critical, don't just un-gate it.)

## Match resolution @ L10 (how long a clear takes to pop; pre_stop covers it):
hover X=6, pop/panel Y=7, flash W=28, face V=15. Match duration ≈ W + V + n·Y
(e.g. 4-combo ≈ 28+15+28 = 71 frames).

## The loop, quantified:
big block lands (≤76 shake) → set up to the known reveal during it → fire a chain as it depletes;
if you're buried that chain is CRITICAL (90–98) → its pop is pre_stop (~71+) → next block. The meter
never hits 0, you never rise, and every refresh also sends garbage. Source of truth: `checkMatches.lua`
(awardStopTime/pre_stop ∝ POP·(comboSize+garbageCleared)); see [[garbage_stoptime_model]].
