# Proposal: search-based competent base + BC clones as a style layer

**From:** data track  **To:** bot track  **Date:** 2026-06-15  **Status:** proposal

## TL;DR
Our pure behavior-cloning clones **don't play** (closed-loop: ~0 clears, no chains,
no garbage — §16). That's not a tuning bug; it's the wrong tool for *getting
competence* in this genre. Verified research + chaos's own game data both point to
the same fix: **make the competent base a bounded-depth real-time SEARCH over a
chain/survival evaluation (Puyo-AI style), and repurpose the trained BC clones as the
per-player STYLE layer on top.** This is the realistic single-machine path; heavy
self-play RL stays an optional later lever.

---

## 1. What happened (the failure)
`bot/modelVsModel.lua`, both brains = our trained models, full match, instrumented:
```
chaos952: cleared=3  outGarbage=0  (topped out)
mscl:     cleared=0  outGarbage=0  ("won" — just topped out slower)
```
~0 panels cleared per ~1600-frame game, zero chains, zero garbage traded. The
offline metrics (SWAP-recall 0.57 / pos-acc 0.29) were **teacher-forced** — the model
on the *human's* board states. Closed-loop, it reaches boards no human visited and
flails.

## 2. Why — verified (deep research, primary sources, fact-checked)
- **Covariate shift / compounding error** — textbook BC failure; per-step errors push
  the agent off the human distribution where errors accumulate (Rajaraman NeurIPS'20;
  DART CoRL'17; SQIL ICLR'20). Confirmed 3-0. *This is exactly our symptom.*
- **Deeper, genre-specific reason:** chain-building is a multi-second **plan**. BC
  learns per-frame "what did the human press *here*" — it has **no objective that says
  "build toward a trigger,"** so it can't represent the skill that wins.
- **For chain puzzles, SEARCH is the competence engine, not RL.** The strongest Puyo
  AI ("Mayah") is **beam search over a chain-detecting evaluation** with chain
  templates; a plain Monte-Carlo search reached *fair-human* real-time play with no
  heuristics (IEEE 9355917; Hanson & Moffat AISB'14). Confirmed 3-0.
- **The "pretrain-to-play → then style" recipe is real** (AlphaStar, VPT, RLHF):
  BC-init → make-competent via RL/self-play → **KL-leash to the BC prior** to stay
  human-like. *But every success was massive compute* (VPT = 720 GPUs). The pattern
  transfers; the compute does not.
- **Honest nuance:** BC isn't theoretically doomed — cross-entropy training (we
  already do) + recovery-data augmentation reduces the horizon penalty (Foster et al.
  NeurIPS'24). But it won't give a tiny MLP a *chain plan*; don't expect it to rescue play.

Sources (all primary unless noted): arxiv 2009.05990, 1703.09327, 1905.11108,
NeurIPS'24 "Is BC All You Need?", VPT (cdn.openai.com/vpt), AlphaStar (Nature'19),
CS:GO BC (arxiv 2104.04258), Puyo MCTS (IEEE 9355917), Puyo MCS (AISB'14),
ScriptHawk Tetris Attack bot, nayuki Panel de Pon solver, panel-pop.

## 3. What chaos's data says the eval should reward (120-game sample, 93W/27L)
`bot/analyze_strategy.py` over the parsed corpus:

| metric | WON | LOST |
|---|---|---|
| stack height (median) | **10** | 11 |
| frames under incoming garbage | **46%** | 50% |
| big combos (>3) | 11 | 9 |
| biggest combo | 36 panels | 38 |
| tempo | ~21% swap / 74% wait / 4% raise | same |

**chaos wins by keeping the stack lower and eating less garbage pressure**, while
still landing big combos. The win/loss separation *is* the evaluation function we
need. (Caveat: garbage **sent** isn't in the parsed rows — needs a re-sim pass; chain
depth proxy was weak.)

## 4. Proposed architecture
### 4a. Competent base = real-time beam search (the brain)
Replace `ModelBrain:decide(state)` with a `SearchBrain:decide(state)` that returns the
**same** decision (`SWAP@[row,col] | RAISE | WAIT`) — so the `CursorController` seam is
unchanged. Each decision:
1. Enumerate candidate swaps (legal adjacent pairs; prune to plausible ones).
2. Simulate each a few moves ahead (bounded depth — research found a **shallow
   sweet-spot**; deeper ≠ better under a frame budget; tune empirically).
3. Score each resulting board with the evaluation below; beam-keep top-K; pick the
   best first move (or WAIT if nothing beats holding; RAISE if safe to speed up).

### 4b. Evaluation function = your four terms (the crux)
`E(board, incoming) = w1·chainPotential + w2·survival + w3·breakGarbage + w4·shape`
- **chainPotential (+):** biggest cascade currently set up / triggerable. The hard,
  high-value term — estimate by simulating a trigger and counting cascades (Puyo's
  core trick), or proxy via chainable adjacent same-color groups. This is what makes
  it actually attack.
- **survival (−):** penalize height → topout, steepening near the top (time-to-topout).
- **breakGarbage (+):** reward clears adjacent to incoming/landed garbage, scaled by
  incoming size (digging out before it buries you).
- **shape (±):** prefer flat/low-bumpiness (more chainable + safer); penalize
  over-clearing to near-empty (keep material to build); target a **height band**.
- plus a small **cursor-travel cost (−)** (prefer nearby swaps; realism + frame budget).

### 4c. Per-player STYLE = the BC work we already did (not wasted)
Two cheap options (open design choice — see §6):
- **Conditioned eval weights:** set `w1..w4` + height-band + APM per player from their
  corpus profile (chaos: low band ~10, combo-happy, deliberate tempo). Search plays
  *their* balance of aggression/defense.
- **Clone as a prior/tie-breaker:** when several search candidates score close, bias
  toward the move the player's BC clone prefers — recognizable micro-style on a
  competent base.
- The existing **difficulty throttle** (CursorController) still paces APM per player.

### 4d. Optional later: self-play to tune/strengthen
We **can** run headless self-play (engine + `LoveRandom`) — so if hand-tuned search
isn't strong/distinct enough, we can tune eval weights with CMA-ES, or do KL-leashed
RL toward each player's clone. Search-first; this is the escalation, not the start.

## 5. Phased plan
- **Phase A — competence (gets it PLAYING):** hand-built eval + shallow beam search as
  the brain. Success = bot-vs-bot now trades garbage and clears/chains (not ~0).
  Validate with `modelVsModel.lua` (garbage sent > 0) + vs-human.
- **Phase B — style:** per-player eval weights from `analyze_strategy.py` (extended);
  optional clone-as-tie-breaker. Success = chaos vs mscl play *recognizably differently*.
- **Phase C — optional:** self-play weight-tuning / KL-leashed RL if A+B aren't enough.

## 6. Division of labor (proposed)
- **Bot track (your lane):** the `SearchBrain` (search + eval + simulate-ahead), its
  integration behind `decide()`/`CursorController`, frame-budget tuning. You own the
  engine-interaction + the move-execution you already built.
- **Data track (my lane):** per-player strategy profiles → eval weights (extend
  `analyze_strategy.py`); a re-sim pass to measure garbage-sent / chain-depth (the
  metrics the parsed rows lack); the offline eval/scoring; the self-play tuning
  harness if Phase C.
- **Shared:** the eval-function design (§4b) — the chain-detection heuristic is the
  crux and worth pairing on.

## 7. Risks / open questions (honest)
- **Cursor-swap ≠ Puyo falling-block.** Puyo searches over discrete piece *drops*; we
  search over *swap sequences* with a 1-wide cursor that must physically travel, under
  a rising stack. The chain-eval transfers; the search space is harder. No published
  learned agent for the cursor-swap variant was found.
- **Frame-budget search in Lua.** Bounded-depth beam search must fit the per-decision
  budget; keep depth shallow, prune candidates, reuse the engine's own sim.
- **Style encoding (open):** conditioned eval weights vs. clone-as-prior — no
  small-scale persona result in the literature; we'll likely A/B it.
- **The pivot is real:** the trained clones become a *style prior*, not the player
  themselves. Competence comes from search.

## 8. Recommendation
Build **Phase A** (search base) next — it's the thing that makes a bot *play at all*,
it's single-machine-tractable, and it's what the genre's only working AIs do. The BC
clones + chaos-style data slot in as Phase B style. I'll provide the eval-weight
profiles and the garbage/chain re-sim metrics; let's pair on the chain-detection eval.
