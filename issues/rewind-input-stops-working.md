# Rewind: input stops working in some cases

**Reported:** Bramp (known) + Wyniverse confirmed, 6/12/26 playtest

## Symptom

After using pause + rewind, input occasionally stops working — the board becomes
unresponsive ("got stuck") in certain cases.

## Repro (suspected)

1. Play solo / vs self
2. Die or miss a move, then pause and rewind
3. Resume — in some cases input no longer registers

## Notes

- Distinct from `endless-rewind-swap-disabled.md` (resolved 5/30, was touch-only:
  lingering touch cursor). This report is general "input stops working," possibly
  controller too — if so, it points somewhere new, not the touch path.
- See [[rewind_swap_disabled_root_cause]]: engine rewind is byte-faithful, so a
  controller-input freeze implies a client-side input-state issue post-resume.
- Need exact repro + input method (touch vs controller) to localize.
