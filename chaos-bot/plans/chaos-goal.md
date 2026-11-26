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
