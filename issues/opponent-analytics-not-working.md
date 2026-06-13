# Analytics for other players not working

**Reported:** Dyalon, 6/12/26 playtest

## Symptom

In a multiplayer match, the analytics/stats display for other (non-local) players
is not working — only the local player's analytics appear to update.

## Repro (to confirm)

1. Start a multiplayer match (FFA)
2. Observe the per-player analytics panels for opponents
3. Opponent analytics show nothing / don't update

## Notes

- Needs clarification on which analytics specifically (APM, panels cleared, combo
  counts, etc.) and where they render
- Likely the analytics object is only being populated/ticked for `stacks[1]`
  (local) rather than for all stacks, or remote analytics aren't being synced
- Cross-check against the death-timer / clock work, which had a similar
  "only reads local stack" root cause
