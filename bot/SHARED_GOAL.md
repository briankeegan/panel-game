# SHARED GOAL — three-track alignment charter (bot/A · B · data)

One source of truth for all three Claude tracks building the Panel Attack bot. Each track sets the
**`/goal` condition** below in its own session so its Stop hook won't let it go idle without checking in.

## THE OBJECTIVE (per the LOCKED `bot/BOT_CEILING_FRAMEWORK.md`)
Build ONE **ceiling bot — strictly better than the best human on every axis** (win vs a *killable,
reacting* opponent + offense + survival + ~100% of the 235 puzzles), via a **receding-horizon / MPC
planner**. THEN handicap it *down* (cursor speed, fumble ε, scaled offense) for the easy/med/hard ladder.
Separately, the **human-style clone variety pack** (style-match specific players) — the difficulty/flavor layer.
Never build to human level directly: build the ceiling, pull back.

## THE THREE LANES
- **Track A (live bot, main session):** `SearchBrain` / `BoardSim` / `CursorController`, the MPC planner + eval. Owns the live offense/survival engine + the self-play league.
- **Track B (timing/offense search):** `puzzleSolveTimed` as the MPC reference, event-driven candidate-gen, chain-potential, `chainEnded`/catch-line consumption. New files only.
- **Track DATA:** corpus measurement, the clone fit (`fit_targets`/`compare_profiles`/`fit_player`), the clone + contested scorecards, human benchmarks (`PLAYER_AUDITS.md`), the versioned capture + re-parse (`STATE_CAPTURE_DESIGN.md`).

## THE ALIGNMENT DISCIPLINE (the standing commitment — this is the point)
1. **Check in before going idle.** Scan the shared channels (`BOT_DATA_UPDATES.md`, `BOT_DATA_TIMING_SYNC.md`, `BOT_CEILING_FRAMEWORK.md`) — answer anything addressed to your track promptly. (Watch for BOTH "bot track" and "B track" and "data track" — don't filter one out.)
2. **Post as you go.** What you're doing / what changed / what's blocked — so the others never have to guess. Keeping the other tracks current is part of the job.
3. **Be a teammate, not a silo.** Surface thoughts, ideas, and concerns with the other tracks' approaches — push back when you see a problem; offer connections (e.g. data's clones can be track A's human-style league opponents).
4. **Don't drift.** Before a big move, confirm it fits the LOCKED framework and the other tracks' current state. Time-share the box (don't run heavy engine work while another track is — coordinate in the channel).

## THE `/goal` CONDITION (each track pastes this into its own session)
> Stay aligned with the other two tracks on the ceiling-bot + clones effort (see `bot/SHARED_GOAL.md`).
> Before going idle, check the shared channels (`BOT_DATA_UPDATES.md`, `BOT_DATA_TIMING_SYNC.md`,
> `BOT_CEILING_FRAMEWORK.md`), answer anything directed at MY track, post my status/changes/blockers so the
> others aren't guessing, and surface any concern with their approach. Don't drift from the LOCKED framework.
