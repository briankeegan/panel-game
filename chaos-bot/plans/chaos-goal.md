# The chaos bot's goal

**The target: a bot that survives every game of the chaos benchmark to the end -- 6 minutes (21,600 frames) at chaos Level 9 --
twice in a row, with 0 divergences, 0 late moves and 0 frames over the think budget. Then as much garbage sent as survival allows.
Then Level 10.**

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
2. **Games run on GitHub Actions only**, never in the sandbox -- the sandbox times nothing like a runner.
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
- Each game is chaos Level 9, ends at frame 21,600 or at the loss, and its job uploads the game's log.
- **The report prints, every run, as data:** survived x/N; each loss's frame and pattern; health left at the end of each game and
  the health lost to garbage on the top row; garbage sent a minute; the budgets (frames over the think budget, late moves,
  divergences between the board the bot predicted and the one the game made); and the time the run finished, in ET on the 24-hour clock.
- **One run per change, judged on whether its deaths go away.** The bot must survive whatever the seed or the runner's timing:
  never run the same change twice to average out noise, never call a loss "noise".

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
N/N survived, twice in a row, budgets at 0.

**Step 4 -- attack.** Garbage sent a minute, raised without giving up a single game of Step 3. Every change is checked against
survival first. *Done when:* the owner says the rate is enough, or names a number.

**Step 5 -- Level 10.** The same benchmark at chaos Level 10, Steps 3 and 4 again.

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
