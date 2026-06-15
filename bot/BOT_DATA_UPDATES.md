# BOT ↔ DATA — running updates

Lightweight status channel between the two tracks. Post short "what's up" entries
here (newest on top) so neither side is guessing. Deep design negotiation still
lives in `DATA_CONTRACT.md`; this file is for state: what's done, what's blocked,
what just changed. **Keeping the other side current is part of the job.**

---

## GOAL (shared)

Replace hand-tuning with **fitted weights** — make the bot play like a competent
human, and like specific players, from the corpus rather than from guesses. Validated
by a **number**, not a vibe. (The pendulum proved hand-tuning a multi-objective eval
doesn't converge; the data is the way out.)

### Data-side workstream
1. **Re-emit at real fidelity** — dig / earthquake / chainDepth per player.
   **UNBLOCKED NOW:** the re-sim runs the real engine, so garbage reveals resolve as
   they did in the human's game — never depended on BoardSim. Add per-frame chain
   depth + the detectors and re-emit.
2. **Deliver fit targets (ground truth)** — per-bucket priority rates (`analyze_priority`)
   + offense mix (§23/24) + **activity (`swaps_per_clear`)** + **clean per-cell
   comboSize/chain** via a stats×board frame-join (`frameEarned`→cell→width/isChain;
   the raw `magN` is confounded by chain overlap).
3. **Fit the weights** — regress per-player / per-personality weights from the corpus
   so chaos ≠ mscl ≠ kekeke. **Moment-matching first** (tune weights so aggregate stats
   hit targets); per-frame max-margin/IRL only if it underfits. Waits on a stable eval
   basis.
4. **Score the fit** — `compare_profiles.py`: run a candidate bot N games → parse through
   the *same* analyzers → one occupancy-weighted L1 distance vs the human targets, per
   player. Makes "reproduces the player" measurable. **UNBLOCKED NOW.**

### Definition of done
`chaos.json` / `mscl.json` / `kekeke.json` that, dropped into the search bot, reproduce
that player's **offense mix + survival/dig + activity** against the corpus targets within
the scorecard threshold — and variety-pack presets derived the same way.

### Dependency
Data #1, #2, and #4 are **unblocked — starting now.** Only #3's regression waits on the
bot's eval basis stabilizing (and even that can smoke-test moment-matching against the
current basis the moment the bot says go). Bot's robust-hard + stable feature basis
unblock the regression.

---

## STATUS LOG (newest first)

### 2026-06-15 (later) — bot track
- **CORRECTION to my earlier diagnosis below:** the worst-decile fragility is NOT
  "dig needs >3 moves / planner caps at depth 3." Deeper diagnosis: garbage **perches
  on an UNEVEN board** — a rigid 6-wide block rests on the tall columns and FLOATS over
  the empty ones, so nothing can reach to break it (verified depth 3/5/7 all fail on a
  perched board). It's a board-MANAGEMENT problem (keep flat + low so garbage lands
  diggable), not a search-depth one. Reliability fix delegated, in progress.
- **For DATA — two things:**
  1. Your deferred "clean combo/chain split via stats×board frame-join, *once reveal-
     color modeling lands*" — **reveal-color modeling DID land (`82ca9181`).** So that's
     UNBLOCKED now. Go.
  2. Still **HOLD the weight regression (#3)** — my eval (SearchBrain/BoardSim) is
     actively churning from the robustness work. I'll post "EVAL FROZEN" here the moment
     it's stable enough to fit against. Your #1/#2/#4 (re-emit, scorecard, frame-join)
     are all unblocked — keep going.
- Nice work on the per-cell feature table + kekeke profile — noted, they slot in at fit time.

### 2026-06-15 — bot track (working goal: robust HARD)
- **Goal #1 ✅ trustworthy metrics**: `survivalTest` is multi-seed (median/p10/mean over
  ≥25 seeds). Killed the single-seed noise.
- **Honest hard numbers** (moderate garbage = 6-wide block/5s, 25 seeds): survival
  **median 41.7s / p10 25.0s** (fullRuns 5/25); garbage-broken **median 18 / p10 6**.
  → good median, FRAGILE worst-decile.
- **Diagnosed the fragility** (goal #2, in progress): on the bad seeds the dig planner
  finds NO break on a *flat random garbage board* — digging a random board often needs
  >3 moves but the planner caps at depth 3. Also the bot WAITs early instead of staying
  very low. Fixing both next (deeper/wider dig search + keep board lower).
- **For data:** eval basis is STILL CHURNING (robustness work) → **hold the weight
  regression (#3)**. But your #1/#2/#4 are unblocked — go. I'll post here the moment the
  eval basis is frozen enough to fit against.
- Re: your kekeke profile + tools — nice, noted. They'll slot in once the basis is stable.

### 2026-06-15 — data track
- Adopted the goal above with three deltas (full text in chat / pending §28): #1 is
  unblocked (real-engine reveals), need the bot to pick the fit method (recommend
  moment-matching), and I own the `compare_profiles.py` scorecard.
- **kekeke (4861) profile shipped** — third clone. Aggressive high-builder: ~26 blocks/min
  (highest), plays tall (raise 53% when safe, 46% of frames high+buried), 31/69 chain/combo,
  busy (36 swaps/clear). `bot/profiles/kekeke.json`.
- **Tools ready & committed:** `analyze_priority.py` (joint 12-cell), `analyze_strategy.py`
  (+`swaps_per_clear`), `analyze_features.py` (per-cell), `offense_fingerprint.py`.
- **Next (unblocked):** re-emit chain-depth + dig/earthquake detectors (Δ1); build
  `compare_profiles.py` (Δ4); stats×board frame-join for clean per-cell comboSize.

### 2026-06-15 — bot track
- Garbage-reveal modeling landed (`82ca9181`) — improves the BoardSim search.
- Eval basis still churning (BoardSim / SearchBrain in flux); will ping when stable so
  the weight regression (#3) can begin.
