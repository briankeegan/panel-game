# Task 15 — Ensure the targeting ruleset (incl. RNG seed) is in room/match setup

## Result: already covered upstream — no change needed
A client needs three things to reproduce targeting deterministically; all are delivered once at
match start via `ServerProtocol.startMatch(roomNumber, replay)` where `replay = game:getPartialReplay(false)`:

1. **Targeting mode (broadcast vs round-robin):** `garbageMode` ("all" / "shared") is a field of the
   `GameMode` preset (`common/data/GameModes.lua`). The match start replay carries
   `metadata.gameModeName`; the client resolves `GameModes.getPreset(GameModes.nameToGameModeId[name])`
   and reads `garbageMode` (and `stackInteraction`) from it — same preset table on both sides.
2. **Team layout / player→team map:** `Game.createFromRoomState` builds `replay.garbageFlows`
   (`{source, recipients}` per stack) from `room.teams` / `stackInteraction` and ships it in the replay;
   `ClientMatch.createFromReplay` reconstructs `garbageTargets` from it and (for team modes) rebuilds
   `teams` via `TeamUtils.createTeams(#players, teamCount, playersPerTeam)` — deterministic from the
   preset.
3. **RNG seed:** `Game.seed = math.random(...)` (server) is written to `replay.panelSource.seed` and
   sent in the match start replay; the client's engine seeds panel generation from it. (Garbage
   *targeting* itself is fully deterministic from the flows + living-stack state and doesn't consume
   the RNG, but the seed is present regardless.)

`roomRequest → roomCreate` (the lobby exchange) only needs the gameMode id — it doesn't need to carry
targeting details because the authoritative match config is the match-start replay above.

## Verification
- No code change. Test state unchanged from task 13/14.
- Manual N-player target-agreement check deferred to task 24's e2e pass.
- Not committed.
