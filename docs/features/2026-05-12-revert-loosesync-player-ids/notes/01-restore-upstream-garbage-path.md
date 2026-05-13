# Task 01 — Restore upstream garbage path in Match:pushGarbageTo / distributeGarbageToTargets

## Files touched
- `common/engine/Match.lua`

## Changes
- `Match:pushGarbageTo`: removed the loose-sync `readyClock` split (`self.fromReplay` /
  `st.stopWatch >= oldestTransitTime`) and the `self:deliverOutgoingGarbage(...)` call.
  Restored upstream's behavior: if the recipient ran past `oldestTransitTime`,
  `rollbackToStopWatch` (desync-abort fallback if rollback fails); then
  `stack:receiveGarbage(st:getReadyGarbageAt(stack.stopWatch))`. Kept the
  multi-target-sender skip (team-mode round-robin is distributed by
  `distributeGarbageToTargets`).
- `Match:distributeGarbageToTargets`: kept the team/round-robin selection logic; replaced
  the `deliverOutgoingGarbage` / `deliverOutgoingGarbageToMultiple` calls with the new
  `Match:deliverGarbageToRecipient`. "All" mode now loops over living targets and pushes a
  per-target garbage copy directly (no batched G event).
- Deleted `Match:deliverOutgoingGarbage` and `Match:deliverOutgoingGarbageToMultiple`
  (they only existed to route through loose-sync G events).
- Added `Match:deliverGarbageToRecipient(recipient, transitTime, garbageDelivery)` — mirrors
  `pushGarbageTo`'s rollback-on-overshoot + `receiveGarbage`.

## Decisions / open notes
- The branch's `distributeGarbageToTargets` is the team-mode multi-target / round-robin
  feature (added alongside loose-sync) and is being kept per the spec — it's not in
  upstream, so "restore upstream" there meant "strip the loose-sync detour", not "delete".
- `distributeGarbageToTargets` still gates the *pull* on `sender.stopWatch >= oldestTransitTime`
  and shares one `getReadyGarbageAt(oldestTransitTime)` pull across all targets. A target
  that's *behind* `oldestTransitTime` still receives (lands a touch late on its own clock)
  rather than waiting — same as the pre-loose-sync behavior. Per-recipient overshoot is now
  handled (rollback). Flag for the manual e2e in task 24: watch round-robin / "all" garbage
  timing under lag in 3–4p.
- `self.fromReplay` field is left in place (still set in `createFromReplay`); only its use in
  `pushGarbageTo` was removed. Task 20 handles the rest of `createFromReplay`.

## Verification
- `luac5.1 -p common/engine/Match.lua` → OK; `luajit -e "assert(loadfile(...))"` → OK.
- `grep deliverOutgoingGarbage` → no remaining references.
- Full `zsh run_tests.sh` not run yet — `LooseSyncTests.lua` and `LOOSE_SYNC_GARBAGE` are
  still present and will fail until later tasks (21 / 03); full suites are run at phase
  boundaries and in task 24, per the plan's "networked breakage expected until later tasks".
- Not committed (per skill).
