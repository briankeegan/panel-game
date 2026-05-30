# Panel pop SFX broken

**Reported:** Tournament Streamer, 5/26/26 playtest

## Symptom

"Panel pop sound effects sound broken as hell" during multiplayer matches.

## Notes

- Needs an audio listen-through to characterize (cutoff, overlap, wrong sample, missing trigger?)
- Possibly tied to the snapshot-rendering change — remote-board pop events may be triggering SFX in batches or at wrong times
- Could also be sample exhaustion / voice limit if many remote pops fire at once
