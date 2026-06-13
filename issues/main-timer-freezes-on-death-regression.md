# Main timer freezes when you die (possible regression)

**Reported:** Dyalon, 6/12/26 playtest (screenshot provided)

## Symptom

After the local player dies, the middle / main match timer freezes instead of
continuing to count up while other players are still alive. The player's own timer
should mark/stop at their death time, but the main timer should keep going.

## Notes

- This looks like a **regression** of `clock-stops-on-death.md`, which was fixed
  5/30/26 by having `ClientMatch:drawTimer()` take the max `stopWatch` across all
  stacks. Re-verify that fix is still in place and effective in multiplayer FFA.
- See also [[clock_time_domains]] — engine.clock includes countdown; stopWatch does
  not. Make sure the "main timer" being read here is the all-stacks max, not the
  local stack's frozen `stopWatch`.
- Screenshot from Dyalon shows the frozen timer (not yet reviewed — attach to issue).

## Resolution (6/13/26)

Confirmed regression. The 5/30 fix (`drawTimer` max `stopWatch` across stacks) was
still present but **neutralized by the snapshot/spectate-view refactor**.

Root cause: under the snapshot pipeline (MP FFA), `pauseNonLocalSimulation` makes
remote stacks skip `Stack:run()` (`Match:shouldRun`, `common/engine/Match.lua`), so
their `stopWatch` never advances — and the snapshot payload carries `clock` but not
`stopWatch`. The only live-advancing `stopWatch` was the local stack's, which freezes
on death (`stopWatchIsRunning` → false). So `max(stopWatch)` froze at local death.

Fix: `ClientMatch:drawTimer()` now derives each stack's gameplay time from `clock`
instead of `stopWatch`: `max(0, engine.clock - countdownOffsetFrames)`. `clock`
advances unconditionally (`Stack:run`, `Stack.lua:933`) and IS mirrored onto remote
view stacks from snapshots (`DisplayClientStack.lua:246`), so the max stays live while
anyone is alive. The expression is the exact derivation `Stack:recordDeath` uses
(`Stack.lua:1346`); `countdownOffsetFrames` is set on every stack by `Match:start`.
For live stacks `clock - countdownOffsetFrames == stopWatch` exactly, so single-stack
modes are byte-identical (PuzzleGame overrides drawTimer, so the firstInput/firstSwap
offset divergence never displays). Validated by 3 independent agents.
