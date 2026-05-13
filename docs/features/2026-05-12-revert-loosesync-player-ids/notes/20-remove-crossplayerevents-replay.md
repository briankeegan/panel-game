# Task 20 — Remove crossPlayerEvents from ReplayV3 and the loose-sync playback branches

## Files touched
- `common/data/ReplayV3.lua`
  - `REPLAY_VERSION` 4 → 3 (the V4 bump existed solely for `crossPlayerEvents`).
  - Removed the `CrossPlayerGarbageEvent` / `CrossPlayerDeathEvent` / `CrossPlayerEvents` class
    annotations, the `---@field crossPlayerEvents` line, the `self.crossPlayerEvents = {...}`
    constructor init, the `crossPlayerEvents` `keyorder` entry, and the backfill block in
    `createFromV3Data`.
  - `createFromTable` still accepts `replayVersion == 4` (loads through the V3 path, ignoring the
    now-unused key) — per the spec non-goal "the V3 loader may simply ignore the extra key".
- `common/engine/Match.lua`
  - `createFromReplay` already used only the upstream V3 derive-from-sim path (builds
    `garbageTargets`/`garbageSources` from `replay.garbageFlows`); no V4/`crossPlayerEvents`/
    `DeathEvent` playback branch existed to delete.
  - Reworded the four comments that referenced "DeathEvent" / "loose-sync" (in `createFromReplay`,
    `hasEnded`'s `isDone`, the TEAMS_ACTIVE end check, and the winning-team helper) — the
    underlying mechanic (a dead remote stack stops sending inputs, so its view-stack clock stays
    pinned below `game_over_clock`) is unchanged; the bypass logic stays.

## Verification
- `luac5.1 -p common/data/ReplayV3.lua common/engine/Match.lua` → OK
- `zsh run_tests.sh`: `ReplayTests` / `StackReplayTests` / `StackRollbackReplayTests` GREEN.
  Same pre-existing (`RoomTests:138`, `ServerTests:236`) + task-21 deleted-suite failures.
- Manual save/reload-replay check deferred to task 24.
- Not committed.
