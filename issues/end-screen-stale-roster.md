# End-screen stale roster

**Reported:** Mako, 5/26/26 playtest

## Symptom

The post-match "You lose :(" ranking screen lists players who are no longer in the lobby.

## Repro

1. Start an FFA match with N players
2. Have one or more players leave the room before the match ends
3. Observe the end screen — departed players still appear in the ranking

## Evidence

Screenshot shows ranking including `Azyyyyyyyy` and `javi`; Mako confirmed at least one wasn't in the room at the time.

## Notes

- The end-screen roster seems to be sourced from match-creation state rather than current participants
- Look for where the post-match scoreboard pulls its name list — probably `match.players` snapshot vs. live room state
