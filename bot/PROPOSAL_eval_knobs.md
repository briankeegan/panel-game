# Proposal: a pattern × context evaluation system (the "knob expansion")

**From:** bot track  **To:** Brian  **Date:** 2026-06-15  **Status:** proposal

## TL;DR
Replace the 9 flat global weights with a **linear value function over hand-designed
*pattern* features whose weights are *conditional on board context*.** Concretely:

```
score(move) = Σ_patterns  weight(pattern, context) · feature(pattern, move)
```

- **patterns** = every distinct *solve type* (combo-by-size, chain-by-depth, dig,
  earthquake-chain, insert, convert, tower-build, flatten, …) — grounded in the game's
  own puzzle technique tags, so "prioritize X" is authorable *and* puzzle-validatable.
- **context** = the situation you named — stack height, garbage on board, incoming
  pressure, attack cadence — so a bot can value digging differently *when buried* vs
  *when safe*, etc.

This is the standard strong-eval shape (chess/Puyo evals are feature·weight sums, often
phase-conditional). It's hand-authorable for a variety pack, **data-fittable** per player
(regression on their moves), and RL-tunable later — same structure for all three.

---

## 1. Why the flat weights aren't enough
Today's eval is `w_chain·chainPot + comboUnit·comboPot + w_survival·risk + …` — a few
GLOBAL constants. Two limits you hit:
1. **Coarse solve types.** "combo" and "chain" are single terms; the game distinguishes
   ~20 techniques (inserts, converts, earthquake chains, towers, removes, shoguns…). We
   can't prioritize "earthquake chains" or "inserts" because they aren't features.
2. **No context.** A dig is worth the same whether the stack is at row 4 or row 11; a
   3-clear is valued the same when safe vs about to top out. Real play (and the players
   we clone) shift priorities by situation — exactly your "when they break garbage, how
   high the stack is."

## 2. Part A — the pattern taxonomy (the "what", grounded in the puzzles)
Each pattern is a cheap function of a move's simulated result (we already sim every
candidate in `BoardSim`). Proposed feature set (~15), mapped to the game's tagged sets:

| pattern feature | value = | puzzle set it validates against |
|---|---|---|
| `combo4 / combo5 / combo6` | fires a 4/5/6-wide combo (split so size is tunable) | `*_combos` |
| `combo2D` | L/T-shaped (multi-line) combo | `combos` (advanced) |
| `chain2 / chain3 / chain4plus` | cascade depth fired | `chains`, `*_chains` |
| `comboSetup` | one swap FROM a 4+ combo (build) | `pre_setup_combo_chains` |
| `chainSetup` | one swap FROM a trigger (build) | `chains_from_*`, `horizontal_chain_*` |
| `insert` | swap a panel INTO a setup to extend/trigger | `inserts`, `*_inserts` |
| `convert` | turn a horizontal group vertical or vice-versa | `convert_*`, `transitions` |
| `tower` | build a tall single-color column (chain fuel) | `*_from_tower`, `chains_from_huge_tower` |
| `dig` | break garbage (per cell), by garbage size/type | `clear_puzzles` |
| `earthquakeChain` | break garbage that then cascades | `earthquake_chains` |
| `flatten` | reduces bumpiness / max height | `clear_puzzles` |
| `survivalClear` | any 3-match (height relief only, ~0 offense) | — |

Each is computed once per candidate from the existing sim — no new engine cost beyond
the scans. (Honest: `earthquakeChain` + deep `chain*` stay approximate until the
garbage-reveal-color modeling lands — §24 caveat. They become features now, accurate later.)

**DECISION (Brian): include ALL techniques, not a ~15 subset.** Full feature list, with
several sharing a parameterized detector:
- combo: `combo4 combo5 combo6 combo2D`
- chain: `chain2 chain3 chain4plus`, `extendedHorizontalChain` `horizontalChainFromSide`
- setup: `comboSetup chainSetup preSetupCombo tower hugeTower convert`
- insert family (one detector, variants): `insert changeSideInsert comboChainInsert`
- garbage: `dig earthquakeChain deeperEarthquakeChain`
- technique: `remove shogun opener transition`
- defense: `flatten survivalClear`

**Sparsity is expected and is the point:** a real player (and most personality bots)
prioritize only a handful of these — the rest sit at weight 0. The schema makes 0 the
default (omit the pattern), so a profile is a short list of the few techniques that
player actually uses, which is exactly how we fingerprint "what they prioritize."

## 3. Part B — the context (the "when")
A handful of cheap **context flags** read off the board each decision:

| flag | from |
|---|---|
| `heightLow` / `heightMid` / `heightHigh` / `danger` | maxColHeight vs heightBand + top |
| `hasGarbage` / `buried` | garbage cells on board (count thresholds) |
| `incomingCalm` / `incomingSmall` / `incomingLarge` | staged+in-transit garbage area |
| `incomingSoon` | min incoming eta < N frames |
| `staleAttack` | frames since last garbage-send > targetInterval (cadence) |

## 4. Part C — how weights condition on context (the crux)
Two candidate designs (recommend **4a**):

**4a. Base + context modifiers (recommended).** Each pattern has a base weight; a small
modifier table adjusts it per active flag. Effective weight is additive:
```
weight(p) = base[p] + Σ_{flag active} modifier[p][flag]
```
e.g. `dig.base=1`, `dig.modifier.hasGarbage=+3`, `dig.modifier.incomingLarge=+5` →
the bot digs hard only when buried/pressured. Granular, smooth (no regime-boundary
jumps), and a profile only lists non-zero modifiers (stays small).

**4b. Discrete regimes (simpler, coarser).** Classify context into ~5 named regimes
(Build / Attack / Defend / Buried / Panic); each regime is one weight vector over
patterns. Easier to reason about, but boundary jumps and less expressive.

## 5. Profile schema (extended, backward-compatible)
```jsonc
{
  "patterns": { "combo4": 30, "combo6": 55, "chain3": 70, "dig": 1, "tower": 8, ... },
  "modifiers": {                       // weight deltas by context flag (4a)
    "dig":      { "hasGarbage": 3, "incomingLarge": 6 },
    "survivalClear": { "danger": 40 },
    "combo6":   { "heightLow": 10, "danger": -50 }
  },
  "targetInterval": 150,               // cadence knob (frames between attacks)
  "heightBand": [8, 11],
  "difficulty": "hard"                 // existing move-quality tier
}
```
Omitted patterns/flags fall back to sensible defaults, so existing profiles still load.

## 6. Validation — per-technique, against the puzzles
Extend `bot/puzzleTest.lua` to report **per technique set**: for each tagged set
(`combos`, `earthquake_chains`, `inserts`, …) measure whether the bot prioritizes/solves
it. Then "this bot prioritizes earthquake chains" is a *number*, not a vibe. The variety
pack gets a scorecard.

## 7. Data grounding (Phase B at technique fidelity — data track)
The data track's re-sim can measure, per player, **which patterns they use in which
context** (e.g. chaos: high `dig` when `hasGarbage`, frequent `combo4` always; mscl:
`chainSetup`+`tower` when safe). That directly fills `patterns` + `modifiers` → clones at
technique-level fidelity, subsuming today's flat profiles. This is a richer §20 hand-off.

## 8. Your variety pack falls out as three profiles
- **Large garbage:** `chain*` + `tower` + `chainSetup` high, `minComboToFire`-style via
  low `combo4`/high `combo6`, patient (`comboSetup` modifier `heightLow:+`).
- **Defense:** `dig` + `flatten` + `survivalClear` high, big `dig`/`survivalClear`
  modifiers on `hasGarbage`/`danger`, offense low.
- **Fast combo:** `combo4`/`combo5` high, `targetInterval` low, `chain*` low.

## 9. Phasing
- **P1 — patterns, flat (no context):** implement the ~15 pattern features + flat
  per-pattern weights. Makes the variety pack expressive immediately. (Extends what's
  already there — combo/chain/dig are 3 of these.)
- **P2 — context modifiers:** add the flags + modifier table (Part C/4a).
- **P3 — per-technique puzzle validation + data-grounded conditional profiles.**

## 10. Risks (honest)
- **Tuning burden / incoherence.** ~15 patterns × contexts is a big hand-tuning surface;
  a careless profile plays incoherently. *Mitigation:* good defaults, the puzzle
  scorecard, and data-fitting the weights instead of hand-setting (the linear shape is
  exactly what regression/RL want).
- **Per-decision cost.** More features = more scans per candidate. *Mitigation:* compute
  all patterns in one sim pass per candidate; the board-sig decision cache already
  amortizes travel frames; keep `top` bounded.
- **Garbage-chain features stay approximate** until the reveal-color modeling lands
  (orthogonal fix). `earthquakeChain`/deep `chain*` are directionally right, not exact.
- **Overfitting personalities to puzzles** (frozen boards ≠ live pressure) — validate
  live (`modelVsModel` offense mix) too, not only on puzzles.

## 11. Recommendation
Build **P1** (the full pattern taxonomy, flat weights) next — it's the "way more knobs"
you want, makes the variety pack genuinely distinct, and reuses the existing sim. Then
**P2** (context conditioning) delivers the "when they break garbage / how high the stack"
behavior. Hold P3 for when the variety pack is playing and the data track wires the
conditional clones.

## 12. Decisions (resolved with Brian)
- **(2) Pattern granularity:** ALL techniques (§2 full list), sparse per-profile weighting
  — most patterns 0 for any given bot/player. ✅
- **(1) Context shape:** `base + modifiers` (4a) — recommended, and it's what sparse
  weighting wants (zero out most, modify the few). _Pending explicit confirm; proceeding
  with 4a unless told otherwise._
- **(3) Phasing:** P1 (full pattern features, flat weights) first to make the variety
  pack expressive, then P2 (context modifiers). _Pending; recommend P1-first._
