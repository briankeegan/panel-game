# Garbage on dead boards

**Reported:** Mako, 5/26/26 playtest

## Symptom

Dead players' boards (rendered remotely from snapshots) still show garbage panels piled on top of their stack. (WHEN you die... maybe also... for remote? not confirme.d. investgate.)

## Repro

1. Join FFA, start a match
2. Stay alive long enough to see another player die
3. Observe the dead player's board in your view — garbage still stacked

## Notes

- Live screenshot confirms: BowserThe2nd, Mako, and the left-edge board all show red garbage panels above dead stacks
- Likely in the snapshot-render path; the dead-state flag isn't suppressing garbage rendering
- Local player's own board correctly clears when *they* die
