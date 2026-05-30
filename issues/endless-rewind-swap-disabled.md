# Endless rewind: swap disabled on random cells

**Reported:** Bramp, 5/27/26

## Symptom

After using rewind in Endless mode, swap becomes randomly disabled on specific cells of the board. May be related to "no raise" state persisting incorrectly post-rewind.

## Repro (suspected)

1. Play Endless
2. Pause and rewind
3. Resume — try to swap panels; some cells reject the swap

## Notes

- May be tied to the rewind not fully restoring per-cell swap-eligibility flags
- Possible "no raise" state is leaking into per-cell state during rewind
- See [[feature_endless_rewind]] for the broader rewind feature design

## Resolution (5/30/26)

Root cause was **not** the engine. A diagnostic that replicated the exact
scrub → preview → transplant → `rewindToFrame` path and compared per-cell
`color`/`state`/`dont_swap` against a clean reference simulation found **0
mismatches** — in normal endless, no-raise endless, and a deliberately
flag-divergent case, both at the rewind frame and after forward-simulating
past it. `dont_swap` and panel state are fully captured by `rollbackCopyPanels`
(copies every key) and restored by `internalRollbackToFrame` (`table.clear` +
full overwrite). The engine rewind is byte-faithful.

The real culprit is client-side per-cell state the engine rollback can't touch:
`TouchInputController.lingeringTouchCursor` / `touchTargetColumn`. A failed
touch-swap pins a `(row, col)`; as the board rises `stackIsCreatingNewRow`
bumps that row upward, but a rewind never bumps it back down. After resume the
lingering cursor points at a stale cell and `handleTouch` stays in its locked
branch — swaps "disabled" on that cell until release + re-tap.

**Fix:** `TouchInputController:onRollback()` clears the selection state;
`PlayerStack:onRollback` calls it (fires on the scrub-commit rewind). Regression
test: `client/tests/TouchInputControllerTests.lua`.

Note: this is touch-input only. For controller input there is no client-side
per-cell swap state, and the engine restore is faithful — if the symptom ever
recurs with controller input, it points somewhere new, not at the rollback.
