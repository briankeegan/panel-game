# The weighted evaluator

A second brain for the Panel Attack bot. It has no shapes in it: it scores the
board a move **leaves**, on 19 weighted terms, and picks the highest. The
weights were **found by a search**, not turned by hand.

Read this before editing `bot/PanelEval.lua`.

---

## Why it exists

The existing brain (`bot/EnvelopeBrain.lua`) recognises shapes from a catalog
and fires the ones it can verify. That works, and it caps out where the
catalog does — a shape nobody wrote down is a shape the bot cannot play.

The other approach is the one that produced the strongest Puyo Puyo bot, which
contains **no chain logic at all**: reward density and stored potential, and
chains happen. Adjacency fills the board with groups of three, one short of
popping; because the reward applies everywhere, those groups end up packed
against each other; when one finally pops, what falls lands on another
near-complete group.

The weights here come from a cross-entropy search over that idea, run in the
GameCreator repo (`games/the-game/ai/eval/`), which stopped itself when the
numbers stopped moving. Against that game's previous AI, on seeds it never
trained on: **2683 against 679, +295%**.

---

## What it is made of

| file | what it does |
|---|---|
| `bot/PanelEval.lua` | the 22 features and `evaluate()`. One pure function each, returning a raw unsigned magnitude. |
| `bot/EvalPlan.lua` | the lookahead. The **one** place BoardSim's grid dialect meets the evaluator's. |
| `bot/EvalEarned.lua` | one resolve, translated into what the game pays: garbage out, stop time, score. |
| `bot/WeightedBrain.lua` | the live `decide`. Same interface as every other brain. |
| `bot/profiles/trained.json` | the weight set. Generated — do not hand-tune. |

Sign lives in the registry and weight lives in the profile, so a feature never
needs to know whether more of it is good. That means the same function can be
re-signed or re-weighted without being rewritten, and a test can assert a
**count** rather than a score.

---

## Running it

```sh
# against a human, online
PA_SEARCH_PROFILE=bot/profiles/trained.json \
  luajit bot/playBot.lua <ip> <port> PanelBot "" "" weighted

# offline survival, same harness the other brain uses
PA_BRAIN=weighted luajit bot/survivalStress.lua 900 7200 20 "" hard 6 4

# bot vs bot on a live server, reports the host's win %
luajit bot/winRateTest.lua bot/profiles/trained.json "" 12
```

`brain = "weighted"` on `BotClient`, and `searchProfile` names the weight set
(nil takes `bot/profiles/trained.json`).

---

## How it is kept honest

A port is a **second implementation of rules that already exist**, which is the
shape of work that goes wrong invisibly: both copies look fine, neither is
obviously stale, and the drift only shows as a bot that plays slightly worse
than it used to for reasons nobody can point at. So the port is **checked**,
not reviewed.

| gate | what it proves |
|---|---|
| `bot/tests/panelEvalVerify.lua` | every feature agrees with the JavaScript it was ported from, on 393 boards the shipped bot actually sat on at level 10. 8,646 values, all 22 features, zero mismatches. |
| `bot/tests/comboPartitionVerify.lua` | BoardSim partitions a clear exactly as the real engine does. 4,443 swaps played on a real `Stack`, reading its own `matched` signal. |
| `bot/tests/boardSimVerify.lua` | (pre-existing) the settled board after a swap matches the engine. 0/941. |

The fixture is generated from the other side:

```sh
# in the GameCreator checkout
node games/the-game/ai/eval/export_reference.js
```

Change a feature here and `panelEvalVerify` fails until the fixture is
regenerated. **That is the point.** If the two implementations are meant to
diverge, the divergence has to be written down and re-exported, not discovered
in a match.

---

## What the port found

The gate's first run disagreed on two features, and the real engine — asked
directly, via `Puzzle`/`Match`/`Stack` — said the **port** was right and
**BoardSim** was wrong. Two defects, both pre-existing, both affecting the live
bot and not just the evaluator:

**1. The first match happens before the fall.** `resolve` settled the whole
grid and then matched. That is right for the case it was written for — a swap
empties a cell and the real match only forms once the panel above drops in —
and wrong for the opposite one: when a match is already there on the swap
frame, the engine fires it immediately while the panels that lost their support
are still in the air. They land and match **separately**.

**2. A round is not a chain link.** `resolve` returned its round count as the
chain depth. The engine counts a match as extending the chain only when one of
its panels is *chaining* — a panel that fell into space a previous clear freed,
or one revealed by breaking garbage. Two unrelated matches firing in sequence
are two combos at chain 1.

Neither was reachable by `boardSimVerify`, which compares the settled board: a
cascade that removes six panels can be one 6-combo or two 3s, and those leave
the **identical board** while sending a 5-wide block and nothing at all
respectively. Same board, opposite consequence — a check that only compares
boards is structurally blind to it.

Measured before the fix over 4,443 swaps on 393 real boards: 2 wrong, both on
swaps with an empty side (41% of all legal swaps in real play). After:
4,443/4,443 on panels cleared, biggest combo and chain depth.

---

## What it is worth, measured

Both brains through the identical harness, on the **same twenty seeds**, same
garbage, same cursor pacing (`bot/survivalStress.lua 900 7200 20 "" hard 6 4`):

| | EnvelopeBrain | WeightedBrain |
|---|---|---|
| survival, median | 41.5 s | **46.7 s** |
| survival, p10 | 17.3 s | **31.4 s** |
| survival, mean | 41.3 s | **45.6 s** |
| chains fired, total | 45 | **52** |
| garbage broken, mean | **85.5** | 64.2 |
| seeds survived longer on | 9 / 20 | 11 / 20 |

**Read that last row before quoting any of the others.** Eleven of twenty is a
coin flip: on this sample the weighted brain is *competitive with* the existing
one, not proven better than it. The medians move in its favour and the medians
are not the claim.

What IS a real difference is the **floor**. EnvelopeBrain has two games under
twenty seconds (16.4 s, 17.3 s); WeightedBrain's worst is 21.7 s and its
second-worst 31.4 s. Fewer catastrophic games is what p10 is measuring, and it
is the half of the distribution a survival bot is judged on.

It **digs less** — which is what you would expect, since these weights were
found by training for score and survival in endless, with no dig objective
anywhere in the search, and with no transfer to this engine at any point. It
has never been trained on Panel Attack.

Six seeds said +40% on the median and a clean sweep. Twenty says +13% and
11/20. The first number was noise, and this repo has the scar to prove that one
run per condition measures nothing — quote the twenty, and treat even that as
"no worse, better at the tail" rather than a win.

**The obvious next step is to train it HERE**, on this engine, against this
game's own objective. What is running now is a bot tuned for another engine's
endless mode, dropped in cold.

---

## Things worth knowing before you edit

- **The weight set is only a bot when paired with the switches it was found
  under.** `density: true` in the profile is honoured and matters: it divides
  the panel-counting features (`links`, `edgePenalty`) by the panels they are
  counted over, so a board half the size can be exactly as tidy. Weights found
  with it stop meaning the same thing without it.

- **Holding is a candidate.** Leaving it out asks "given you must move, which
  is the best move?" — an easier question than the one the game asks. A bot
  that cannot hold has no way to build a chain, because building one means
  declining to fire the small thing available now.

- **The cost is quadratic by design.** Scoring one candidate runs a lookahead
  pass over that candidate's own legal swaps, because `chainPotential`,
  `comboPotential` and `matchPotential` measure what the board could do next.
  At ~17 legal swaps that is ~300 resolves per decision. Those three features
  are the point of the approach, so the exponent is not a bug to optimise away.

- **7, 8 and 9 are not colours.** They are real, swappable panels the engine
  never matches. `EvalPlan` maps them to "busy": calling them colours would
  offer the search clears that cannot exist, and calling them garbage would
  report damage that is not there.

- **Every payout number is read from the engine, none is retyped.**
  `COMBO_GARBAGE` and the two score tables are exposed on `Stack` by
  `common/engine/checkMatches.lua`; stop time is computed by calling the
  engine's own `Stack:calculateStopTime`. A bot that re-types a payout table is
  a copy that goes stale silently — the score still moves, so the bot still
  looks like it is working while it optimises a payout the game does not pay.
