# Rewind: stack "self-raises" after pause + rewind

**Reported:** Wyniverse, 6/12/26 playtest
**Status:** FIXED — awaiting playtest verification

## Symptom

In endless / vs-self, after pause → rewind (scrub back) → resume, the stack
**raises a row on its own** even though the player isn't holding the raise
button. Originally described as the stack "ascending" after a rematch.

## Root cause

Manual raise is a sticky latch by design: once a raise starts, the engine
finishes a full row even after the button is released, and a raise interrupted
by `rise_lock` stays pending and resumes when the lock clears
(`common/engine/Stack.lua:138-142`, `handleManualRaise` ~1140-1184). The flag is
only ever set by held input (`Stack.lua:746-751`) — there is no clear-on-release.

The pause-scrub rewind faithfully restores that latch from the target-frame
snapshot (`internalRollbackToFrame`, `Stack.lua:496-498`). So if you scrub back
onto a frame where a raise was in progress, on resume the engine completes that
raise with no button held — ~15 frames (one row) of uncommanded rise.

Only surfaces via the scrub path: in solo modes the live engine never saves
rollback (`Match:shouldSaveRollback` returns false with no garbage senders), so
the latch is only ever restored through the scrub preview's forced per-frame
saves + the transplant into the live engine
(`ClientMatch:scrubToFrame` / `_transplantPreviewState` / `Stack:rewindToFrame`).

## Not the cause (investigated and ruled out)

- **"Rematch" / stale buffers between matches** — incidental. Every rematch is a
  fresh `ClientMatch`/engine/scene; nothing carries across. The real trigger is
  rewinding into a raise-in-progress, which is easy to hit in an active game and
  easy to miss in a quick fresh-game check (the "fresh game works" report just
  landed the rewind on an idle frame).
- **Stale `_scrubPreview` reused across rematch** — verified NOT reachable;
  `_scrubPreview` lives only on the per-match ClientMatch instance and starts nil.
- **Render/displacement desync, stale input after truncate, off-by-one clock** —
  refuted; the engine re-sim is deterministic and input truncation is aligned.

Validated by 3 independent code reviews (all CONFIRM the latch mechanism).

## Fix

`client/src/ClientMatch.lua`, in `_transplantPreviewState` (the scrub-commit
path, right after `livStack:rewindToFrame`):

```lua
-- No button is held on scrub commit; drop the restored manual-raise latch
-- so the stack doesn't self-raise on resume.
if livStack.manual_raise ~= nil then
  livStack.manual_raise = false
  livStack.manual_raise_yet = false
end
```

Scoped to interactive scrub-back+resume only (does not touch replay-playback
rewind). If the player is actually holding raise on resume, the next frame
re-reads live input, so manual raise still works.

## How to verify

1. Endless or vs-self.
2. Manually raise the stack (hold raise) so a raise is mid-flight.
3. Pause (Start), rewind (Left) back into/around that raise, resume.
4. Expect: stack stays put on resume — no uncommanded self-raise.

## Related

- `issues/rewind-input-stops-working.md` — sibling rewind report; check whether
  this fix also affects it.
