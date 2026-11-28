# Runner CPU rule: skip slow runner models

Applies to every workflow that plays games. Written down Nov 28, 2026.

## The rule, as given

```
RUNNER SKIP BY MODEL -- for every workflow that plays games

Why: a game's result depends on the runner's CPU model. Each decision gets
the same wall-clock time, so a slower model searches less and loses more.
gambit-24, 43 runs (#4799-#4848), losses against what each model's own runs predicted:
  Intel Xeon Platinum 8573C   91 games  ratio 1.73  -> SKIP
  AMD EPYC 7763              289 games  ratio 1.46  -> SKIP
  AMD EPYC 9V74              255 games  ratio 1.33  -> SKIP
  Intel Xeon 6975P-C         986 games  ratio 0.78  -> play
  AMD EPYC 9V45              146 games  ratio 0.56  -> play (the best; do not skip AMD as a vendor)
  any model not named                               -> play

The rule:
1. The first step of every game job reads the model:
     lscpu | sed -n 's/^Model name: *//p' | head -1
   and writes it to the game's cpu.txt (the report reads it).
2. Match on the model NUMBER, case-insensitive: 8573C, 7763, 9V74.
   Never match on a vendor or brand word ("AMD", "EPYC", "Platinum"):
   "Platinum" would also skip the 8370C, which lost 0 of 24.
3. On a match, stop before the game starts: print "skipped runner: <model>"
   to the job summary and exit non-zero. No game is played or counted.
4. Retry: when the run ends, if every failed job is a skipped runner, re-run
   the failed jobs only (POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs).
   A re-run gets a new runner. Repeat until no job is skipped.
5. Cap: on the 4th attempt (github.run_attempt >= 4) the job plays on
   whatever runner it has, so every run finishes all its games.
6. The report lists games and losses by runner model, and flags any game
   played on a skip-list model.

What this costs: about a third of jobs get one retry, a little queue time each.
What it doesn't fix: tests then measure the bot on fast machines; live games
on Actions can still land on a slow model and lose more there.
```

## How the live Ranmaru bot applies it (`.github/workflows/bot-prod-smoke-test.yml`)

The owner's call for the live bot: **use the best, never deploy a bot on a slow model -- no retry cap.**
So the live bot differs from the rule above in step 5.

- `SLOW_CPU_MODELS: 8573C 7763 9V74` (workflow `env`). Matched as whole model numbers, case-insensitive (`grep -qiw`).
- **Runner check (slow CPU models)**: the first step of a live run after its setup status starts. It writes the model to
  `cpu.txt` and the run's notice. A deploy's new bot (`standby`) on a slow model stops there -- nothing built, connected,
  played or counted -- prints `skipped runner: <model>` to the job summary, and writes `bot wrote: <time> skipped` to its
  status (`status/<bot>.txt` on `bot-status`).
- **Retry, no cap**: the deploy's *Ask the old bots to leave* step is already waiting for the new bot. When it reads
  `skipped` and the run has finished, it calls `rerun-failed-jobs` on that run (same run id, new runner), and keeps doing so
  until the bot comes up on a model not on the list. Time spent re-rolling does not count toward its 30-minute wait.
- **The lobby is never left empty meanwhile**: the old bot keeps playing. Its 40-minute "no replacement came" fallback
  checks for a newer live run on the same server still in progress (one re-rolling) and waits for it instead of leaving.
- **Not filtered**: a bot started by hand (`versus-player` without `standby`) and the chaos bot play on any runner.
- **Not done yet**: step 6 (games and losses by runner model on the stats page). Each run records its model in `cpu.txt`
  and its notice; the stats page does not show it yet.

To change the list: edit `SLOW_CPU_MODELS` in the workflow. Model numbers only.
