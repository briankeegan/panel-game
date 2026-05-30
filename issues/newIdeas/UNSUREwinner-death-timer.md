# Winner death timer broken

**Reported:** Tournament Streamer, 5/26/26 playtest

## Symptom

The OUT/death timer for the final survivor (the eventual winner) is wrong. Every other player's death timer displays correctly.

## Notes

- All other OUT timers in the FFA HUD work as expected
- The intentional server-side delay before declaring a winner (needed to compare per-player death times) may be related — possibly the winner's timer isn't being stopped/finalized at the right moment
