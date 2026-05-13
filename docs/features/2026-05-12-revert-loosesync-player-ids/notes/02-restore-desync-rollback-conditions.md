# Task 02 — Restore Match:shouldSaveRollback and Match:isIrrecoverablyDesynced to upstream

## Files touched
- `common/engine/Match.lua`

## Changes
- `Match:isIrrecoverablyDesynced`: replaced the loose-sync `return false` stub with the
  upstream implementation — iterates `garbageSources`; if any `source.clock + MAX_LAG < target.clock`,
  returns `true` (the lockstep-era abort trigger is back).
- `Match:shouldSaveRollback`: already matched upstream (the loose-sync work hadn't changed
  it) — no edit needed.

## Verification
- `luac5.1 -p common/engine/Match.lua` → OK.
- `MAX_LAG` is a global (same provenance as `GARBAGE_DELAY_LAND_TIME` already used in this
  file) — in scope.
- Not committed.
