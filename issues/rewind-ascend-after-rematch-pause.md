# Rewind: stack "ascends" after rematch + pause

**Reported:** Wyniverse, 6/12/26 playtest (screenshot provided)

## Symptom

After a rematch followed by a pause, using rewind causes the stack to "ascend" —
abnormal stack/board behavior (screenshot shows the board in a broken/ascended
state).

## Repro (suspected)

1. Play a match, then rematch
2. During the rematch, pause
3. Use rewind
4. Stack ascends / enters a broken visual+state

## Notes

- The **rematch → pause → rewind** sequence is the key trigger; the plain rewind
  path works (Wyniverse confirmed rewind itself works in a fresh game).
- Suspect rewind/rollback state isn't fully reset between matches — a rematch may
  leave stale rewind buffers or frame anchors that the next rewind references.
- See [[rewind_swap_disabled_root_cause]] and [[match_teardown]] (end-of-match →
  restart reset sequence) — check the rewind buffer is cleared on rematch.
- Screenshot from Wyniverse (not yet reviewed — attach to issue).
