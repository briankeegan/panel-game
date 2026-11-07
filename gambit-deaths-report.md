# Gambit overnight on panelattack.com — deaths and kills

Bot: Ranmaru_p13_CPU … p22_CPU (Gambit from GameCreator `main`, one run per number).
Data: 101 games against 8 players, runs p13–p22 (p23–p27 played none).
Source: each run's `bot-prod-smoke.log` (result, opponent, length) and `gambit-*.log`
(the GAMBITD decision lines and the end-of-game stats). Logs are in `logs/handoff/run-<id>/`.

## Results

| Opponent | Games | Won | Lost | Avg game | Longest |
|---|---|---|---|---|---|
| Azyyy | 54 | 52 | 2 | 1:29 | 4:51 |
| Jdawson | 19 | 19 | 0 | 1:49 | 4:12 |
| FabiDFox2004 | 8 | 8 | 0 | 1:09 | 2:29 |
| Tanycanayt | 7 | 4 | 3 | 7:39 | 22:51 |
| Legshot | 6 | 6 | 0 | 1:36 | 2:41 |
| LAZGamer | 4 | 4 | 0 | 1:47 | 2:51 |
| some_noob | 2 | 2 | 0 | 1:54 | 3:33 |
| KillGore | 1 | 1 | 0 | 1:41 | 1:41 |
| **Total** | **101** | **96** | **5** | | |

Wins average 1:37 (median 1:26). Losses average 8:57 (median 4:14).

## How Gambit kills (93 of the 96 wins matched to decision logs)

1. It stacks the opponent to the top with 2–3 mid-size attacks. They are topped out
   (row 12) within 4 s of one of its attacks in 77 of 93 wins.
2. A topped-out opponent lives only on their stop timer. Median time topped out before
   death: 3.6 s.
3. Gambit keeps feeding garbage until that timer reaches 0: 2–3 more attacks, about 1.9 s
   apart. The last one lands a median 0.7 s before the death. The stop timer was 0 at the
   end in 91 of 93 wins.
4. Mode at the last decision: `finish them` in 91 of 93. Last move: mostly hold or carry.
5. What it threw: chains of 2–5 (3 and 4 most common) and combos of 4, 6 and 8; often a
   chain with a combo inside it. Chains of 7 or more almost never decided a game.
   Typical last three: `chain3 → chain4`, `combo4 → combo4 → combo5`,
   `chain5 → chain2+combo4 → chain2`.

Not known: the shape of the garbage (width, height, where it landed). The logs record only
chain and combo sizes. Getting shapes would mean replaying the saved inputs through the engine.

## The 5 losses

| # | Run | Opponent | Length | What the log shows |
|---|---|---|---|---|
| 1 | p13 | Azyyy | 0:35 | Mode `pressure`. Final ~14 decisions are all `hold` with the death forecast `dies=1` (about to die). Opponent not topped out (row 11). |
| 2 | p13 | Azyyy | 0:46 | Opponent was topped out with stop time, then recovered (row 10, 160 stop). Gambit threw chain 2–3 with combo 3–4 but never combo 4+. Last line: `finish them`, `hold`, `dies=30`. One engine rollback for late garbage (opponent copy 53 frames behind) in this match. |
| 3 | p13 | Tanycanayt | 16:18 | Opponent topped out 81% of the game and survived. Mode was `finish them` in 2521 of 2898 decisions (87%). 330 garbage landings on Gambit. Last line: `hold` at `dies=1`. |
| 4 | p18 | Tanycanayt | 4:14 | Mode `pressure`, `hold` at `dies=1`. Opponent not topped out (row 9). |
| 5 | p19 | Tanycanayt | 22:51 | Opponent topped out 82% of the game (1116 s of 1371 s) and survived. `finish them` in 3457 of 4047 decisions (85%). 477 garbage landings on Gambit. Last line: `hold` at `dies=3`, opponent at stop 90 (their timer was full). |

## Patterns

- **Tanycanayt out-stalls it (losses 3 and 5).** Gambit gets them topped out but cannot
  finish: their stop time keeps getting refilled (stop 90 near the end of loss 5). Gambit
  threw one attack about every 5.6 s in the 22-minute game, versus about 6.3 s in a normal
  win, so it did not push harder when the game dragged on. It stays in `finish them` and
  holds for most of the game while garbage keeps landing on it, until its own stack dies.
- **It holds while the death forecast says it is dying (losses 1, 3, 4, 5).** The last
  decisions of four of the five losses are `hold` with `dies` between 1 and 3. This is the
  last logged line, so it shows what it was doing at the end, not that holding caused the loss.
- **Short losses to Azyyy (1 and 2)** came in `pressure` and early `finish them`, not in a
  stalemate. In loss 2 it had the opponent topped out and let them recover.
- Wins show that mid-size repeated attacks work. The losses show the same bot not being able
  to convert when the opponent keeps their stop timer alive.

## Limits of this analysis

- 5 losses is a small sample. Three are against one player.
- The logs do not record Gambit's own stack height or the incoming garbage queue, so what
  actually killed it is inferred from the `dies` forecast and the garbage-landed counts.
- Not checked: whether the same two behaviours (holding while `dies` is small, and staying
  in `finish them` against a protected opponent) also cost time in the wins.

## Where the code lives

Gambit is in GameCreator (`games/the-game/ai/gambit/`), not in this repo.
Analysis scripts are in the session scratchpad (`kills.py`, `pat.py`, `loss.py`, `table.py`).

---

# Second batch — runs p28 to p48 (5 Nov 10:09 to 6 Nov evening)

278 games against 20 opponents: **269 won, 9 lost (96.8%)**. Wins average 1:24 (median 0:57).
Losses average 2:14 (median 2:07). Run p30 (the older `Ranmaru` run) had no log artifact and p49 was
still running, so neither is counted.

Both batches together: **379 games, 365 won, 14 lost (96.3%)**.

| Opponent | Games | Won | Lost | Avg game | Longest |
|---|---|---|---|---|---|
| Bramp | 32 | 32 | 0 | 0:40 | 1:38 |
| javi | 31 | 29 | 2 | 2:31 | 6:02 |
| eeeeyuke | 27 | 27 | 0 | 0:59 | 3:07 |
| KillGore | 24 | 24 | 0 | 1:04 | 3:19 |
| Bowser | 23 | 23 | 0 | 1:23 | 3:05 |
| Mako | 23 | 22 | 1 | 1:10 | 3:43 |
| FabiDFox2004 | 19 | 17 | 2 | 1:20 | 2:25 |
| Kevin123 | 18 | 17 | 1 | 1:49 | 9:23 |
| Wyniverse | 17 | 17 | 0 | 1:45 | 3:37 |
| StreetsTM | 14 | 13 | 1 | 0:36 | 0:59 |
| Snicholas289v2 | 11 | 10 | 1 | 2:25 | 7:58 |
| MabPa | 10 | 10 | 0 | 0:41 | 1:47 |
| mrbad | 8 | 8 | 0 | 2:40 | 6:13 |
| Mastershadow | 7 | 6 | 1 | 2:40 | 7:28 |
| DonVonVinii | 6 | 6 | 0 | 1:15 | 3:14 |
| ponv | 3 | 3 | 0 | 0:24 | 0:35 |
| Deagle | 2 | 2 | 0 | 2:11 | 2:30 |
| Andrej, LAZGamer, some_noob | 1 each | 3 | 0 | | |

## The 9 losses

"Opp topped out" is the share of the game the opponent spent at row 12. "Landings" is how many
times garbage landed on Gambit. The mode is the mode of the last decision.

| # | Run | Opponent | Length | Mode at the end | Opp topped out | Landings | What we threw | Last logged move |
|---|---|---|---|---|---|---|---|---|
| 1 | p28 | StreetsTM | 0:10 | opener | 0% | 2 | nothing | break_line |
| 2 | p35 | Kevin123 | 6:57 | finish them (89%) | 65% | 43 | 63 attacks, chains 2–7, combos 4–8 | hold |
| 3 | p38 | FabiDFox2004 | 0:43 | finish them | 1% | 4 | chain 4, 5, 6 | hold |
| 4 | p38 | FabiDFox2004 | 2:07 | pressure | 51% | 15 | 21 attacks, mostly 2–6 | hold |
| 5 | p39 | javi | 2:19 | pressure | 67% | 48 | 33 attacks | hold |
| 6 | p40 | Mastershadow | 2:58 | pressure | 34% | 28 | 33 attacks | hold |
| 7 | p44 | javi | 0:31 | pressure | 19% | 5 | combo 4 ×2, chain 2, chain 6 | hold |
| 8 | p47 | Snicholas289v2 | 4:01 | finish them (97%) | 81% | 57 | 62 attacks | hold |
| 9 | p48 | Mako | 0:21 | opener | 0% | 2 | chain 5 | hold |

## Patterns across the 9

- **Two more stalemates, the Tanycanayt shape (2 and 8).** Kevin123 and Snicholas289v2 were
  topped out for 65% and 81% of the game and still did not die. Gambit sat in `finish them` for 89%
  and 97% of its decisions and was killed by garbage first.
- **Four early losses, 43 s or less (1, 3, 7, 9).** Two ended in `opener`, one in `finish them` and one in
  `pressure`. In 1 and 9 the opponent was never topped out; in 9 Gambit's stack was already
  high (mat 56) with garbage still landing (108) and it threw one chain 5. These are lost races,
  not stalls.
- **Three mid-length losses in `pressure` (4, 5, 6).** Against javi, FabiDFox2004 and Mastershadow the
  opponent was topped out for 34–67% of the game, but Gambit had dropped back to `pressure` by the end.
  In 5 and 6 the last line is `hold` with `dies=1` (the death forecast) and no garbage in flight (land 0).
- **8 of 9 end on `hold`.** This is the last logged line, so it shows what the bot was doing at the end,
  not that holding caused the loss. It is the same signature as the first five losses (4 of 5).
- Across all 14 losses, 4 are stalemates against a protected opponent (Tanycanayt ×2, Kevin123,
  Snicholas289v2, with the third Tanycanayt loss in `pressure`), and the rest are short losses
  in the opening or in `pressure`.

## Limits

- Loss 1 (10 s) only logged 23 decisions in `opener`, and the end of its decision log is about 110 frames
  past the game length, so the match between the two logs is approximate.
- The logs do not record Gambit's own stack height or the incoming garbage queue.
- As before, 14 losses in 379 games is a small sample.
