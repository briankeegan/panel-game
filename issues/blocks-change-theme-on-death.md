# Blocks change theme/appearance on death

**Reported:** 6/12/26 playtest

## Symptom

When a player dies, the panels/blocks on the board change their theme (visual
appearance / skin) instead of keeping the theme they had during the match.

## Repro (to confirm)

1. Play a multiplayer match with a non-default panel theme/skin
2. Let a player die
3. Observe their board — panels render with a different (likely default) theme

## Notes

- Suspect the death/game-over draw path falls back to a default panel set instead
  of the player's selected theme — possibly the panel asset reference is dropped
  or the dead-board render uses a different code path that doesn't carry the theme
- Check whether it's the dead player's own board, opponents' view of it, or both
- Confirm whether the theme reverts on death specifically, or on the result screen
