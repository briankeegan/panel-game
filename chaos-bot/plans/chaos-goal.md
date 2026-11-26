# The chaos bot's goal

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
moves the benchmark to new seeds; it is never rerun on the same ones.

**Step 4 -- attack.** Garbage sent a minute, raised without giving up a single game of Step 3. Every change is checked against
survival first. *Done when:* the owner says the rate is enough, or names a number.

**Step 5 -- the lower levels.** The same benchmark at Levels 9, 8 and 7, with no change to the bot: every number is the level's.

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
