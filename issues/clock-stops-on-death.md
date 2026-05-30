# Clock stops when local player dies

**Reported:** Bramp (self), 5/26/26 playtest

## Symptom

When the local player dies, the main match clock freezes instead of continuing to count up while spectating remaining players.

## Evidence

Screenshot showed clock frozen at 0:17 on the "You lose :(" screen while live opponents were still playing.

## Notes

- Clock should keep running so death-time deltas between players remain meaningful
- May share root cause with the winner-death-timer bug (something about local-tick advance being gated on alive state)

## Resolution (5/30/26)

Root cause: `ClientMatch:drawTimer()` read the displayed time only from
`self.stacks[1]` (the local player). A dead stack stops running, so its
`stopWatch` freezes at the death frame — correct engine behavior, but the
display stalled with it.

Fix: `drawTimer` now takes the max `stopWatch` across all stacks. Dead stacks
freeze at their death time while live stacks keep counting, so the displayed
match clock keeps advancing as long as anyone is alive. (`client/src/ClientMatch.lua`)
