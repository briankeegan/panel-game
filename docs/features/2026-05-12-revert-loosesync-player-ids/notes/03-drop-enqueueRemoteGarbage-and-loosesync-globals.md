# Task 03 — Remove Stack:enqueueRemoteGarbage and the loose-sync globals

## Files touched
- `client/src/globals.lua`

## Changes
- Removed `LOOSE_SYNC_GARBAGE` and `MIN_REACTION_FRAMES` globals (+ their comments).
- `Stack:enqueueRemoteGarbage` — searched the whole tree (`grep -rn enqueueRemoteGarbage`),
  it was never actually implemented (the loose-sync plan proposed it but `applyGarbageEvent`
  delivered via `receiveGarbage` directly). Nothing to remove.
- Bonus cleanup (fork "junk", in scope per the spec's "remove anything not needed"):
  restored upstream `MAX_LAG = 155 + GARBAGE_TELEGRAPH_TIME + GARBAGE_TRANSIT_TIME`,
  dropping the fork's `defaultDesyncTolerance = 230` bump and the `config.max_lag_frames`
  override. Confirmed `max_lag_frames` is referenced nowhere else.

## Verification
- `luac5.1 -p client/src/globals.lua` → OK.
- `grep -rn "enqueueRemoteGarbage|LOOSE_SYNC_GARBAGE|MIN_REACTION_FRAMES"` (non-test) → none.
- Not committed.
