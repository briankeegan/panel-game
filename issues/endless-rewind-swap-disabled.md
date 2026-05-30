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
