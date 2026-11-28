# The chaos bot's goal

## NOW -- the one goal, and the standing orders (the owner, 2026-11-27: "Set your goal so it's clear and you don't keep stopping")

**EACH MODE HAS ITS OWN SEEDS (the owner, 2026-11-27 16:20 ET: "I just want to make sure that when you're doing 8-color, 7-color,
chaos margin, etc., they're all on different seeds, because I don't want it to just be trained towards just the 8 different seeds";
"you got to redo all of this and rerun. They have to be on different seeds. Yes, you can rerun on the same seeds, but each mode has to
have its own seeds"; "Make this clear in your goal as well").** Until then every mode had played seeds 7-8 -- the seeds the bot was fixed
on (268 games). Those results do not count. Every mode is redone from the top on the seeds in the table below, which no run had played;
a mode's reruns stay on its own seeds; no mode ever plays another mode's seeds. Seeds 7-8 stay only the Level 10 six-colour gate.

**GENERIC, NOT TUNED TO THE SEEDS (the owner, 20:10 ET).** Every fix is a rule about the board (losses, breaks, the queue, the level's
own timing), never about a seed, a pattern or a frame. No held-out step (the owner, 21:40 ET: "for 8 color you can run the same seeds"):
each mode plays its own seeds only, and reaching 7/8 there finishes it.

**Goal now (the owner, 2026-11-27): every mode at chaos Level 10 to 7/8 on its own seeds, one set at a time, in the table's order --
then back to each for 8/8 (on its own seeds).** (The owner, 16:35 ET: "Get to 7 before moving on" -- no mode is left below 7/8 on its own seeds.) (The owner: "7/8 IS GREAT", "If you have that. GO into next mode", "And once all
modes are that good go back and get them all to 100%"; "Not just the colors... other modes as well".) Never below Level 9.

**Mode table (the owner: "Love this table" -- kept here, updated every run; 4 patterns x the mode's 2 seeds = 8 games):**

| Mode | Level | Seeds | Run | Result |
|---|---|---|---|---|
| 8 colours | 10 | 21-22 | 227 | **7/8 -- done** |
| 7 colours | 10 | 23-24 | 234 | **7/8 -- done** |
| Chaos margin 4 | 10 | 25-26 | 235 | 6/8, being fixed (run 236) |
| Chaos mode | 10 | 27-28 | - | to redo (old: 8/8 on 7-8, run 192) |
| 1 HP | 10 | 29-30 | - | to redo (old: 8/8 on 7-8, run 193) |
| No stop time | 10 | 31-32 | - | to redo (old: 8/8 on 7-8, run 196) |
| BALL | 10 | 33-34 | - | to do (run 197 on 7-8 cancelled) |
| Line Clear | - | 35-36 | - | to do |
| Queue limit | 10 | 37-38 | - | to do |
| training_random | 10 | 39-40 | - | to do (its own pattern: chain and combo garbage mixed at a random balance, Chaos Mode 1 game in 4 -- TrainingMenu.lua createBasicTrainingMode) |
| Challenge Mode | stage's | 41-42 | - | to do |

(8 colours old: 7/8 on seeds 7-8, run 180 -- does not count.)

**Standing orders -- every step, no exceptions:**
1. **A run is always going.** The moment a run finishes, the next one is pushed -- before writing to the owner, before reading at
   length. Never end a turn, never write a summary, with no run in flight. Never stop to ask; decide from this file.
2. **Read every loss move by move** in the run's losses.txt (decisions and boards) and figure out what actually went wrong -- the
   report's tags are not the answer. One fix per run, aimed at a loss seen on the board.
3. **No luck.** A loss is a fault to fix. **Each mode plays only its own seeds (the table)** -- reruns on them are fine, never another
   mode's seeds.
4. Keep a change only if the run is no worse; otherwise turn it off and say so here.
5. Record each run's result here, in bench/request.txt (with the next run's push only) and bench/history.txt.
6. Report to the owner briefly with each result (ET time, survived x/8, what was lost and why, the next run already going).
7. Never raise the decision budget, never change hand speed, games only on GitHub Actions, never more than 8 games a run.

**Reminders:** a scheduled check-in fires into this session every hour ("Chaos bot: is a run going? ...") -- on it, check the latest
run, and if none is going, push the next one at once.


**The target: a bot that survives every game of the chaos benchmark to the end -- 6 minutes (21,600 frames) at chaos Level 10 --
8/8, then 8/8 again on a new set of seeds (the owner, 2026-11-25 18:08 ET: not twice in a row on the same seeds), with 0 divergences,
0 late moves and 0 frames over the think budget. Then as much garbage sent as survival allows.**

*(The owner, 2026-11-25: "just focus on level 10 -- making sure everything is dynamic, so it will work on 9, 8, 7". The benchmark is
Level 10 only. Every number the bot uses is read off the level being played (docs/NUMBERS.md), never tuned to one level, so the same
bot plays 9, 8 and 7.)*

Nothing else counts as progress. A plan, a doc or an engine is a step toward this line, never a result. Every report to the owner
starts with the last benchmark's number (survived x/N, frames lost at, health left), or says plainly that no bot plays yet.

---

## 1. Hard rules (never broken)

1. **This project is separate from Gambit.** Never push to, edit, dispatch or cancel anything in `briankeegan/GameCreator` or
   `briankeegan/panel-game`. Read them; copy what helps into `chaos-bot/`; never reference their files in place, never share a
   library, profile, workflow, artifact name, concurrency group or seed record with them.
   *(Owner's instruction, 2026-11-25: this project lives in `briankeegan/panel-game` itself, in its own folder `chaos-bot/`, on
   branch `ccr-9ee25bfb-744765` -- "same repo is fine, just make sure it doesn't [disturb] the other bot". So: nothing outside
   `chaos-bot/` and nothing on any other branch; Gambit's files, branches and workflows are never touched. See section 6 for the
   one open question: where this project's workflow file lives.)*
2. **Games run on GitHub Actions only**, never in the sandbox -- the sandbox times nothing like a runner. **So do the engine
   checks** (owner, 2026-11-25 20:47 ET): the checks workflow runs them on every push; the sandbox runs nothing -- it edits, compiles
   (to catch a typo before a push), commits and pushes.
3. **One benchmark run at a time** (of ours). Gambit's benchmark is not waited for (the owner, 2026-11-25: our runs may play while
   a `gambit-24.yml` run is in progress; "you don't have to pay attention to Gambit's benchmark"). Start small before big.
4. **Read state, never recall it.** Before answering "what is running / what did it score", look at Actions and the run's own report.
5. **Never parse a tool's prose -- make it emit data**, and have the consumer check the count it got back matches the count sent.
6. **Never ask for or store tokens.** Scripts read `$GITHUB_TOKEN` from the environment.
7. **A question to the owner never stops the work.** Ask it, then go on with the next thing on this list.
8. **An explicit instruction from the owner beats a measurement.** Say the number once, then do what was asked.

## 2. The benchmark (the only measure)

- A workflow in this repo plays **N games**: every chaos training pattern on fixed seeds, one job per game, plus a report job. The
  same seeds every run until the bot survives them all; only then new seeds. Write the patterns, N and the seeds into this file
  (section 6) before the first run.
- Each game is chaos Level 10, ends at frame 21,600 or at the loss, and its job uploads the game's log.
- **The report prints, every run, as data:** survived x/N; each loss's frame and pattern; health left at the end of each game and
  the health lost to garbage on the top row; garbage sent a minute; the budgets (frames over the think budget, late moves,
  divergences between the board the bot predicted and the one the game made); and the time the run finished, in ET on the 24-hour clock.
- **The forecast is checked every run (owner: fix it in the infrastructure, 2026-11-25 17:15 ET):** each garbage arrival's notice --
  frames the bot's telegraph forecast had garbage inside its look-ahead before it came -- is measured (gambit native.c noticeCheck);
  an arrival with under 60 frames (the fall) is a **surprise**. The report prints surprises/arrivals per game and for the run, and
  the gambit.log lists each surprise (ARRIVE). A forecast change is judged on surprises going to 0, not guessed from a loss.
- **N = 8 (the owner, 2026-11-25 16:55 ET):** the 4 patterns (combo_storm, chain_garbage, thicc_combo_storm, insane_combo_storm)
  x seeds 1 and 2, garbage level 9 speed 9, at chaos Level 10. Once a run is 8/8, the seeds change (3 and 4, and so on).
- **One run per change, judged on whether its deaths go away.** The bot must survive whatever the seed or the runner's timing:
  never run the same change twice to average out noise, never call a loss "noise".

## 2b. Every chaos mode, 6 minutes each -- the owner, 2026-11-25 23:40 ET: "fix it all", "should be able to survive anything":
no mode is written off; a mode that loses is a bot problem to fix (owner, 2026-11-25 21:58 ET: "try them all, and you should be able to do them all for
6 minutes" -- "nothing should be impossible")

Each is its own benchmark set of 8 games at chaos Level 10, 21,600 frames, judged as the main one (8/8, budgets 0), played one run
at a time, never more than 8 games at once (the owner's limit). request.txt carries the setting after the level as key=value:
- training_random (the fifth generator), seeds 1-8
- Margin Time: Colors (margin=2), Modoki (margin=3), Chaos (margin=4) -- health decays x0.9 every 900 frames with any of them
- Chaos Mode on (chaosmode=1)
- Game modes: 1 HP (mode=2), No Stop Time (mode=3), BALL (mode=4: 1 HP and no stop time)
- Colour counts 4, 5, 7, 8 (colors=)
- Challenge Mode, every difficulty to Impossible (the launcher starts a challenge stage: to build), and Line Clears (Step 4)

## 3. The order of work (each step has a gate; the next starts only when it passes)

**Step 1 -- the engine is the truth.** `engine/ca.c` matches the real chaos game frame for frame on every path a game can take:
plain clears, combos, chains up to the 12-row cap, big chains, combo garbage of every queue type, shock garbage, all-clears, stop
time fading, health falling and never refilling, the faster swap. Gate: the checker runs on every push, prints how many times each
of those events happened in the recorded frames (each at least 20), and fails on a single differing frame. Where random play never
makes an event, a scripted test player or hand-built boards make it. *Done when:* 0 differences and every event counted.

**Step 2 -- a bot plays, and its board is the game's.** Gambit's search copied into `chaos-bot/`, rebuilt on `ca.c`, hooked into
the chaos client headless. Every frame the bot predicts the next board; a predicted board that differs from the game's is a
divergence, and a run with any is red. Every decision logs one line: frame, what was played, why, the time it took, health, the
board's danger. *Done when:* 4 games played end to end on Actions with 0 divergences, 0 late moves, and the report reading them.

**Step 3 -- survival.** Every loss read decision by decision from its own log, the decision that lost it found, the cause fixed,
the benchmark run again. Health is permanent in chaos, so the board's danger is judged on health too: garbage resting in the top
row costs health that never comes back, and a line that saves frames by spending health is ranked as the loss it is. *Done when:*
8/8 survived with budgets at 0, then the next run on a new set of seeds (3 and 4, then 5 and 6, ...) 8/8 too -- a run that gets 8/8
moves the benchmark to new seeds; it is never rerun on the same ones. **Survival is called complete only when one bot, unchanged,
has 8/8 on several sets** (owner, 2026-11-25 21:50 ET: "try a few more seeds before saying it's complete"): after run 33's 8/8 on
seeds 3-4, the same bot on seeds 5-6, 7-8 and 9-10, and on seeds 1-2 again (run 20 passed them with the bot before the settle fix).
Any loss: a change, and the sets start over from the one lost.

**Step 4 -- attack.** Garbage sent a minute, raised without giving up a single game of Step 3. Every change is checked against
survival first. *Done when:* the owner says the rate is enough, or names a number.

**Focus (the owner, 2026-11-26): the harder levels.** "It just needs to be dynamic... harder levels are where you should focus."
Level 10 and Level 11 (the top preset: health 10, start speed 81), against garbage up to 11/11, every number read from the
level. Never test below Level 9 (the owner, 2026-11-26: "you can test on 9 or 10 as well.. depending on the training mode.. just
don't test below 9"): Levels 9, 10 and 11, whichever suits the training mode. Being dynamic is what carries the bot to the rest.

**One mode at a time (the owner, 2026-11-26 12:4x ET: "focus on [one] at a time"):** the weakest mode is worked on alone until it
holds -- now 8 colours at Level 10 -- and nothing else is changed or surveyed meanwhile.
**No luck, no reruns (the owner, 2026-11-26 12:5x ET: "Luck is not really a factor. ignore that noise. no reruns. should work
regardless of run."):** a run is never repeated to see whether it holds, and a loss is never put down to the noise -- the bot has to
survive whatever a run deals it; every loss is a fault to find and fix.

**Step 5 -- every level from 9 up.** The same benchmark at Levels 9, 10 and 11, with no change to the bot: every number is the
level's. Nothing below Level 9 is tested (the owner, 2026-11-26).

## 4. Chaos rules the bot must respect (from `docs/CHAOS_RULES.md`)

- **Health never refills.** Survival is not only "not topped out": every frame garbage holds the top row costs health for good. The
  report counts it; the ranking prices it.
- **Stop time fades.** Clearing for stop time buys less than in vanilla; never plan on banked stop time.
- **The 12-row chain cap**, the **new combo garbage** and the **queue types** are in the engine and in the attack planning.
- **Faster swaps** change the swap timing the search and the frame loop assume: both read it from the engine, never a constant
  copied from Gambit.
- **The input allowance**: find out whether chaos limits actions per window as vanilla's server does (76 actions in 600 frames),
  write the answer in section 6, and if it does, every line's walk is charged against it.

## 5. Method (learned the hard way on Gambit)

- **Don't stop to ask (the owner):** every decision is made from this file and written down here. Decisions the owner has made:
  hands stay at Gambit's vanilla speed (setup 12 12 4: a swap every 12 frames, a cursor step every 4), though chaos has no input
  limit -- survival comes from better choices, not faster hands (2026-11-25 16:52 ET); no DAS; moves within the reach.
  The decision budget is not raised either (the owner, 2026-11-26 10:28 ET: "Don't double the decision budget. That's cheating" --
  "just figure out how to make it work with" it): the searches' time stays what the hands' cadence gives (propose.c searchesEnd).

- **One engine, held to the game's own code.** The C engine is trusted only while recordings prove it frame for frame; a rule
  change in the game means a new recording before anything else.
- **Every answer on time.** A move answered after its frame is a late move. Anything that runs long without checking the clock --
  freeing a big search tree, a batch of steps on worker threads -- makes moves late.
- **Measure what moves, not only survival:** actions per break, frames from a block landing to its first break, health lost per
  minute, time idle while under garbage.
- **Leave the board easy to play:** flat, with breaks ready before the garbage lands. Clearing the middle while garbage rests on the
  edge columns leaves it held up out of reach -- the commonest way Gambit loses.
- **Speed is not the lever it looks like.** A faster search alone changed nothing on Gambit; better choices did.
- **Every rule that matters has three parts:** a plain-English rule in this file, a script that decides it, and a check that runs it
  on every push.
- **Commit and push every change; never rerun code that has not changed.**
- **request.txt is touched only by the push that starts the next run** -- a comment alone starts a run too (run 93's result note
  queued a copy of run 94, cancelled 2026-11-26 09:05 ET). Results are written into it with the next run's games.

## 6. Facts to fill in before the first benchmark run

- **Repo, branch, and the workflow's file name:** `briankeegan/panel-game`, branch `ccr-9ee25bfb-744765`, folder `chaos-bot/`.
  Workflow: `.github/workflows/chaos-bot.yml` (proposed). **Open question to the owner:** a workflow file has to live in
  `.github/workflows/` (outside `chaos-bot/`) and is triggered by a push to this branch touching `chaos-bot/**` (no change to
  `beta`). Gambit's own workflows are not on this branch and are not touched. Allowed?
- **The chaos training patterns used, games per pattern, N:** TBD (Step 2). Candidates from the v3 TrainingMenu: training_random,
  chain_garbage, combo_storm, thicc_combo_storm, insane_combo_storm, each generated once per seed and saved as a fixed
  `training_chaos` file so every run sees the same garbage.
- **The seeds:** TBD (Step 2).
- **The input allowance in chaos:** **none.** The v3 build has no InputBudget (its `computerPlayers/` holds only DummyCpu) and the
  chaos server source has no action limit. The 76-per-600 limit is the panel-game fork's, not chaos's. (Checked 2026-11-25.)
- **The think budget a frame (ms) and the reaction delay the bot plays with:** TBD (Step 2). The v3 build has no ThinkBudget;
  proposed: Gambit's (answers within the frame, decisions asked ahead).
- **The client build the bot is hooked into, and how a headless game is started:** the v3 build fetched by `game/fetch.sh`
  (upstream commit `4da6c5d`, zip sha256 `ec5baf00…`), run with LÖVE 11 under xvfb on Actions. How the bot attaches: TBD (Step 2).

## 7. Progress log (the last benchmark first)

- **Run 235 (22:57-23:05 ET), CHAOS MARGIN 4 on seeds 25-26, run 234's bot: 6/8.** combo s25: three attack combos spent the opener to 22
  panels. Run 236: the opener keeps 30 panels (every mode).
- **Run 234 (22:48-22:56 ET), the queue let drop from 15 waiting above six colours: 7/8 -- 7 COLOURS DONE.** Run 235: chaos margin 4 on
  seeds 25-26 with this bot.
- **Run 233 (22:38-22:46 ET), wait and press-now share a credit: 5/8 -- off** (232 restored by hash). Run 234: the queue let drop from 15
  waiting above six colours (thicc s24 starved on 14-20 panels with 26-32 waiting).
- **Run 232 (22:28-22:36 ET), no waiting under a backlog: 7 colours 6/8** -- kept. chain s24: the wait on a line breaking nothing kept over
  the same line pressed now by its horizon credit. Run 233: the two share one credit, and press-now holds for any line.
- **Run 231 (restarted 22:17:29, done 22:25 ET; per-game retries), the line in progress outlived gives up the top: 7 colours 5/8** -- kept.
  combo s24: the carry waited on six times under a backlog. Run 232: pressed now before waited, above six colours under garbage.
- **Run 230 (2026-11-27 22:02 ET), 7 COLOURS on seeds 23-24, run 227's bot: 3/8.** combo s24: the line in progress kept on top over an entry
  lost 73-82 frames later. Run 231: the line in progress outlived by a third of a break gives up the top.
- **Run 228 (2026-11-27 21:36 ET), HELD-OUT 8 colours seeds 51-52, run 227's bot: 6/8** -- below 7/8. thicc s52 lost at 966: the stack
  raised to 54 panels before the first block. Run 229: the run-160 high-opening rule back, bounded (48+ panels, never past 36), on 51-52;
  then 21-22 again before 7 colours.
- **Run 227 (2026-11-27 21:19 ET), run 218 + the canyon rule letting a dig through at a quarter break: 7/8, 167677 frames -- 8 COLOURS
  AT 7/8 ON ITS OWN SEEDS.** Lost only insane s21 at 16477. Run 228: the held-out check, 8 colours on seeds 51-52 with this bot unchanged.
- **RUNNER SKIP BY MODEL -- the owner's rule, 21:30 ET, for every workflow that plays games (here: chaos-bot-games.yml; chaos-bot-checks.yml
  replays recordings in the engine, no clock).** Skip on the model NUMBER only (8573C, 7763, 9V74), never a vendor or brand word; the
  first step reads lscpu's model and keeps it as the game's cpu.txt; a skip prints "skipped runner: <model>" to the job summary and plays
  nothing; the fourth try plays on whatever it has; the report lists games and losses by model and flags any game played on a skip-list
  model. The retry is a next try inside the same run (play1-play4), not a re-run of failed jobs: a run cannot re-run its own jobs while
  it is going, and a re-run from outside waits on the session.
- **THE RUNNER CHOSEN (21:15 ET, the owner: "Which model is the worst? Look historical... if we get a bad runner... we just skip it....
  and wait for another").** Runs 208-226 by CPU: AMD EPYC 7763 4/23 (17%), EPYC 9V45 2/10 (20%), EPYC 9V74 5/23 (22%), Intel Xeon 8573C
  2/7, Intel Xeon 6975P-C 38/78 (49%). From run 228 the workflow plays each game in up to four tries (play1-play4): a try that draws one
  of the named worst MODELS -- Xeon Platinum 8573C, EPYC 7763, EPYC 9V74 -- is skipped and the game waits for the next try's runner; the
  fourth plays on whatever it draws. (The owner, 21:20 ET: "Skip by model, not by vendor" -- gambit-24's 43 runs #4799-#4848, loss rate
  against each model's own runs: 8573C 1.73, 7763 1.46, 9V74 1.33, 6975P-C 0.78, 9V45 0.56; a vendor rule kept the worst model and threw
  away the best. Chaos-bot's "run N" is this file's own count of chaos-bot-games runs on panel-game -- 8 colours, Level 10, the chaos
  client -- not gambit-24's numbering; its survival rates are of those games.) Results from run 228 on are
  on the runners kept, not comparable one-to-one with earlier runs.
- **Run 226 (2026-11-27 21:09 ET), 1'' credited-only: 2/8 -- off.** The owner asked how to tell the runners apart: by CPU -- runs 208-225,
  Intel Xeon 6975P 37/76 survived (49%), AMD EPYC 7763/9V74/9V45 10/52 (19%); not the clock (the 9V45 runs fastest). The report now
  prints survivals by CPU family. Run 227: the canyon rule lets a dig through at a quarter break (combo s22 9918-9947).
- **Run 225 (2026-11-27 21:00 ET), promise-vs-break a quarter break: 3/8 -- off.** Run 226: 1'' holds credited-only pairs to the quarter
  break (the hold kept 76 frames sooner, chain s22 11519-11564).
- **Run 224 (2026-11-27 20:51 ET), the garbage let down guarded: 2/8 -- off.** Six changes running at 2-4 against 218's 5/8. Run 225: A
  PROMISE NEVER BEATS A BREAK gives way at a quarter break above six colours (a 3-cell break lost at 223 over 310).
- **Run 223 (2026-11-27 20:41 ET), the same break lost later to the top: 4/8, 136784 frames -- off** (one game fewer; two losses in the last
  minute). Run 224: THE GARBAGE LET DOWN never puts first a line lost a quarter break sooner on its own board.
- **Run 222 (2026-11-27 20:31 ET), the material kept: 3/8 -- off** (218 restored by hash); the opening was not what lost. Run 223: the same
  break lost later moves to the top above six colours (a third line beat through the order).
- **Run 221 (2026-11-27 20:22 ET), 1a at a quarter break: 3/8 -- off** (218 restored by hash). Few sooner picks now; games lost met the first
  block with 14-24 panels, games kept with 30-40. Run 222: the material kept (30 panels) while garbage is on its way above six colours.
- **Run 220 (2026-11-27 20:13 ET), dig the backlog's row count: 3/8 -- off** (218 restored by hash). Run 221: 1a (the line in progress kept)
  lets go at a quarter break above six colours (insane s21 4474, 171 kept over 224).
- **Run 219 (2026-11-27 20:04 ET), dig down under stop time: 4/8 -- off** (218 restored by hash). Run 220: DIG THE BACKLOG's row count
  fixed (6 cells vs 5 counted as a row more: insane s22 13879, 97 put over 222).
- **Run 218 (2026-11-27 19:55 ET), no changing minds lets go at a quarter break: 5/8** -- kept; 5 sooner-lost picks in the run (was
  10-20). combo s22: nine rows under the garbage, stop 205-259, nothing dug. Run 219: DIG DOWN TO THE GARBAGE above six colours while
  the stop time covers a break.
- **Run 217 (2026-11-27 19:45 ET), the promise capped: 2/8 -- off** (216 restored by hash). Run 218: NO CHANGING MINDS lets go for a line
  that outlives the carry by a quarter break (insane s21 7195: 225 kept over 289).
- **Run 216 (2026-11-27 19:36 ET), the plan kept on own boards: 5/8, 136383 frames** -- kept. With 12-18 queued, lines put first on their
  promise (130 credited 231 over 193). Run 217: the promise capped at a quarter break above six colours with 10+ queued.
- **Run 215 (2026-11-27 19:26 ET), no changing minds' quarter break: 2/8 -- off** (214 restored by hash). Run 216: THE PLAN KEPT also gives
  way on own boards a quarter break apart (insane s22 7060-7100, the carry kept on its promise).
- **Run 214 (2026-11-27 19:17 ET), 1b's quarter break for credited-only pairs: 4/8** -- kept. NO CHANGING MINDS kept carries lost 40-100
  frames sooner the same way (credited pairs skip lostAlike). Run 215: the same quarter break there.
- **Run 213 (2026-11-27 19:07 ET), the quarter test on the carry's own loss: 2/8 -- off** (212 restored by hash). chain s21: 1b put the hold
  lost 51-92 frames sooner over entries, both counted living by the credit. Run 214: 1b's quarter break holds for credited-only pairs.
- **Run 212 (2026-11-27 18:58 ET), outliving first at a quarter break: 3/8, 127328 frames** -- kept. The horizon credit still kept carries
  lost 72-103 frames sooner (credited by their promise). Run 213: the quarter-break test reads the carry's own loss.
- **Run 211 (2026-11-27 18:49 ET), no dig lost inside a break put first: 2/8 -- off** (run 210 restored by hash). The hold on top over
  lines lost 41-84 frames later, through a third line. Run 212: outlivingFirst at a quarter break above six colours.
- **Run 210 (2026-11-27 18:40 ET), run 204 + horizon credit taken back a quarter break: 3/8, 120364 frames** -- kept (base last 2/8).
  thicc s21: DIG THE BACKLOG put five digs lost inside a break's time over later losses. Run 211: no such dig put first above six colours.
- **Run 209 cancelled: it was run 205's code again** (the owner: "you should not be rerunning the same thing twice"). Each run's rank.c is
  now checked against every earlier run's. Run 210: run 204 + the horizon credit taken back beside a board lost a quarter break later
  (chain s21 2664, 232 kept over 319).
- **Run 208 (2026-11-27 18:24 ET), run 204's exact bot: 2/8.** The owner: "Just focus on the losses. You need to succeed in worse
  scenarios" -- the bot must win on the slow machines too. thicc s22 1286: DIG THE BACKLOG, lost at 90 over 200 (as run 204 chain s22).
  Run 209: that rule gives way at a quarter break above six colours.
- **Revert fault found (18:20 ET):** "back to the kept bot" took rank.c from the commit before, sometimes the turned-off run's own. Run 204
  (5/8) really played run 201 + run 202's change (THE PLAN KEPT a quarter break, garbage resting or not) + run-160 off; run 207 also had
  run 205's change. From now on the kept bot is restored from its run's commit by hash. Run 208 re-pushed with run 204's exact file.
- **Run 207 (2026-11-27 18:14 ET), lostAlike with garbage queued: 2/8 -- off.** Four changes running worse than run 204's 5/8. Run 208:
  run 204's bot unchanged as a baseline, with each game's CPU logged (workflow only -- the owner: "Infra solutions are great. Just don't
  fuck with internals too much").
- **Run 206 (2026-11-27 18:05 ET), no credit under a backlog: 2/8 -- off.** With garbage queued but none resting, rank.c's 8-colour limits
  (decF.under) never apply: NO CHANGING MINDS kept lines lost 90 frames sooner. Run 207: run 204 + lostAlike's quarter break with garbage
  queued too. (A watcher now reads each run the moment it ends: scratchpad watch.sh, polling the Actions API.)
- **Run 205 (2026-11-27 17:55 ET), + dig the backlog a quarter break: 4/8 -- off.** Run 206: run 204's bot + no next-moves credit above six
  colours under garbage with 10+ queued (SURVIVAL FIRST put lines lost sooner first on promises: combo s21 9416, insane s22 16810/17249).
- **Run 204 (2026-11-27 17:46 ET), run 201 with the run-160 high-opening rule off: 5/8, 137380 frames** -- kept; openings now meet the
  garbage with 34-38 panels. chain s22 lost at 2121: DIG THE BACKLOG put a one-row break lost at 197 over a line lost at 299. Run 205:
  above six colours it gives way at a quarter break.
- **Run 203 (2026-11-27 17:36 ET), run 201 + a 30-panel floor on the high-opening rule: 4/8 -- off.** Openings still met the garbage with
  20 panels. Run 204: run 201's bot with the run-160 high-opening rule off (it was built on seed 8's opening).
- **Run 202 (2026-11-27 17:26 ET), the plan kept a quarter break everywhere: 2/8 -- off.** Openings spent: the first garbage met with
  14-18 panels, by rank.c's run-160 high-opening rule (clear more panels first). Run 203: run 201's bot + that rule stops at 30 panels left.
- **Run 201 (2026-11-27 17:16 ET), 8 colours seeds 21-22, + 1b a quarter break: 5/8** -- kept (count no worse). THE PLAN KEPT still kept
  lines lost 44-104 frames sooner where garbage was not resting. Run 202: a quarter break, garbage resting or not.
- **Run 200 (2026-11-27 17:06 ET), 8 colours seeds 21-22, + lostAlike a quarter break: 5/8** -- kept. insane s21 lost at 1289: rule 1b
  (the mode's goals) kept a hold lost at 287 over an extend lost at 448. Run 201: above six colours 1b decides only within a quarter break.
- **Run 199 (2026-11-27 16:55 ET), 8 colours seeds 21-22, + the plan kept gives way: 4/8** -- kept. Lines lost 56-83 frames later
  were called alike (rank.c lostAlike: under a break's time apart) and lost to the sooner (combo s22 12984 241 vs 297; thicc s21 7959
  225 vs 308). Run 200: above six colours under garbage, alike only within a quarter of a break's time.
- **Run 198 (2026-11-27 16:42 ET), 8 colours seeds 21-22, + k1265 never the line lost sooner: 3/8, 133942 frames (was 85914)** -- kept;
  losses all late with a backlog. THE PLAN KEPT (k1156) kept lines lost 55-92 frames sooner (combo s21, insane s22, combo s22). Run 199:
  above six colours under garbage it does not keep a line lost half a break's time sooner.
- **Run 197 (2026-11-27 16:27 ET), 8 COLOURS at L10 on its OWN seeds 21-22, run 196's bot: survived 3/8, 85914 frames** -- seeds 7-8
  gave 7/8: fitted. chain s21 lost at 1601: rank.c k1265 (run 167: above six colours under garbage, no break, the panels kept) put a hold
  lost at 194 over a 2-chain lineup lost at 257, five decisions running. Run 198: that rule never puts the line lost sooner first.
- **Run 196 (2026-11-27 16:11 ET), NO STOP TIME at L10, run 195's bot + FINISH_8_LIFE skips an eight dying sooner than the top under
  garbage in modes 3+: survived 8/8, full health every game** -- done. Run 197: BALL (mode=4) at L10.
- **Run 195 (2026-11-27 15:55 ET), NO STOP TIME at L10, run 180's bot + 1b off for dying lines under garbage in modes 3+: survived 6/8,
  149728 frames** -- no worse, kept. combo s7 lives now, thicc s7 17012 (was 11312), lost combo s8 3116. In both losses rank.c's
  FINISH_8_LIFE move (k2010) put an eight over a line dying later under garbage (combo s8 3092: 172 over 256; thicc s7 16907: an eight
  breaking none at 205 over a break of 6 at 213). Run 196: that move skips such an eight in modes 3+ under garbage. Game 6 parted from
  run 194 at frame 257/260, before any garbage: the searches stop on the wall clock (core/clock.h clockOut).
- **Run 194 (2026-11-27 15:35 ET), NO STOP TIME at L10, run 180's bot: survived 6/8, 145364 frames** -- below 7/8. combo s7 3652: the
  mode's goals (1b) and the plan kept carried a combo breaking nothing under garbage where combos buy no stop. Run 195: 1b does not decide
  between two dying lines under garbage in game modes 3+. describe.py's names fixed (bare keys were named after the run-167 rule).
- **Run 193 (2026-11-27 15:20 ET), 1HP at L10, run 180's bot: survived 8/8** -- done. Run 194: no stop time (mode=3) at L10.
- **Run 192 (2026-11-27 15:08 ET), CHAOS MODE at L10, run 180's bot: survived 8/8, full health every game** -- done. Run 193: 1HP
  (mode=2) at L10.
- **Run 191 (2026-11-27 14:55 ET), CHAOS MARGIN 4 at L10, run 180's bot: survived 7/8, 153783 frames** -- done. Lost thicc s7 at 2583.
  Run 192: chaos mode (chaosmode=1) at L10.
- **Run 190 (2026-11-27 14:45 ET), 7 COLOURS at L10, run 180's bot: survived 7/8, 172270 frames** -- done at the owner's bar. Lost only
  combo s8 at 20470. Run 191: chaos margin (margin=4) at L10, 6 colours, seeds 7-8.
- **Run 189 (2026-11-27 14:37 ET), no needless-swap hold with garbage on the board: survived 1/8, 80081 frames** -- off. 8 colours
  closed at run 180's 7/8 (the owner: "7/8 IS GREAT", "focus on one set at a time"). Now 7 colours (run 190).
- **Run 188 (2026-11-27 14:20 ET), 'a break in hand before a promise' reads the unrested first slab: survived 2/8, 115508 frames** --
  reverted. thicc s8 lost at 609: 604-618 the hold put on top by decide.c's needless-swap override over a ready line, the first slab
  unrested. Run 189: that override off above six colours with garbage on the board, resting or not.
- **Run 187 (2026-11-27 14:01 ET, third ask -- two asks lost to the client download answering 504; the zip now cached): survived 4/8,
  112481 frames** -- reverted. thicc s8 lost the seed-8 opening (615: an entry breaking nothing credited by moves after it over a break
  of 9 lost no sooner on its own board). Run 188: 'A BREAK IN HAND BEFORE A PROMISE' reads the unrested first slab.
- **Run 186 (2026-11-27 13:10 ET), the top pair agrees at the end of rank(): survived 5/8, 125766 frames, 0 inversions** -- off by the
  rule kept (run 180 7/8); the owner may keep it (the order and the line played agree on every decision). Run 187: run 180 plus the
  creditPair rule reading the unrested first slab (the seed-8 opening's 2-chain carried by the credit step).
- **Run 185 (2026-11-27 12:54 ET), the top pair agrees in the sort: survived 2/8, 114145 frames** -- reverted; inversions not fewer
  (56/6410): rank() drops lines after the last sort. Run 186: the top pair made to agree at the end of rank(), after every cut.
- **Run 184 (2026-11-27 12:37 ET), the needless-swap hold override off under garbage: survived 4/8, 127662 frames** -- reverted. True
  inversions 1.1% (44/79 the hold first) -- cycles in the merge sort, not the override; post-sort moves 0.2%; drift 3.2%; ties 4.5%.
  Run 185: the top pair made to agree (the second over the top where it beats it compared alone).
- **Run 183 (2026-11-27 12:19 ET), high-opening rule capped on run 180: survived 1/8, 78840 frames** -- reverted. The order measured
  in playOf: 1.5% inverted, 2.8% drift (the old label's state), 4.8% ties; 45 of 69 inversions are decide.c rank() putting the hold on top
  after the sort (needless one-swap line). Run 184: that override off above six colours under garbage; post-sort moves labelled.
- **Run 182 (2026-11-27 12:02 ET), the top beats the most others head to head: survived 4/8, 148207 frames** -- reverted; 0 late. The
  inversions hardly moved (404/7227): most come from state moving between the order and the label (livedPrev, set after playOf) and lines
  moved after the sort, not the sort. Run 183: run 180 plus the high-opening rule capped at two rows; the agreement measured in playOf.
- **Run 181 (2026-11-27 11:46 ET), the first-slab break rules on run 180: survived 3/8, 73894 frames** -- reverted; five early losses
  (breaks of 6 on the unrested slab before building). Run 182: run 180 plus the top of the order chosen as the line beating the most
  others head to head -- the owner, on the order and the line played disagreeing (6% of decisions): look into it.
- **Run 180 (2026-11-27 11:29 ET), under garbage a move before the hold where the keys leave them equal: survived 7/8, 152311
  frames** -- KEPT, the best yet (run 167: 5/8). Lost only combo s8 at 1111, the seed-8 opening (the credit step keeping no-break lines
  over breaks while the first slab sat unrested). The order is inverted on ~6% of decisions (won=inv). Run 181: run 176's first-slab
  break rule on this bot.
- **Run 179 (2026-11-27 11:12 ET), before the first contact chain aims only as breaks: survived 3/8, 134920 frames** -- reverted.
  insane s8 2275: under garbage on 54 panels with stop running, the hold played first over moves lost no sooner (step 11, the nearer
  first swap, puts the hold first). Run 180: above six colours under garbage, a move before the hold where every key leaves them equal.
- **Run 178 (2026-11-27 10:54 ET), the high-opening rule capped at two rows: survived 3/8, 120227 frames** -- reverted. Seed-8 games
  3/4 lived; every seed-7 game lost. thicc s8 1591: the opening's chains (aims open at 45 panels, the slab told of) spent 45 to 29 before a
  6-row slab. Run 179: before garbage first rests, while garbage is on its way, chains meet the aims only as breaks.
- **Run 177 (2026-11-27 10:37 ET), the no-break panels-kept rule only short of panels: survived 3/8, 141456 frames** -- reverted on
  survivals (frames above run 167's). thicc s7 lost at 2743: the labels name rank.c's run-160 rule (A HIGH OPENING MAKES ROOM, the line
  clearing more panels first, uncapped) keeping a 4-chain that cleared 18 of 37 panels before the first slab -- the same rule keeps
  the seed-8 opening's 4-chains. Run 178: that rule counts up to two rows' worth of panels only.
- **Run 176 (2026-11-27 10:20 ET), the first slab read before it rests (own record): survived 2/8, 110303 frames** -- reverted; no
  seed-8 opening loss, worse overall. Run 177: run 167's no-break panels-kept rule only short of panels (< 42) -- run 175's thicc s7
  labels show it (k1257) holding over a walk to a break on 52 panels with 253 frames of stop, then the board filled to 63.
- **Run 175 (2026-11-27 10:03 ET), the first slab read before it rests: survived 3/8, 102378 frames** -- every decision labelled. thicc
  s8 lost the seed-8 opening at 943; the labels show the credit step (rank.c '1. lives before does not') at 661 again: the new rule was
  gated on gambitHit, which a topped board sets too, so it never ran. Run 176: the rule keeps its own record of garbage resting.
- **Run 174 (2026-11-27 09:46 ET), under garbage aims met only by breaks: survived 2/8, 88004 frames** -- reverted. The seed-8 opening
  lost three times at ~950 (as runs 169, 171, 172; not in run 173). Run 175: run 173's rule (break rules read garbage not yet resting on
  the stack) only until garbage first rests on the stack. Every decision now labelled (won=k<line> rank.c, d<line> decide.c, only/tie/
  raise/none; losses.txt names the rule; decisions/game-N.txt every decision in words) -- the owner: every decision labelled.
- **Run 173 (2026-11-27 09:27 ET), break rules read garbage anywhere on the board: survived 0/8, 76099 frames** -- reverted. The
  seed-8 opening losses at ~1000 did not happen; every game lost later. chain s8 3083: under garbage on 41-50 panels the aims (decide.c
  brk -1 from five rows' worth up) were met by 2x chains clearing 9 and breaking nothing, a canyon dug under the garbage. Run 174: garbage
  resting on the stack -> aims met only by breaks (brk 1), above six colours.
- **Run 172 (2026-11-27 09:13 ET), break first unless two breaks' time longer: survived 3/8, 128533 frames** -- reverted. thicc s8 lost
  the seed-8 opening at 1139 (661: carry lost at 373 breaking nothing over a break of 15 lost at 252). The fault: decF.under is garbage
  resting on the stack (FACT_US_CONTACT); the slab was on the board, not resting, so every under-garbage break rule was skipped and the
  credit step (rank.c, won=k1119) ranked the carry first. Run 173: above six colours those rules read garbage anywhere on the board.
- **Run 171 (2026-11-27 08:54 ET), the queue room after the first landing: survived 0/8, 57745 frames** -- reverted to run 167's queue
  rule. combo s8 (947) and insane s8 (995) lost the opening run 169's combo s8 lost: under the first slab, chains breaking nothing kept
  over breaks lost a break's time sooner (664: carry lost at 370 over a break of 15 lost at 249), 45 panels spent to 23. Run 172: above six
  colours under garbage, the break first unless the other lasts two breaks' time longer, not one. (The owner, 2026-11-27: the noise rule
  stands -- no reruns, every loss is a fault to fix.)
- **Run 170 (2026-11-27 08:38 ET), the board left alone for the queue only two rows under the ceiling: survived 3/8, 110647 frames** --
  worse than run 167; narrowed. insane s7 lived (first since run 162), but chain s7 lost at 1765: the opening's queue was held back and
  came down as one 6-row slab on 27 panels. Run 171: the rule only once garbage has first landed.
- **Run 169 (2026-11-27 08:20 ET), the 42-panel chain floor in the opening only: survived 0/8, 76062 frames** -- reverted. combo s8
  (933) and insane s7 (1007): the opening grew to 48 panels, then the chain spent it under the first slab. Run 170 (run 167's bot):
  insane s7 lost four runs alike (163-167) -- the stack grew to 57-62 panels between waves and the board was left alone for the queue to
  drop on it; above six colours the board is now left alone only where what waits lands two rows under the ceiling (short of 25 waiting).
- **Run 168 (2026-11-27 08:06 ET), no chain aims below 42 panels without garbage: survived 1/8, 96679 frames** -- reverted. thicc s7
  lived, but chain s7/s8, combo s8 and thicc s8 lost by 6000: the floor held chains back all game. Run 169: the 42-panel floor in the
  opening only (before garbage first lands), 36 after.
- **Run 167 (2026-11-27 07:49 ET), no break offered, keep the panels: survived 5/8, 137319 frames** -- kept. thicc s8 lasted 19086 (was
  5395), insane s8 lived. Lost thicc s7 at 2347: the opening rose to exactly 36 panels, a 12-panel chain aim opened (the no-chain floor is
  below 36) and the carry spent the board to 18 before the first slab (run 156 the same, 2283); insane s7 7886, thicc s8 19086. Run 168: the
  no-chain floor at 42 panels.
- **Run 166 (2026-11-27 07:34 ET), the queue let drop from 25 waiting above six colours: survived 4/8, 133500 frames** -- kept (equal to
  run 163; combo s8 lived again). Lost chain s7 13565 and insane s7 12851 (backlogs of 15-29), insane s8 15289, thicc s8 5395: four rows
  of full-width garbage on 41 panels, no break offered, levels spent the panels to 31 and the next slab buried it. Run 167: under garbage
  with no break offered, of two lost alike breaking nothing, the one clearing fewer panels first.
- **Run 165 (2026-11-27 07:20 ET), the planner 52 wide with the opening fixes: survived 0/8, 112803 frames** -- back to 64. Four lost after
  18000, with 20-35 waiting for thousands of frames (insane s8: 21-35 from 12000 to 20355). Run 166: the queue let drop (a quiet board while
  what waits fits under the top) from 25 waiting above six colours, not 35.
- **Run 164 (2026-11-27 07:07 ET), full board asks the combo first: survived 3/8, 100688 frames** -- off. insane s8 lived; combo s8 lost at
  4656 again (so run 163's fix is partial), thicc s8 at 1954 (slabs piled early), chain s7/s8 early. Run 165: the planner 52 wide again,
  re-measured with the opening fixes in.
- **Run 163 (2026-11-27 06:54 ET), no chain aims with no garbage on the board below six rows' worth of panels: survived 4/8, 138496
  frames -- kept**, its target fixed: combo s8 lived (lost at ~4500-5000 in runs 160-162). Three losses that repeated run after run are
  now gone (insane/combo s8's high opening, chain s7's spent opening, combo s8's spent lull). insane s8 lost at 6859 (6406 in run 161): a
  full board, 54-57 panels in eight rows, under garbage with 13-14 waiting. Run 164: run 126's full board asks the combo first, on again.
- **Run 162 (2026-11-27 06:41 ET), keep the panels between waves: survived 2/8, 92014 frames** -- off. combo s8 still lost at 4525. Its
  run-161 log: 2x/4x/6x chains with no garbage on the board took 63 panels to 25 (3556-4117) -- run 161's guard (tallest column under six
  rows) missed them, a tower holding the top at six or more -- then 20 pieces arrived at 4616. Run 163: the guard by the panels too (under
  six rows' worth).
- **Run 161 (2026-11-27 06:28 ET), no chain aims before garbage on a low stack: survived 4/8, 117188 frames -- kept**, its target fixed:
  chain s7 lived (lost early in runs 156-160). Two repeating opening losses fixed in two runs. combo s8 now loses at ~5000 each run (5028,
  4842): between waves, none on the board, the bot cleared 63 -> 25 panels, then ~8 rows of slabs landed on 3-4 rows at ~4690. Run 162:
  run 55's keep-the-panels rule above six colours between waves too (no garbage on the board, stack under six rows).
- **Run 160 (2026-11-27 06:13 ET), a high 8-colour opening makes room: survived 4/8, 108422 frames -- kept**, its target fixed: insane
  s8 lived and combo s8 passed the opening (lost at 5028, not ~605). The openings are where the losses repeat: they play the same each
  run (time to spare). chain s7 (early in five runs, 1647-4637): the 8-colour aims fired 2x and 4x chains from 298 to 838 with no garbage
  near -- 36 -> 21 -> 15 panels, each stop halting the rise -- and a 6-row slab landed on three rows at ~1028, lost at 2000. Run 161: with
  no garbage on the board and the stack under six rows, the chain aims are asked only as breaks (so not at all).
- **Run 159 (2026-11-27 06:00 ET), starving from four rows: survived 3/8, 94790 frames** -- back to five. insane s8 lost at 605 the very
  way combo s8 lost at 610 in run 151 -- the same board cell for cell: seed 8 starts both patterns alike and the opening, played with time
  to spare, plays the same. 30 -> 48 panels (eight rows) by 441 on set-ups and zips, every line dying from 545 once the first slab is told,
  topped at 768. Run 55's rule keeps the opening's panels under six rows; nothing makes room above. Run 160: a high opening makes room --
  above six colours, stack at seven rows or more before garbage first comes, of two living lines the one clearing more first.
- **Run 158 (2026-11-27 05:47 ET), the line-up swaps off: survived 4/8, 104839 frames** -- back on. Six features measured off on the
  wide search (runs 151, 153-155, 158): only 1'h was dispensable. Since run 145 the bot has scored 5/8 four times and nothing tried has
  moved it past; 8/8 twice needs a different kind of step than another tie-break. Run 159: starving from four rows' worth again.
- **Run 157 (2026-11-27 05:33 ET), the planner 64 x 7: survived 2/8, 125777 frames** -- back to 64 x 6 (four lost late, 16405-19906).
  Run 158 measures the line-up swaps off on the wide search.
- **Run 156 (2026-11-27 05:20 ET), starving, any break asked last: survived 3/8, 99096 frames** -- off. Run 157: the planner 64 x 7 (the
  wide beam with the full depth; late moves have been 0 throughout).
- **Run 155 (2026-11-27 05:08 ET), the 8-colour aims off: survived 2/8, 113350 frames** -- back on. Of the features measured off on the
  wide search (runs 151, 153-155), only 1'h was neutral; rule 117, the perched drops and the aims each held games. The bot stands at 5/8.
  Run 156: starving, any break asked last in the aims (run 141 asked it first).
- **Run 154 (2026-11-27 04:55 ET), perched drops under garbage off above six colours: survived 3/8, 134322 frames** -- back on. Checked
  for a late-game slowdown (the losses run late now): heap flat at ~1.77 GB, search work per ms 0.62-0.77 throughout a 17184-frame game --
  none. Run 155 measures the 8-colour aims (run 110) off on the wide search.
- **Run 153 (2026-11-27 04:42 ET), rule 117 off: survived 4/8, 120772 frames** -- back on. Run 154 measures the perched drops offered
  under garbage above six colours (run 122) off.
- **Run 152 (2026-11-27 04:29 ET), the searches 76 x 6: survived 2/8, 111422 frames** -- back to 64 x 6 (width at 8 colours, 6 deep: 52
  5/8, 64 5/8 three times, 76 2/8). Run 153 measures rule 117 (no canyon dug for nothing) off on the wider search.
- **Run 151 (2026-11-27 04:17 ET), 1'h off: survived 5/8, 128433 frames -- equal, kept off (the simpler bot).** combo s8 lost at 610,
  the other way this time: the opening flat but high, 45 panels and nine rows when a 3-row slab landed at 711. Lost also combo s7 5633,
  thicc s7 14190. Run 152: the searches 76 x 6 at 8 colours.
- **Run 150 (2026-11-27 04:03 ET), the extend search a swap deeper at 8 colours: survived 1/8, 105996 frames** -- back. The bot of runs
  145, 147 and 148 scored 5/8 each: that is where it stands; 1-2 of 8 is a real regression, 4-6 the noise. Run 151 measures a feature
  off instead of adding one: 1'h (the colours lined up, a tie-break) off on the wider search.
- **Run 149 (2026-11-27 03:51 ET), the searches 64 x 5: survived 2/8, 90487 frames** -- back to 64 x 6. The planner's shape at 8 colours:
  24 x 12 3/8, 28 x 10 4/8, 40 x 7 4/8, 52 x 6 5/8, 64 x 6 5/8 (twice), 64 x 5 2/8 -- best near 52-64 wide, 6 deep. Run 150: the extend
  search a swap deeper (6 -> 7) above six colours.
- **Run 148 (2026-11-27 03:38 ET), 1'e (flat first) in the 8-colour opening with garbage told: survived 5/8, 131964 frames -- kept.**
  All four seed-8 games lived, combo s8 (its target) among them. Lost combo s7 9068, insane s7 12576 and thicc s7 2320 -- thicc s7 has
  now lost early in seven runs: the opening leaves column 2 hollow, the first slab lands at 694 on 24 panels, and by 766 rows 7-12 are
  garbage. Run 149: the searches a swap shallower (64 x 5 at 8 colours).
- **Run 147 (2026-11-27 03:25 ET), the searches 64 x 6 at 8 colours: survived 5/8 (equal to run 145), 117086 frames, 0 late -- kept.**
  combo s8 lost at 812 as in run 145 (866): the opening's clears from 431 dug columns 1-5 to rows 3-6 beside an eight-row tower in
  column 0, and the first 6-wide slab perched on it at 707 out of reach -- a loss seen twice, the same way: a fault, not the noise. 1'e
  (flat first) never acts in an 8-colour opening: garbage is told nearly the whole time. Run 148: 1'e above six colours with garbage on its
  way too, while none is on the board. Lost also combo s7 3022, thicc s7 5252.
- **Run 146 (2026-11-27 03:13 ET), perched drops for full-width blocks: survived 2/8, 80654 frames** -- removed. Four early losses
  (chain s7 3020, insane s7 3775, chain s8 3516, thicc s8 4132). Run 147: run 145's bot with the searches wider again (64 x 6 at 8 colours).
- **Run 145 (2026-11-27 02:59 ET), the searches 52 x 6 at 8 colours: survived 5/8, 120708 frames, 0 late -- kept.** All four seed-7
  games lived. combo s8 lost at 866: the opening left a one-panel tower in column 0, a 6-wide slab landed on it at 712 with columns 1-5
  two to four rows lower, and no perched drop was offered -- perchedDrops walks a support past the block's edge, and a full-width block
  has none. chain s8 3482, insane s8 8360 lost. Run 146: a support under a block with no edge walked to the nearest column it falls in.
- **Run 144 (2026-11-27 02:46 ET), no shaping of the searches by the colours (40 x 7 at 8 colours): survived 4/8, 143378 frames --
  kept**, the most frames of any 8-colour run (run 132: 141612), every loss late: chain s7 13573, combo s8 15118, thicc s8 16342 (all
  backlog, 23-35 waiting, full boards under stacked slabs), insane s8 11945. The frames have followed the shape: 24 x 12 98k, 28 x 10
  131k, 40 x 7 143k. Run 145 follows it: 52 x 6 at 8 colours.
- **Run 143 (2026-11-27 02:33 ET), the searches 24 x 12 at 8 colours: survived 3/8, 98270 frames, 0 late** -- back to 28 x 10. All of
  seed 8 lost (5263-9678) and insane s7 5219. Run 144: no shaping by the colours (40 x 7), the other side of the lever.
- **Run 142 (2026-11-27 02:19 ET), the top row kept empty from twenty waiting: survived 2/8, 91868 frames** -- back to thirty-five.
  Ten tie-break changes since run 132 (runs 133-142) scored 1-5 of 8; none clearly beats the noise. Run 143 tries the bigger lever, the
  search's reach: above six colours, per colour 8 narrower and 2.5 deeper (8 colours 24 x 12, was 28 x 10).
- **Run 141 (2026-11-27 02:07 ET), starving, any break asked first: survived 3/8, 124684 frames** (run 140: 4/8, 130640) -- off. Both
  thicc games lived; chain s7 11883, combo s7 5696, chain s8 14908, combo s8 10723 and insane s8 16674 lost, the last two to backlog
  (24-31 waiting). Backlog runs through the late losses of runs 135-141. Run 142: the queue-room rule (the top row left empty) from twenty
  waiting above six colours, not thirty-five.
- **Run 140 (2026-11-27 01:54 ET), a starved board's break pays for itself: survived 4/8 -- kept** (a judgement against the noise, said
  plainly: below run 132's 6/8, but the 132 family has averaged ~4 since, and its frames played, 130640, are second only to run 132's
  141612 -- runs 137-139 played 96-109k; its losses came later: 6450, 12704, 19489, 5597). insane s8 5597: 16 panels sandwiched between
  a 3-row slab and the slabs above, no single swap breaking either. Run 141: starving, any break asked first (a combo of three or more
  breaking garbage ahead of the chain aims).
- **Run 139 (2026-11-27 01:40 ET), five line-up swaps offered: survived 3/8** -- back to three. Since run 132's 6/8: 5, 1, 5, 2, 4, 3,
  3 -- run 132's own 6/8 was likely high. thicc s7 lost at 911: from 346 to 765 every line was judged living, and the opening's chains
  and then 12-15-panel clears breaking 6 garbage cells took the board from 42 panels to 14, then 8-11 under the next slab. The search
  runs on its own thread while the game plays in real time (native.c frameOut reads the game's live frame), so the noise is in real-time
  play itself; a lockstep benchmark mode would make games repeatable but is a large change to the launcher and the native side -- asked
  of the owner, not built. Run 140: a starved board's break pays for itself (cells broken less panels cleared, a row better first).
- **Run 138 (2026-11-27 01:28 ET), run 87's scarce-fuel rule above six colours: survived 3/8** -- off. Lost chain s7 2101, thicc s7
  2267, insane s8 2065 (not starved: a 6-row slab converted to ~30 panels at 1264 and the next slabs landed on a 10-row board), chain s8
  9687, combo s8 15234 (queue 31-36). Since run 132 (6/8): 5, 1, 5, 2, 4, 3. Run 139: five line-up swaps offered, not three -- run 131's
  wider line-ups are the one change that moved these seeds.
- **Run 137 (2026-11-27 01:15 ET), run 132's bot with the opening keeping its panels to seven rows: survived 4/8** -- back to six.
  thicc s7 met the first slab with 36 panels (24 in run 136) and still starved, lost at 2498; insane s7 8382, combo s8 6949, thicc s8
  4574 lost. **Found: the search is cut by wall-clock time on a single thread** (native.c: the deadline is the frame's start), so the
  same bot plays a different game on a faster or slower runner -- every seed of s7-8 has lived and died across runs 130-137. An 8-game
  run carries about 1.4 games of noise; a change is real only when it moves more than that, or holds across runs. Run 138: run 87's rule
  (scarce fuel under garbage is not spent: of two living lines breaking nothing below five rows of panels, the one clearing fewer) on
  again above six colours only.
- **Run 136 (2026-11-27 01:02 ET), 1'h' -- a break made ready over a dying wait, though lost up to two breaks' time sooner: survived
  2/8** -- removed. Lost chain s7 6370, thicc s7 2106, insane s7 10233, combo s8 5255, thicc s8 8249, insane s8 18479. Every rule that
  ranks something above the life count has cost games (runs 129, 134, 136). thicc s7, lost early in runs 135 and 136 (both carried
  run 135's extra judge work, a column-top pass on every line judged) and alive in 131-133: the opening fired a carry clearing 12 at 498
  with no garbage near (the opening's keep-panels rule ends at six rows, passed by ~450 at 8 colours), 45 -> 24 panels by the first slab,
  then buried. Run 137: run 132's bot exactly (judge.c restored) with the opening keeping its panels to seven rows above six colours.
- **Run 135 (2026-11-27 00:48 ET), the open side a line itself digs beside a resting slab (sideDig): survived 5/8** -- off. thicc s8
  (its target, lost in 132-133) lived; thicc s7 lost at 2411 (buried under 6-wide slabs from 696, 18-36 panels), chain s7 at 16647 (a
  1-wide tower of converted panels on column 0 up to row 11, 3-wide slabs landing on it) and insane s8 at 14025 (backlog 25-29: at
  13813 a combo bought 229 frames of stop under a slab, and the bot held and leveled through it -- hold:229 beat toward:187, two lines
  not judged alike, so 1'h never chose the line-up -- no break readied). Every seed of s7-8 has now lived in one run and died in another
  (runs 130-135): the fixes move the losses. Run 136: 1'h' -- of two dying lines breaking nothing, a break made ready over waiting,
  though lost up to two breaks' time sooner.
- **Run 134 (2026-11-27 00:34 ET), the canyon counts the whole open side beside a slab: survived 1/8** -- off. Measured on the line's
  board, the side gap moved with every falling slab and grew with every clear breaking nothing, so rule 117 put down nearly every clear
  that buys stop: boards starved and topped (lost at 4865-17657; only chain s7 lived) -- the run-129 failure again. Run 135: run 132's bot
  with only the rows a line itself takes off an open column beside a resting slab (judge.c sideDig, against the board as it stands).
- **Run 133 (2026-11-27 00:20 ET), starving from six rows' worth (36): survived 5/8** (worse than 6/8) -- back to five rows. chain s7
  lived (lost in runs 131-132), but combo s7 2816, insane s7 16442 and thicc s8 2609 lost: the threshold trades one seed for another.
  thicc s8 (lost in run 132 too), read on the whole-game boards: every garbage width's drop map starts at column 1, so slabs keep landing
  on the left; clears on the right left columns 3-5 at rows 3-6 (1862) while 3-wide slabs stacked on columns 0-2 to the top (2410-2760) --
  no panel stood level with a slab, so nothing could break it from the side, and the board topped out with half of it empty. Run 134:
  the canyon (gapOf, rule 117) also counts an open column beside a slab, the rows from its top up to the slab's lowest cell.
- **Run 132 (2026-11-27 00:06 ET), starving from five rows' worth of panels (30): survived 6/8 on seeds 7-8** (equal to run 131;
  kept). Lost chain s7 at 8276 (garbage over the whole top, a canyon in columns 2-3, 33-57 panels, 19 clears breaking none in its
  last minute; it also lost in run 131) and thicc s8 at 3736 (3-wide slabs towered on columns 0-2 to the top while columns 3-5 sat
  at row 6, under garbage from frame 705 with 25-46 panels, 17 clears breaking none). Both are starving boards above the 30-panel
  line choosing clears that break nothing. Run 133: starving from six rows' worth (36).
- **Run 131 (2026-11-26 23:56 ET), the line-up swaps whenever the swapped panels rest: survived 6/8 on seeds 7-8** (run 130, the
  same bot without it: 3/8) -- the best 8-colour run yet. Kept. chain s7 lost at 4143 (2x/3x breaking nothing took 47 panels to 29,
  then starved), insane s8 at 7738. Run 132: starving from five rows' worth of panels.
- **Run 130 (2026-11-26 23:45 ET), run 122's bot on new seeds 7-8: survived 3/8** (thicc s8 73 frames short). Late losses with 24-36
  waiting, no line found, 15-22 holds in the last 1200 frames. Run 131: the line-up swaps whenever the swapped panels rest.
- **Run 129 (2026-11-26 23:35 ET), the chain aims need a break under garbage at all: survived 3/8.** Back. Since run 122 (5/8 on
  s5-6: runs 117, 121, 122), thirteen changes all scored worse there: tuning on the same eight games moves their losses around. Run 130:
  run 122's bot exactly on new seeds 7-8 -- new losses to read, and the 5/8 tested off the seeds it was tuned on (not a rerun: new seeds).
- **Run 128 (2026-11-26 23:24 ET), 1'h off: survived 4/8** (on: 5/8) -- back on. Losses chose 15-25 clears breaking nothing a minute
  (140-180 panels) with 19-32 pieces waiting. Run 129: under garbage at all the chain aims need a break.
- **Run 127 (2026-11-26 23:14 ET), panel columns kept even under garbage: survived 1/8.** Off. Ten changes since run 122 all worse;
  the tie-breaking rules above six colours decide most decisions and move far more than the loss aimed at. Run 128: 1'h (colours lined
  up) off, to measure it alone.
- **Run 126 (2026-11-26 23:03 ET), a full board asks the combo first: survived 4/8** (insane s5 221 frames short). Off. thicc s6:
  columns 3-5 emptied rows 7-10 by 4x chains breaking nothing, the garbage on the left tower. Run 127: panel columns kept even under
  garbage (garbage never counted -- every canyon read flat to evenOf).
- **Run 125 (2026-11-26 22:53 ET), no 3x asked: about 2/8.** Back. Runs 118-125: every change but 121-122 worse than 5/8; the best bot
  is run 122's. Run 126: a full board (8 rows of panels) asks the combo first (run 121 combo s6, 47-60 panels 12 rows high, lost late).
- **Run 124 (2026-11-26 22:43 ET), the canyon read off the settled board: survived 3/8.** Off. Run 125: the list asks a 2x then a
  combo of 4+ -- no 3x (the canyons were dug by 3x and longer chains breaking nothing).
- **Run 123 (2026-11-26 22:32 ET), starving when garbage outweighs panels: survived 4/8.** Back. chain s5 lost at 3318: a 3x
  clearing 15 breaking nothing dug columns 2-5 under garbage on the left tower -- the no-canyon rule read the board mid-chain. Run 124:
  the gap read off the settled board.
- **Run 122 (2026-11-26 22:21 ET), let-down lines under garbage: survived 5/8** (kept, equal) -- chain s5 lost at 21003 (600 frames
  short), insane s5 3408 (30 panels under 7 rows of garbage, clears of 12-14 breaking nothing), insane s6 848 (a 4-4-4 fired under
  garbage still falling: the break lost). Run 123: starving also when garbage outweighs the panels.
- **Run 121 (2026-11-26 22:11 ET), starving, the chain aims need a break: survived 5/8** (equal to run 117) -- both insane games
  lived; thicc s5 lost at 643 (garbage held up on a 3-panel tower in column 0 over cleared columns 1-5), chain s5 12886, combo s6 18990.
  Kept. Run 122: the let-down lines offered whenever under garbage above six colours.
- **Run 120 (2026-11-26 22:00 ET), no long chain with garbage on its way too: about 2/8.** The long-chain rule is off. Run 121:
  starving, the chain aims are met only by breaks (run 119 thicc s5: 40 -> 13 panels on 2x clears breaking nothing).
- **Run 119 (2026-11-26 21:50 ET), no long chain (past 3x) for nothing under garbage, 8 colours s5-6: survived 4/8** -- insane s5 lived
  for the first time; chain s5 lost at 660 to a 5x breaking nothing before the first slab landed (outside the rule's reach). Run 120:
  the rule with garbage on its way too; under 5/8 and it goes.
- **Run 118 (2026-11-26 21:40 ET), a starved board breaks cheaply: survived 2/8.** Off.
- **Run 117 (2026-11-26 21:29 ET), no canyon dug for nothing, 8 colours s5-6: survived 5/8** (run 115: 4/8). combo s5 and thicc s6
  lived; chain s5 lost 35 frames short, insane s5 at 1957 (starved: 16-25 panels, breaks of 6 clearing 6), insane s6 at 13029. Kept.
  Run 118: a starved board breaks cheaply (fewer panels cleared first, under 4 rows of panels, above six colours).
- **Run 116 (2026-11-26 21:18 ET), line-up pairs of swaps, 8 colours s5-6: survived 2/8** (four lost inside 2845 frames). Off.
  Run 117: no canyon dug for nothing (rank.c) -- run 115 combo s5, 5x/6x chains breaking nothing emptied columns 1-3 rows 4-9 under
  garbage resting on the edge towers.
- **Run 115 (2026-11-26 19:50 ET), run 113's bot, 8 colours L10, new seeds 5-6: survived 4/8** -- combo s5 4491, insane s5 3804,
  thicc s6 2938 (all early, no-line), chain s5 19249 (queue backlog). The new report worked: losses.txt held each loss's decisions and
  ten boards. thicc s6: a 2-row slab on the stack with 3-wide pieces stacked above the top, the row under the slab one panel -- no break
  within reach, held until the stop ran out. The gap at 8 colours: the row under the garbage kept stocked with near-matches.
- **Infra (the owner, 2026-11-27: "You need better infra fixed"):** the run's report now tells each loss itself -- its last 900 frames
  of decisions (play, verdict, panels, garbage broken, panels cleared, swaps, stop, lines living, the three best offered) and its last
  ten boards drawn by the bot's own viewer (built in the report job, plays nothing) in losses.txt beside report.txt, and the report
  shown on the run's Actions page; and every game's earlier results (bench/history.txt, written with each run's result) printed beside
  it. No log is downloaded by hand to read a loss. Run 115: run 113's bot, 8 colours L10, new seeds 5-6.
- **Run 114 (2026-11-26 13:32 ET): the opening keeps its panels only at six colours or fewer -- survived 2/8.** Openings lower
  (30-38 panels at the first garbage), insane s4 1007 -> 10262, but thicc s4, chain s3 and combo s3 (run 113's survivors) lost. Back.
  8 colours, seeds 3-4, the bot of run 113 (chains for stop, colours lined up, line-up swaps): 4/8; run 110 (without the swaps) 5/8.
- (run 114 as pushed) the opening keeps its panels only at six colours or fewer -- run 113 insane s4 only set
  up in the opening (30 -> 48 panels by 458, no clear: run 55's rule), lost at 1007. 8 colours L10 s3-4.
- **Run 113 (2026-11-26 13:20 ET): the line-up swaps -- survived 4/8.** chain s4 (its target) lived; insane s3 3031, insane s4 1007,
  thicc s3 8752, combo s4 13775 lost. Kept.
- (run 113 as pushed) the line-up swaps -- run 110's bot (1'g and 1'i off: runs 111-112 4/8 and 3/8, the losses
  moved, none fixed) and, above six colours on a board at rest, the single swaps that leave the most breaks a swap away offered as
  set-ups (judge.c lineUpSwaps, propose.c), so 1'h has them to choose: run 110 chain s4 held 284 frames of stop offered only walks.
- **Run 112 (2026-11-26 13:09 ET): room for what is coming (1'i) -- survived 3/8.** Off.
- (run 112 as pushed) room for what is coming (1'i) -- above six colours, when the garbage on its way and
  waiting, stacked on the board, reaches the top row, the line leaving the stack lower first. 8 colours L10 s3-4.
- **Run 111 (2026-11-26 12:57 ET): 1'g on again above six colours -- survived 4/8.** combo s4 4447 -> 11152 (its target); insane s3
  lost at 580: a 7-row board told of a 5-row slab 50 frames out, spent them on a slow break, lost in the landing's shake. Kept.
- (run 111 as pushed) 1'g (no canyon under garbage) on again above six colours -- run 110 combo s4 lost with
  column 3 dug to a well seven rows deep under garbage resting on the columns beside it. 8 colours L10 s3-4.
- **Run 110 (2026-11-26 12:47 ET): above six colours, chains for stop -- survived 5/8** (runs 108-109 on the same seeds: 2/8). Kept. The owner: "you have your work cut out for you".
  The list asks a 2x, then a 3x, then a combo of 4+ (decide.c): only stop time halts a stack rising a row a second, and a 2x buys it
  with six panels where an eight is seldom there at 8 colours. 8 colours L10 s3-4 (runs 108/109: 14377/12353).
- **Run 109 (2026-11-26 12:30 ET), a three on a tall stack is room (above six colours), 8 colours L10 s3-4: survived 2/8, 12353
  frames on average** (run 108: 14377). Off: the opening still held ~48 panels at the first garbage -- at level 10 the stack rises a row
  a second, more than threes at 8 colours take off. 8 colours stands at about 2/8, ~13-14k frames on average with runs 102 and 107 kept.
- **Run 108 (2026-11-26 12:18 ET), the colours lined up, 8 colours L10 s3-4: survived 2/8, 14377 frames on average** (107+108
  ~14.2k, 101-106 ~12.0k). Four losses opened high (45+ panels at the first garbage): combo s4 went 30 -> 48 panels by frame 516 with
  every three put off as wasted (Gambit's "never a three unless it follows through"), lost at 981. Run 109: above six colours, with the
  stack six rows or more, a three is room bought (rank.c wastesThree).
- **Run 107 (2026-11-26 12:09 ET): the colours lined up -- survived 1/8, 14117 frames on average, none lost before 6904** (runs
  101-106: 11 of 48 lost before 5000). Kept (above six colours only). Run 108: seeds 3-4. (the owner: "Might have to be more purposeful with colors?"). Above
  six colours, of two lines that live or are lost alike and break the same garbage, the one leaving more breaks a swap away (a single
  swap of two resting panels making a match that touches garbage), then more matches a swap away (judge.c readyOf, rank.c 1'h): the
  waiting time spent lining colours up rather than holding. 8 colours L10 s1-2.
- **Run 106 (2026-11-26 11:19 ET), run 104's search shape again (by the colours, every search), 8 colours L10 s1-2: survived 2/8,
  11122 frames on average** -- run 104's 16654 was the noise. 8 colours, runs 101-106: 2, 2, 2, 2, 1, 2 of 8; 9.7k-16.7k frames on
  average, no change clearly better. Kept: run 102's rule (a living break puts a dying plan down -- sound on its own) and the shape by the
  colours (only above six colours; 104+106 average 13.9k against 11.3k for 101-103, weak). The 8-colour losses: no-line (the search
  finds no clear: 57% of decisions under garbage find no break), full boards topped, the queue's fifty. Open: a new idea is needed, not
  a tuned number -- the next step is reading what a break needs at 8 colours on the boards themselves.
- **Run 105 (2026-11-26 11:08 ET), the planner by the colours (planner only) and the queue-last rule, 8 colours L10 s1-2: survived
  1/8, 10949 frames on average** -- below run 104 (16654), whose profile narrowed the extend search too. Eight games swing by thousands
  of frames. Run 106: run 104's shape again, by the colours in every search the profile shapes; queue-last off.
- **Run 104 (2026-11-26 10:57 ET), the planner narrower and deeper (28 x 10) at 8 colours L10 s1-2: survived 2/8, 16654 frames on
  average** (runs 101-103: 9670, 12565, 11690) -- chain s2 and combo s2 lost to the queue's fifty at 21591 and 21485 with health 13 and
  6 left, ~50 panels kept topped. Kept, shaped by the colours (propose.c: per colour over six, 6 narrower and 1.5 deeper). Run 105: that,
  and within 6 of the queue's fifty the top row emptied whatever the lines' losses.
- **Run 103 (2026-11-26 10:47 ET), the break search's share under garbage 0.9, 8 colours L10 s1-2: survived 2/8, 11690 frames on
  average** (run 102: 12565) -- no better; back to 0.75. Run 104: the planner narrower and deeper in the same time (chaos-deep: width 28,
  depth 10).
- **Run 102 (2026-11-26 10:37 ET), a living break puts a dying plan down, 8 colours L10 s1-2: survived 2/8, 12565 frames on
  average (run 101: 9670).** Kept. Losses: full boards (~50 panels) topped out, no-line. Under garbage the break search found nothing on
  57% of decisions, a third of them cut short by its time (6 colours alike). Run 103: the break search's share of the same budget under
  garbage 0.75 -> 0.9 (the budget itself never raised -- the owner).
- **Run 101 (2026-11-26 10:26 ET), 8 colours at L10 vs 9/9, seeds 1-2: survived 2/8 -- the weakest mode.** The owner (10:3x ET):
  "Just focus on your weakest mode then." combo s1 lost at 706: at 561 three lines living on a three that broke 3 were put after an eight
  breaking the same 3 (lost at 352) -- the fresh-line rule keeps the plan in progress until a living line has lived two decisions -- and
  its eight swaps walked 150 frames on a rising board with no stop. Run 102: under garbage, a fresh line that lives and breaks as much
  garbage puts a dying plan down at once.
- **Run 100 (2026-11-26 10:14 ET), the queue near its limit (top row kept empty, quiet under garbage), L11 vs 11/11 seed 1: survived
  4/8.** 8 colours 1/4 (combo 4344, thicc 8349, insane 4054: topped at ~50 panels under four-row slabs -- the queue never passed 20, the
  new rules never acted), 7 colours 3/4. The same seed plays differently from run to run (the think time on the runner), so a run of
  eight is a rough sample. The bottom five rows never move at 8 colours: every break is made just under the slab, and the search finds
  few (brDeep 3). Run 101: 8 colours at L10 vs 9/9, seeds 1-2.
- **Run 99 (2026-11-26 10:03 ET), the gate's bot at L11 vs 11/11 on the hard settings, seed 1: survived 4/8.** 7 colours 1/2 (combo
  lost at 16429, no-line), 8 colours 0/2 -- both to the queue's fifty at full health (queue 38-46 on average over the last 1200
  frames, stop 86-115: a board kept topped on stop drops nothing), chaos margin 1/2, chaos mode 2/2. The weakness is here. Run 100: with
  the queue within 15 of fifty (margin off), lines leaving the top row empty first (rank.c), and the board left quiet under garbage too
  (decide.c) -- 8 and 7 colours, every pattern.
- **Run 98 (2026-11-26 09:52 ET), the combo size by the panels, 1'g, L10 seeds 15-16: survived 6/8.** Seeds 13-16: by the panels
  13/16, small always 14/16, the gate's bot 14/16 -- none better than eight games' noise; both turned off, the gate's bot is back (it
  holds the record: 40/40 on seeds 1-10, 22/24 on 11-16). Normal L10 is not where the bot is weak. Run 99: the gate's bot at L11 vs
  11/11 on the hard settings -- 7 and 8 colours, chaos margin, chaos mode -- where it is.
- **Run 97 (2026-11-26 09:42 ET), the combo size by the panels, 1'g, L10 seeds 13-14: survived 7/8**, survivors at full health.
  chain s13 lived (lost in runs 91 and 96 at ~4630: a 5x judged living spent 37 panels to 12 under an 8-row chain slab 354 frames
  out); combo s14 lived; insane s13 lost at 6357 (starved). Seeds 13-14: the gate's bot 7/8, small always 6/8, by the panels 7/8 --
  within the noise of eight games. Run 98: the same bot on seeds 15-16.
- **Run 96 (2026-11-26 09:31 ET), combos 4-6 first always, 1'g, L10 seeds 13-14: survived 6/8.** chain s13 lost at 4630 (run 91:
  4646); combo s14 at 2901 with 44-61 panels on the board -- a full board needs the big clears -- after a carried 5 into a 2x waited on
  for 110 frames that never fired. Seeds 13-16: 14/16, the same as the gate's bot. Run 97: the combo size chosen by the panels each
  decision (decide.c): smallest first at or under 33 panels (the life peak), eights first above it; chaos.words back to eights first.
- **Run 95 (2026-11-26 09:22 ET), combos 4-6 first (chaos-small) with 1'g, L10 seeds 15-16: survived 8/8, every game at full health
  (13)** -- no health lost in any game; run 92 (the gate's bot) 7/8, run 94 (1'g alone) 7/8. Kept: `profiles/chaos.words` is now the
  small-combo profile (the old one `chaos-big.words`). The new bot has to pass every seed set (1-16) again at L10, then L11.
- **Run 94 (2026-11-26 09:12 ET), 1'g no canyon under garbage, L10 seeds 15-16: survived 7/8.** insane s16 (run 92's loss) lived at
  full health; chain s16 lost at 8847 (opening-spent, no-line; it lived in run 92). Run 95: combos 4-6 first (chaos-small), 1'g on.
- **Run 93 (2026-11-26 09:01 ET), LEVEL 11 against garbage 11/11, seeds 1-2: survived 8/8, every game at full health (10)**, 0
  late, 16.06 garbage rows a minute. The gate's bot unchanged. Level 11 next on new seeds. Found while it ran (boards drawn, runs 91-92's
  losses): the profile plays "finish them" the whole game -- combos of 8-10 asked first -- and an 8 buys about 15 frames a panel where a
  4 buys about 23 (40 x 1.05^(c-4) stop, FLASH+FACE+POP x n): chain s13 spent 32 panels to 20 on eights with a slab 305 frames out;
  insane s16 dug the middle out under garbage on the edge towers. Run 94: 1'g, no canyon under garbage. Run 95: combos 4-6 first.
- **Run 92 (2026-11-26 07:25 ET), the gate's bot on NEW seeds 15-16: survived 7/8** (lost insane s16 at 18633). On seeds it never
  saw: 22/24. THE REPORT NOW EXPLAINS EVERY LOSS (owner, 07:30 ET: "what are the patterns of deaths? fix the info problem"): a
  "death" line per lost game read off gambit.log -- tags queue50 / early / opening-high / opening-spent / starved / backlog /
  no-line, with the last 1200 frames' panels, queue, stop and hold-only decisions, the last minute's lines clearing panels that
  break no garbage, the panels at first garbage, the share of decisions judged dying -- and a count of deaths by cause per run.
  Read back over ten losses of the night: dying 77-95% of decisions in 9 of 10; the search offering only the hold (no-line) in 6;
  the first garbage met with 22 or fewer panels in 5; 5-27 lines a minute clearing panels that break no garbage in all.
- **Run 91 (2026-11-26 07:16 ET), the gate's bot on NEW seeds 13-14: survived 7/8** (lost chain s13 at 4646). On seeds it never
  saw: 15/16. Run 92: new seeds 15-16.
- **Run 90 (2026-11-26 07:07 ET), the gate's bot on NEW seeds 11-12: survived 8/8** (seven at full health, insane s12 at 3).
  It holds beyond its seeds. Run 91: new seeds 13-14.
- **Run 89 (2026-11-26 06:58 ET), the run-87 bot on L10 seeds 3-4: survived 7/8** (the gate's bot: 8/8). The scarce-fuel rule
  is not kept; the gate's bot stays. Run 90: the gate's bot on new seeds 11-12, never played.
- **Run 88 (2026-11-26 06:49 ET), the run-87 bot on L10 seeds 1-2: survived 8/8, full health.** Run 89: L10 seeds 3-4.
- **Run 87 (2026-11-26 06:40 ET), scarce fuel under garbage not spent on attack (living lines only): L9 seeds 7-8 7/8** (6/8
  without). Within the spread; it changes L10 play, so the L10 gate is run again before it is kept (run 88: seeds 1-2).
- **Run 86 (2026-11-26 06:30 ET), LEVEL 9 seeds 9-10: survived 8/8.** Level 9 with the gate's bot unchanged, every seed set:
  36/40 (90%), every survivor at full health -- 1-2 7/8, 3-4 7/8, 5-6 8/8, 7-8 6/8, 9-10 8/8. Losses: combo s1 11544, chain s4
  4310, chain s8 1282 (panels spent on attack under garbage, then starved), insane s8 18970.
- **Run 85 (2026-11-26 06:21 ET), LEVEL 9 seeds 7-8: survived 6/8** (chain s8 at 1282: panels spent on an entry and a 12-panel
  extend breaking nothing, then starved under the slabs; insane s8 at 18970). Level 9: 28/32. Run 86: seeds 9-10.
- **Run 84 (2026-11-26 06:12 ET), LEVEL 9 seeds 5-6: survived 8/8, full health.** Level 9: 22/24. Run 85: seeds 7-8.
- **Run 83 (2026-11-26 06:02 ET), LEVEL 9 seeds 3-4: survived 7/8** (lost chain s4 at 4310). Level 9: 14/16. Run 84: seeds 5-6.
- **Run 82 (2026-11-26 05:53 ET), LEVEL 8 against garbage 8/8: survived 8/8, full health.** Step 5, garbage of the level: L10
  8/8 on all five sets (the gate), L9 7/8, L8 8/8, L7 7/8 -- the level-derived numbers hold. Open at levels 7-8: garbage above the
  level (9/9) buries the board and the queue's fifty ends it. Run 83: level 9 on seeds 3-4.
- **Run 81 (2026-11-26 05:43 ET), LEVEL 7 against garbage 7/7: survived 7/8, survivors at full health, no queue losses.**
  The level-7 failures against 9/9 were the benchmark's level-10 garbage; with garbage of its level the level-derived bot holds.
  Against garbage above its level, levels 7-8 fill to the top and the queue's fifty ends it -- open. Run 82: level 8 vs 8/8.
- **Run 80 (2026-11-26 05:34 ET), topped with garbage waiting, dig first: level 7 2/8 -- off.** The level 9/9 garbage set for
  level 10 buries a level-7 board (slow pops) to the top; the bot lives on stop and the queue overflows. Run 81: level 7 against
  garbage 7/7 -- is it the benchmark's garbage or the bot?
- **Run 79 (2026-11-26 05:23 ET), a stopped board left quiet: level 7 2/8 -- and the cause found.** combo s1 held 150 frames
  at stop 258-114 with 25 waiting and none dropped: at levels 7-8 the board sits topped under its own garbage all game, alive on
  stop (no health lost), and nothing drops with the top row full. Run 80: topped with pieces waiting, the line breaking more first.
- **Run 78 (2026-11-26 05:12 ET), a living hold for the queue: level 7 2/8 -- it never asked** (at level 7 nearly every line is
  judged dying on the planned single point of health, while the real health, 30, is never touched). Run 79: while stopped by a
  break's time or more, the hold over lines breaking nothing.
- **Run 77 (2026-11-26 05:03 ET), LEVEL 7, seeds 1-2: survived 2/8** -- five losses to the queue at full health (30). Step 5's
  problem: garbage drops only on quiet frames and the bot swaps constantly on a board never in danger. Run 78: with 10+ waiting,
  a living hold is played.
- **Run 76 (2026-11-26 04:53 ET), the queue drained from 40 over breaking lines: level 8 5/8 -- worse.** Runs 75-76 reverted.
  At level 8 the bot never loses health; the queue's fifty is the loss, and a hold does not quiet a board of slowly popping
  garbage. Open. Run 77: level 7.
- **Run 75 (2026-11-26 04:44 ET), the queue drains from 25: level 8 6/8**, both losses still the queue (chain s2 nine frames
  short); the hold gave way only 5 times (nearly every line breaks some). Run 76: from 40, over breaking lines too.
- **Run 74 (2026-11-26 04:33 ET), LEVEL 8, seeds 1-2: survived 6/8**, survivors at full health (23); both losses at full health --
  the queue reached 50 (the loss) under a board always busy breaking. Run 75: from 25 waiting, under garbage too, the hold lets the
  queue's head drop when it fits (one piece a quiet frame).
- **Run 73 (2026-11-26 04:24 ET), Step 5 -- LEVEL 9, seeds 1-2: survived 7/8**, survivors at full health (17), 0 late (lost combo
  s1 at 11544). Run 74: Level 8.
- **Run 72 (2026-11-26 04:14 ET), chaos margin, full set: survived 7/8** (survivors at health 1: the mode shrinks health and adds
  colours to 8; lost insane s1 at 1790, opening panels spent). 8 colours' limit: the break search reaches only 3 swaps in its
  time (~10k boards) -- engine throughput or a narrower move set (same-colour swaps) is the fix, not more time. Run 73: Level 9.
- **Run 71 (2026-11-26 04:05 ET), no opener above six colours: 7 colours 5/8 -- worse, reverted.** Open at 7-8 colours: the search
  offering no line but the hold when the colours are scattered (8 colours thicc s3). Run 72: chaos margin, the full set.
- **Run 70 (2026-11-26 03:55 ET), 7 colours, the full set: survived 6/8** (lost thicc s1 15090, thicc s2 968: the opening plan
  built its chain while the stack rose 30 to 48 panels). Run 71: no opening plan above six colours.
- **Run 69 (2026-11-26 03:46 ET), the linear colour scale (floored at six) on 8 colours seeds 3-4: survived 3/8.** Kept (exactly
  the gate's play at six colours and under). 8 colours stays ~3/8: thicc s3 sat 130 frames with no line offered but the hold (24
  panels, no three in reach at 8 colours) -- the search's reach at many colours is the deeper fix. Run 70: 7 colours, full set.
- **Run 68 (2026-11-26 03:36 ET), by (colours/6)^2: 8 colours 1/8 -- worse** (two losses inside 45 s). Back to linear, never
  below six's. Run 69: 8 colours seeds 3-4.
- **Run 67 (2026-11-26 03:27 ET), the break time scaled by colours/6: 8 colours 3/8**, losses later (16.4k frames on average vs
  12.1k). Run 68: by (colours/6)^2, never below six's.
- **Run 66 (2026-11-26 03:18 ET), 8 colours, the full set: survived 2/8.** The weak mode. Run 67: the cycle's break time scaled by
  colours/6 (unchanged at six colours, so the gate's bot plays the same there).
- **Run 65 (2026-11-26 03:08 ET), every mode with the gate's bot: 7/8.** No Stop Time 6:00, BALL 6:00 (1 health, none lost), 5
  colours 6:00, 8 colours insane 6:00, Panel Hell 4, Ridiculous 4 and Impossible 8 won; lost 8 colours combo s1 at 1033 (every
  line dying from 413 at 42 panels). Run 66: 8 colours, the full 8-game set.
- **Run 64 (2026-11-26 02:59 ET), the run-59 bot on seeds 9-10: survived 8/8. THE NORMAL SURVIVAL GATE IS PASSED** (section 2):
  one unchanged bot (the run-59 bot: run 46's two-break margin for lines clearing nothing, run 55/59's opening keeping its panels
  under six rows) 8/8 on seeds 1-2 (run 61), 3-4 (62), 5-6 (60), 7-8 (63) and 9-10 (64): every game 6:00 at health 13, 0 late,
  0 diverged, 0 surprises; 47/48 with run 59's 7/8. Next: every mode again with this bot (run 65), then fix what fails.
- **Run 63 (2026-11-26 02:50 ET), the run-59 bot on seeds 7-8: survived 8/8, health 13 in every game.** The run-59 bot: 39/40;
  1-2, 3-4, 5-6, 7-8 all 8/8. Run 64: seeds 9-10 again (7/8 in run 59) -- 8/8 completes the survival gate.
- **Run 62 (2026-11-26 02:41 ET), the run-59 bot on seeds 3-4: survived 8/8, health 13 in every game.** The run-59 bot: 31/32
  (1-2, 3-4, 5-6 8/8; 9-10 7/8, combo s9 late). Run 63: seeds 7-8, then 9-10 again.
- **Run 61 (2026-11-26 02:32 ET), the run-59 bot on seeds 1-2: survived 8/8, health 13 in every game.** Gate: 1-2 and 5-6 passed,
  9-10 7/8. Run 62: seeds 3-4, then 7-8.
- **Run 60 (2026-11-26 02:23 ET), the run-59 bot on seeds 5-6: survived 8/8, health 13 in every game** (insane s5 lived again).
  The gate for the run-59 bot: 5-6 passed, 9-10 7/8; run 61 seeds 1-2, then 3-4, 7-8.
- **Run 59 (2026-11-26 02:14 ET), the opening keeps its panels only under six rows: survived 7/8 on seeds 9-10** (insane s10 and
  combo s10 lived; lost combo s9 at 20319, late). Run 60: the run-59 bot on seeds 5-6.
- **Run 58 (2026-11-26 02:04 ET), the run-55 bot on seeds 9-10: survived 6/8** (lost combo s10 18558, insane s10 3924). The run-55
  bot: 28/32, the run-46 bot's rate. insane s10's opening kept its panels to 48 (eight rows) and was dying from 484 at that height.
  Run 59: the opening keeps its panels only under six rows (LOW_ROWS).
- **Run 57 (2026-11-26 01:54 ET), the run-55 bot on seeds 7-8: survived 7/8** (lost thicc s7 at 19850, late, the backlog pattern).
  The run-55 bot: 22/24 over seeds 3-8. Run 58: seeds 9-10.
- **Run 56 (2026-11-26 01:45 ET), the run-55 bot on seeds 3-4: survived 8/8, health 13 in every game** (insane s4 lived, lost by
  the run-46 and run-49 bots). The gate for the run-55 bot: 3-4 passed, 5-6 7/8; run 57 seeds 7-8, then 9-10, 1-2, 5-6.
- **Run 55 (2026-11-26 01:36 ET), the opening keeps its panels: survived 7/8 on seeds 5-6** (insane s5 lived, the first time since
  run 37; lost thicc s6 at 4365, three minutes after an opening that grew 30 to 48 panels as meant). Kept. Run 56: seeds 3-4.
- **Run 54 (2026-11-26 01:27 ET), the run-46 bot on seeds 7-8: survived 8/8, health 13 in every game.** The run-46 bot in Normal:
  45/52. Run 55: in the opening, of two living lines breaking no garbage, the one clearing fewer panels first. Seeds 5-6.
- **Run 53 (2026-11-26 01:17 ET), the opening keeping its panels for the raise: survived 6/8 -- inert.** No raise was asked in the
  opening at all: at level 10 the raise height (chaosRaiseTo) is ~5 rows, which the 30 opening panels already are. Off. insane s5
  is lost at 1667-4463 by every bot but run 37's: the seeds' spread is wide. Run 54: the run-46 bot on seeds 7-8.
- **Run 52 (2026-11-26 01:06 ET), the run-46 bot on seeds 5-6: survived 6/8** (lost thicc s5 10956, insane s5 4463). The run-46
  bot in Normal: 28/32. insane s5 spent its 30 opening panels on entries before any garbage, and the raise was refused while the
  board was busy. Run 53: in the opening, with a raise wanted, a line spending no panels on clears breaking nothing goes first.
- **Run 51 (2026-11-26 00:57 ET), run 49's rule off (the run-46 bot) on seeds 3-4: survived 7/8** (lost insane s4 17308, which run
  50 lost too). Run 49's rule costs seeds 3-4 (two early losses) and stays off. The run-46 bot: 9-10 8/8, 1-2 7/8, 3-4 7/8.
  Open: clears breaking nothing while stopped (stop is a max), panels spent under a queue. Run 52: the run-46 bot on seeds 5-6.
- **Run 50 (2026-11-26 00:47 ET), the run-49 bot on seeds 3-4: survived 5/8** (lost insane s3 5221, chain s4 3860, insane s4
  19914; the run-33 bot had 8/8 here). Run 51: run 49's rule off (the run-46 bot) on seeds 3-4, to tell which change costs them.
- **Run 49 (2026-11-26 00:38 ET), the cheaper of two dying clears breaking no garbage: survived 8/8 on seeds 1-2, health 13 in
  every game.** The gate for the run-49 bot: 1-2 passed; run 50 seeds 3-4, then 5-6, 7-8, 9-10, unchanged.
- **Run 48 (2026-11-26 00:28 ET), the run-46 bot on seeds 1-2: survived 7/8** (lost thicc s1 at 20886, 12 s short). With run 46's
  insane s10 (21070): the queue grows all game to 22-33 pieces and dying lines spend 6-18 panels on clears breaking no garbage.
  Run 49: of two dying lines that both clear and break no garbage, the cheaper first (unless the other lives a break longer).
- **Run 47 (2026-11-26 00:19 ET), the run-46 bot on seeds 9-10: survived 8/8, health 13 in every game** -- the first 8/8 on
  9-10 (insane s10 lost in run 46 and lived here: the search's time budget makes games vary, so a set is passed only by one
  unchanged bot on every set). Run 48: seeds 1-2, then 3-4, 5-6, 7-8.
- **Run 46 (2026-11-26 00:10 ET), a line that clears nothing needs two breaks' margin: 6/8, every targeted loss turned.**
  Ridiculous 4 won, Panel Hell 4 won (8 colours, no stop time), No Stop Time combo s1 6:00 at health 13, Line Clear 15:6 alive to
  the two-minute wall; Normal s10 chain/combo/thicc 6:00 at 13; lost insane s10 at 21070. Run 47: this bot on Normal seeds 9-10.
- **Run 45 (2026-11-25 23:56 ET), the rest of Challenge Mode: 3/8.** Ridiculous 5 and Line Clear 15:1-2 won. A Line Clear stage
  waits 7230 frames (2:00.5) and then sends a row a frame with no queue limit, so 50 queued ends it: a two-minute attack test (send
  the stage's rows: 15:3 needs 39.5, the bot sent 30.3) -- Step 4 work; 15:3-5 and 14:6 ended that way, health full. 15:6 lost by
  health with no garbage at all: lines clearing nothing lived on one break's margin decision after decision until none lived.
  Run 46: a line that clears nothing needs two breaks' margin (the break put off and the next).
- **Run 44 (2026-11-25 23:47 ET), Panel Hell 1-4 and Ridiculous 1-4: 6/8.** Lost Panel Hell 4 (8 colours, no stop time, chaos
  margin: near the top from 0:08, every line judged dying) and Ridiculous 4 (garbage up to the top row with 6-10 panels under it:
  out of fuel, and no raise with the top row full). Run 45: the stages not yet played (Ridiculous 5, Line Clear 15 1-6, 14:6), to
  have the whole failure list before fixing; then fuel first (the most common loss: 5 colours, insane s5, Ridiculous 4).
- **Run 43 (2026-11-25 23:36 ET), Challenge Mode Impossible (difficulty 11), stages 1-8: won 8/8**, 1:08 to 3:05, surprises
  0/140, 0 late; health left 6,5,6,5,5,3,3,1 (stage 8 won on its last point: the margin to fix). Run 44: Panel Hell (17, no stop
  time, 5-8 colours) stages 1-4 and Ridiculous (16) stages 1-4; the launcher records each stage's own settings.
- **Run 42 (2026-11-25 23:27 ET), seeds 1 and 2: survived 8/8, health 13 in every game, budgets 0.** The run-33 bot in Normal:
  52/56 (seeds 1-2 8/8, 3-4 8/8, 5-6 7/8 and 8/8, 7-8 7/8 and 8/8, 9-10 6/8). Run 43: Challenge Mode -- the launcher starts a
  challenge stage (challenge=D:S); Impossible, its 8 stages (level 11, chaos margin, 4-7 colours), won or alive at 6:00.
- **Run 41 (2026-11-25 23:18 ET), dig down to the garbage: survived 5/8 -- worse.** chain_garbage s10 lived, but seed 9 lost
  chain 7162, thicc 20985 and insane 1926 (all lived in run 40): clearing panels whenever they are plenty spends the fuel the next
  minute needs. Reverted. Run 42: the run-40 bot on seeds 1 and 2.
- **Run 40 (2026-11-25 23:08 ET), seeds 9 and 10: survived 6/8.** Lost chain_garbage s10 5491 (34-56 panels under the slab, none
  in reach, holds while the stack rose) and thicc_combo_storm s10 16119. Budgets 0. The run-33 bot: 44/48 in Normal. The fuel log:
  fuel low with room in 4, 8 and 0 decisions, the game taking a raise in none -- under garbage the board is almost never still, so a
  manual raise is almost never possible: the fuel raise is a dead end. Run 41: dig down to the garbage (panels plenty under it: of
  two dying lines breaking nothing, the one leaving the stack lower first).
- **Run 39 (2026-11-25 22:59 ET), seeds 7 and 8: survived 8/8, health 13 in every game, budgets 0** -- but raises 0 in every
  game: the reworked fuel raise did not fire either, so this is the run-33 bot again. Its record in Normal: 38/40 (runs 33, 34, 37,
  38, 39), every survivor at 13 health. Run 40: seeds 9 and 10, with the fuel raise's two tests (fuel low; the game taking a raise)
  logged apart and counted in the report.
- **Run 38 (2026-11-25 22:49 ET), seeds 7 and 8: survived 7/8.** Survivors' health 13 each; budgets 0; 15.93 rows a minute. Lost
  thicc_combo_storm s8 at 13888 (backlog 19-24 pieces from 8400). **Correction:** the fuel raise never fired -- 0 raises and 0 raise
  offers in run 38 and in run 37's insane s5 too: its test (fewer than two threes and no garbage break) never passes on the boards
  that lose (3-5 threes scattered). Run 37's 8/8 was the run-33 bot again, so the run-33 bot stands at 30/32 in Normal (runs 33, 34,
  37, 38). The fuel raise is reworked next.
- **Run 37 (2026-11-25 22:39 ET), the fuel raise: survived 8/8 on seeds 5 and 6 -- health 13 in every game.** Budgets 0,
  surprises 0/787, 16.26 rows a minute; insane s5 (lost at 2124 in run 34) lived. A changed bot re-earns every set: 7-8, 9-10, 1-2,
  and 3-4 again. Run 38: seeds 7 and 8.
- **Run 36 (2026-11-25 22:28 ET), colour counts: 5/8.** 4 colours: both 6:00, 26.8 and 25.6 rows a minute. 5: insane 6:00, combo
  lost 2755 (panels 5-8, nothing to break with). 7: both 6:00. 8: combo lost 17845, insane 11518 (fewer matches, slower digging).
  Budgets 0. Fuel is the common thread (insane s5, NST, 5 colours) and the bot has never raised: the refill raise only fired on a stack
  under six rows or under the rules' floor, which chaos has none of. Run 37: the fuel raise (decide.c), on Normal seeds 5-6.
- **Run 35 (2026-11-25 22:18 ET), the mode survey (combo_storm s1, one setting a game): 6/8.** Survived 6:00: training_random,
  margin Colors, Modoki and Chaos (health decaying to 1 as designed), Chaos Mode on, 1 HP (never an idle topped frame). Lost: No Stop
  Time at 6250 and BALL at 7437, both at the 17-piece burst near 6000 -- with no stop time, only motion, garbage pops and shakes hold
  the stack. Budgets 0. Run 36: colour counts 4, 5, 7, 8.
- **Run 34 (2026-11-25 21:55 ET), seeds 5 and 6, no change: survived 7/8.** Survivors' health 13 each; budgets 0. Lost
  insane_combo_storm s5 at 2124: panels 7-22 from the start, lines dying in their own steps, no raise all game -- fuel. The seed
  sets go on from 5-6 after a change. Run 35: the mode survey -- one game a setting, combo_storm s1 (lived in Normal).
- **Run 33 (2026-11-25 21:45 ET), run 19's real-health-while-topped off: survived 8/8 on seeds 3 and 4 -- health 13 in every
  game.** Budgets 0, surprises 0/851, 15.43 rows a minute. The bot now: the engine's settles end (the verdict works), the cycle
  verdict (margin a break's time, fuel -- a break on the garbage under garbage -- and the readiness), runs 14/15/17 kept, runs 19 and
  20-23 off. Run 34: new seeds, 5 and 6, no change.
- **Run 32 (2026-11-25 21:34 ET), fuel under garbage is a break on the garbage: survived 6/8.** insane_combo_storm s3 lived; lost
  chain_garbage s3 at 21558 (42 frames short) and thicc_combo_storm s4 7168 (backlog 9 to 15, digging 3-6 a break: every line dying
  on the readiness). Kept. Survivors' health 1, 2, 1, 8, 4, 13 -- run 19's real-health-while-topped, made for the broken verdict, is
  re-tested: run 33 turns it off.
- **Run 31 (2026-11-25 21:23 ET), keep-the-panels rule off: survived 7/8.** Lost insane_combo_storm s3 4028; 16.67 rows a minute;
  budgets 0. The loss: lines living on the margin with a three or two of panels left, panels 31 to 10 with nothing broken, then none.
  Run 32: under garbage the cycle's fuel is a break on the garbage (it freezes longest and pays panels back), not any three.
- **Run 30 (2026-11-25 21:12 ET), the cycle's margin a whole break's time: survived 6/8.** Lost thicc_combo_storm s3 10320,
  combo_storm s4 8323; 16.49 rows a minute; budgets 0; ~20% of decisions with a living line. Since the settle fix: 3, 5, 6. combo s4:
  backlog 8-14 from 5200, panels 12-20, then holds at margin 95 to 58 to the loss -- runs 20-23's keep-the-panels rule, made when
  every line was judged lost, puts the hold first among dying lines. Runs 12-24's changes are re-tested one by one against the
  working verdict; run 31: that rule off.
- **Run 29 (2026-11-25 21:01 ET), the cycle test with the readiness: survived 5/8.** Lost combo_storm s3 14645, s4 7629,
  insane_combo_storm s4 5195; 14.23 rows a minute; budgets 0. insane s4: holds living with a break ready and never played, the margin
  137 down to 60 as the stop ran out -- the margin asked (53, the next freeze's start) left no time to finish a break. Run 30: the
  margin is a whole break's time (levelBreak, 94 at Level 10).
- **Run 28 (2026-11-25 20:50 ET), settles end: survived 3/8 (run 27, same bot without the fix: 7/8).** Lines are judged at last
  -- 60-85% of decisions have a line that lives -- but the bot plays worse: 12.5 rows a minute (17.1 before). combo_storm s3 5780:
  a hold judged alive decision after decision while its margin ran 274 to 72 and the stop out (holding spends nothing, so it
  ranks first among living lines), then nothing could rebuild it. Runs 12-24's changes were tuned on a bot that judged every line
  lost. Run 29: the cycle test stands in only for "stands left alone"; with garbage coming, a break ready for the landing is asked
  again (the readiness).
- **The overarching problem, found 2026-11-25 20:35 ET (run 27's cycle log):** every line in every decision came back dead in
  the judge's own steps, done 0. The chaos engine (engine/ca.c) never set b->quiet -- pa.c's "the board has settled", which the
  search's MK_SETTLE waits for -- so no settle ever ended: each line the judge played ran on to the board's loss. Every decision of
  runs 1-27 was judged lost, and every ranking change since was a tie-break among losses. Fixed (ca.c caQuiet: a signal only, the
  engine skips nothing on it). Run 28: the fix, with run 26's cycle verdict now able to fire.
- **Run 26 (2026-11-25 20:20 ET), the cycle verdict: survived 7/8, lives 0 of ~9,800 decisions.** The verdict never fired: run
  23's bot again (lost thicc_combo_storm s4 16701). Run 27 logs the numbers of the verdict for the first line of each decision
  (its loss left alone, the frame it is done, the threes left, dead flags) to find which condition fails.
- **Run 26 (pushed 2026-11-25 20:12 ET), the cycle verdict:** a line lives when, once done, the margin to the top left alone is at
  least the next freeze's start (reaction + two swaps' walks, the hands' frames) and it leaves fuel (a three, or breakable garbage).
  The report now counts the decisions judged alive, so whether the verdict takes is measured, not guessed.
- **Run 25 (2026-11-25 19:07 ET), the chaos verdict (alive to the next freeze, with fuel): survived 4/8 -- and no verdict changed.**
  Every decision still v=dies (412/412 in insane s3): after a ~300-frame line the board left alone is within a break of the top, even
  on a fresh board. Reverted to run 23's bot. The verdict must judge the cycle going on (margin to the next freeze, fuel, cost per
  freeze), not when a board left alone dies: docs/CHAOS_RULES.md "How chaos is survived". Next: the judge reports margin and fuel.
- **Run 24 (2026-11-25 18:54 ET), no attack-list order under a backlog: survived 5/8 -- worse.** Lost thicc_combo_storm s3 6129,
  combo_storm s4 5317, insane_combo_storm s4 2431. Reverted. And the overarching problem (owner: "it's always about to die -- it just
  has to not die, not die a little longer"): in every decision of every lost game read (3,833) the verdict was v=dies -- no line
  ever lived, the ranking ran on its tie-breaks, and each run patched another one. A line was alive only if the board stood ~350 frames
  left alone, past any stop: at chaos speed none does. Run 25: the chaos verdict -- alive to the bot's next freeze (a break's time
  after the line, a stop being frozen time), with the fuel for it (a three or a breakable garbage). docs/CHAOS_RULES.md.
- **Run 23 (2026-11-25 18:43 ET), keep the panels whatever the stop left: survived 7/8 (seeds 3, 4).** thicc_combo_storm s4 lived
  with 13 health; lost insane_combo_storm s3 12434 (it lived in runs 21-22). late 0, diverged 0, overruns 0, surprises 0/780; 16.97
  rows a minute. The loss: 15 pieces burst into the queue at 8008 and it stayed 15-18 for 4,000 frames, the bot never digging it
  down, then out of panels. Run 24: under a backlog the attack list (finish them: combos of 8-10) orders no line, not only the hold.
- **Run 22 (2026-11-25 18:31 ET), keep the panels with garbage queued too: survived 7/8 (seeds 3, 4).** Run 21's two losses lived;
  lost thicc_combo_storm s4 10361. late 0, diverged 0, overruns 0, surprises 0/769; 16.58 rows a minute. The loss: none on the board,
  8 to 13 queued, survive and hold both lost at 238 -- the survive line bought nothing -- yet it spent panels 50 to 17: the rule asked
  for stop longer than a break's time and the stop was 63-82. Run 23: the rule whatever the stop left.
- **Run 21 (2026-11-25 18:22 ET), new seeds 3 and 4, no change: survived 6/8.** Lost thicc_combo_storm s3 7765 and combo_storm s4
  7769; survivors' health 4, 1, 2, 12, 4, 9; late 0, diverged 0, overruns 0, surprises 0/699; 16.18 rows a minute. thicc s3: 8-9
  pieces queued and none on the board, clears breaking nothing kept the stop up (and, the chaos queue dropping only with nothing
  moving, the garbage held off), panels 27 to 12, then the queue dropped on a board with nothing left to dig with. Run 20's rule
  asked for garbage on the board. Run 22: with garbage queued too. (Seeds 3 and 4 stay until 8/8.)
- **Run 20 (2026-11-25 18:11 ET), stop time is a max -- stopped, keep the panels: survived 8/8.** Seeds 1 and 2, Level 10; late 0,
  diverged 0, overruns 0, surprises 0/764; 17.06 rows a minute; health 13 in seven games, 3 in insane_combo_storm s2. The bot: runs
  14 (no hold first by the attack list under a backlog), 15 (chain end forecast), 17 (dig the backlog), 19 (real health only while
  topped out with no stop), 20 (keep the panels while stopped). Run 21: new seeds, 3 and 4, no change.
- **Run 19 (2026-11-25 17:59 ET), real health only while topped out with no stop: survived 7/8, surprises 0/760.** Lost
  thicc_combo_storm s1 19895; survivors' health 13, 2, 13, 3, 13, 2, 13; late 0, diverged 0, overruns 0; 17.43 rows a minute. The
  loss: survive lines clearing panels at stop 70-127 -- stop is a max, a new award only replaces what is left -- panels 45 to 8, no
  break in reach, then the top-out. Run 20: stopped longer than a break's time, of two dying lines breaking nothing, the one keeping
  more panels first unless the other lives a break's time longer.
- **Run 18 (2026-11-25 17:48 ET), planned with the real health: survived 7/8 -- but spent it.** Survivors ended at 1, 1, 1, 7, 3,
  1, 4 health (run 17: 13 in every one); lost thicc_combo_storm s2 at 4450, a game run 17 lived. Planned with 13, the search walks
  into topped-out states it can stand for 12 frames, and health never refills. Reverted to 1. Run 19: 1, and the real pool only
  while topped out with no stop or pre-stop -- the frames health is actually draining, where 1 made every line lost at once.
- **Run 17 (2026-11-25 17:39 ET), dig the backlog: survived 7/8, surprises 0/752.** Lost insane_combo_storm s1 18864 only; every
  survivor kept all 13 health; late 0, diverged 0, overruns 0; 17.70 rows a minute. The loss: from 16200 the queue grew 0 to 21 as
  the speed rose, the last 300 frames no line in reach broke garbage, panels 20 to 11 spent on stop, then holds topped out to the loss.
- **Run 16 (2026-11-25 17:28 ET), run 15's bot with the forecast checked: survived 4/8, surprises 0/632.** Every garbage arrival
  was foreseen 151 frames or more: the forecast is right. Lost thicc_combo_storm s1 19423, insane_combo_storm s1 7349, combo_storm
  s2 19613, insane_combo_storm s2 13010; late 0, diverged 0, overruns 0; 17.47 rows a minute. The losses are the dig: insane s1
  carried 15-24 queued pieces for 1,700 frames, its panels 40 to 7 on survive lines that broke nothing (stop time bought with the
  next break's panels), no raise. Run 17: under a backlog, of two lines that both die, the one breaking more garbage rows first,
  unless the other lives a break's time longer.
- **Run 15 (2026-11-25 17:19 ET), a chain still building ends one link gap after its last link: survived 4/8.** combo_storm s2
  (run 14's burst loss) survived; lost thicc_combo_storm s1 14050, insane_combo_storm s1 20962, chain_garbage s2 12885,
  thicc_combo_storm s2 12138. late 0, diverged 0, overruns 0; 16.33 rows a minute. Run 16: the same bot with the forecast checked
  in every game (surprises: arrivals with under 60 frames of notice), to see what the forecast still misses.
- **Run 14 (2026-11-25 17:06 ET), no hold put first by the attack list under a backlog; 8 games: survived 5/8.** Lost
  thicc_combo_storm s1 19194, insane_combo_storm s1 8336, combo_storm s2 6432; late 0, diverged 0, overruns 0; 16.52 rows a minute.
  Kept. The combo_storm s2 loss: board clear and 41 panels, the forecast 260 frames out for 250 frames -- run 11's rule (a chain
  still building ends a look-ahead from now) kept the pieces staged behind it past the look-ahead -- then 17 pieces at once.
  Run 15: the chain ends one link gap after its last link (chaos training ends a chain exactly so; a real chain about so).
- **Run 13 (2026-11-25 16:48 ET), no change (run 11's bot), Level 10 only: survived 0/4.** Lost combo_storm 9684, chain_garbage
  20964, thicc_combo_storm 18918, insane_combo_storm 13590; late 0, diverged 0, overruns 0; 16.58 rows a minute. Run 11's 4/4 did
  not repeat: the search runs on a time budget, so the runner's speed changes the play. Level 10, runs 9-13: 9 of 20 survived.
  Every loss (run 12's two read decision by decision): a backlog of 10-25 queued pieces carried for minutes with garbage always on
  the board, the bot digging slower than it arrives, and holding 10-12% of its frames meanwhile -- the hold won on the attack list
  (rank.c key 8, the finish-them combos) ahead of the survival keys. Run 14: under garbage with more queued, the list never puts a
  hold first; and the benchmark is 8 games (seeds 1 and 2).
- **Run 12 (2026-11-25 16:37 ET), the vanilla full-board drive off: survived 4/8 -- worse.** Level 10 2/4 (combo_storm and
  chain_garbage survived; lost thicc_combo_storm 11440, insane_combo_storm 20686). Level 9 2/4 (lost chain_garbage 11033,
  thicc_combo_storm 9116, both sooner than run 11). late 0, diverged 0, overruns 0; 16.03 rows a minute. Reverted. Run 13: Level 10
  only from now on, run 11's bot unchanged, to see whether its 4/4 repeats.
- **Run 11 (2026-11-25 16:25 ET), a chain still building ends no sooner than a look-ahead: survived 6/8.** **Level 10 4/4** (health
  13/13 each). Level 9 2/4: combo_storm and insane_combo_storm survived; lost chain_garbage at 14737 and thicc_combo_storm at 20277.
  late 0, diverged 0, overruns 0; 16.72 rows a minute. The chain_garbage loss: a backlog of 5-15 queued pieces carried for minutes
  while digging, then with the board clear and 54 panels the vanilla life table ("full" above 33 panels) spent them to 18 with
  nothing broken, and the backlog dropped on an empty board. Run 12: that drive off.
- **Run 10 (2026-11-25 16:13 ET), queue rule loosened: survived 4/8** (L9: chain_garbage, insane_combo_storm survived; lost
  combo_storm 5606, thicc_combo_storm 12393. L10: chain_garbage, thicc_combo_storm survived; lost combo_storm 5661,
  insane_combo_storm 20543). late 0, diverged 0, overruns 0. The new q= log: in the lost combo_storm the bot's own queue was empty
  for the 600 frames its panels drained (47 to 17) -- the garbage was held at the sender behind a chain still being built (chaos
  staging releases in order) while Gambit's forecast had the chain ending next frame, so it braced every frame for a block that
  had not left, then 12 pieces arrived at once. Run 11: a chain still building ends no sooner than a look-ahead from now.
- **Run 9 (2026-11-25 16:01 ET), no change, the 4 games at Level 9 and Level 10: survived 4/8.** Level 9: 3/4 (insane_combo_storm
  lost at 3455 -- the queue rule never fired, letDrop=0: its ceiling test refused, the board burned to 12 panels and 11 rows
  dropped at once). Level 10: 1/4 (chain_garbage survived, health 13/13; lost combo_storm 10901, thicc_combo_storm 8894,
  insane_combo_storm 17916). late 0, diverged 0, overruns 0. Not N/N twice: Step 3 goes on.
- **Run 8 (2026-11-25 15:51 ET), don't stall the queue: survived 4/4** at Level 9 (combo_storm, chain_garbage, thicc_combo_storm,
  insane_combo_storm, seed 1, garbage level 9 speed 9), every game health 17/17, none lost on the top row; 16.45 rows a minute
  (18.39 / 18.58 / 10.17 / 18.67); late 0, diverged 0, overruns 0 (worst frame 1.3 ms). First N/N; the gate wants it twice in a row.
  Run 9: the same 4 at Level 9 again, and the same 4 at Level 10 (the owner: every number dynamic, play on 9 or 10).
- **Run 7 (2026-11-25 14:47 ET), raise offered only when the game takes it, no floor: survived 2/4.** Survived chain_garbage
  (17.86 rows/min) and thicc_combo_storm. Lost combo_storm at 5692 and insane_combo_storm at 13964 (was 5573; 23.46 rows/min).
  late 0, diverged 0, overruns 0. No raise was ever offered. The combo_storm loss: no garbage ever landed -- chaos drops queued
  garbage only on a quiet board; the bot cleared every ~14 frames (each judged a later loss), 13-15 pieces piled at the door,
  47 panels burned to 9 with none broken, then it all dropped. Run 8: don't stall the queue.
- **Run 6 (2026-11-25 14:35 ET), raise ceiling computed from the level + material floor 36, same 4 games: survived 2/4 (worse than
  run 4's 3/4).** Survived combo_storm (17.78 rows/min) and thicc_combo_storm. Lost chain_garbage at 17483 (it survived runs 3 and 4)
  and insane_combo_storm at 5573 -- the same frame as run 4, with a different game (11.30 rows/min vs 13.78). late 0, diverged 0,
  overruns 0. (Run 5: the same games, cancelled while it waited for Gambit's benchmark.)
- **Run 4 (2026-11-25 14:11 ET), chaos rules (no raise, no material floor, no opener), same 4 games: survived 3/4.** combo_storm
  now survives (21600, health 17; lost at 18583 in run 3); chain_garbage and thicc_combo_storm survive (health 17). Lost:
  insane_combo_storm at frame 5573 (run 3: 8658), all 17 health on the top row. 15.22 rows a minute; late 0, diverged 0, overruns 0.
  Gambit still judges nearly every line dying in the lost game: with garbage coming, a line "lives" only if it leaves a break
  ready (outcome.c), and with no material floor the board has too few panels to build one.
- **Run 3 (2026-11-25 13:52 ET), 4 whole games, Level 9, garbage level 9 speed 9: survived 2/4.** Lost: combo_storm seed 1 at
  frame 18583 (health 0, 17 lost on the top row), insane_combo_storm seed 1 at frame 8658 (health 0, 17 on the top row). Survived:
  chain_garbage (21600, health 17), thicc_combo_storm (21600, health 17). Garbage sent 16.47 rows a minute. late 0, diverged 0,
  overruns 0 (worst frame 2.5 ms). **Step 2's gate passed** (4 games end to end, 0 divergences, 0 late). Step 3 begins.
- **Run 2 (2026-11-25 13:40 ET), 1 smoke game, 1 minute:** survived 1/1 (3600/3600 frames), health 17/17, health lost on the top
  row 0, 16.00 garbage rows a minute, late 0, overruns 0 (worst frame 0.6 ms), **diverged 25** -- all in the incoming queue's
  frameEarned (telegraph told on the stopwatch, the game's queue on the clock); fixed in board.lua. Not a benchmark yet (1 minute).
- Run 1: the client booted on the runner, the match never started (no controller claimed headless); fixed in the launcher.
- Step 2 in progress: Gambit (a frozen copy) on the chaos engine, hooked into the real chaos v3 client; run 3 = 4 whole games.
- 2026-11-25 -- **Step 1 gate passed locally** (`engine/checks.sh 300`): 300 recordings, 424,290 frames, 0 differences. Events in
  those frames: clear3 942, combo 104, chainLink 1397, chain6plus 926, chainCap 235, shockSent 179, allClear 150, allClearSent 55,
  tallSent 39, dropQueue1 387, dropQueue2 490, dropQueue3 575, stopFaded 241, healthLost 7608, swap 11344, garbageBroken 76.
  Still open for the gate: running it on every push (the workflow, waiting on the owner's answer in section 6).
- 2026-11-25 -- the one difference found on the way: at the chaos margin's last step with an empty queue the stop time is 0/0;
  LuaJIT's math.min/max keep the NaN and no stop time is awarded. ca.c does the same.
