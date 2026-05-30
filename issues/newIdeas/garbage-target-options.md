# Expand garbage targeting options

**Reported:** Bramp + Mako discussion, 5/26/26

## Idea

Today FFA garbage targeting supports:
- **Broadcast** — every attack goes to every opponent
- **Round-robin** — rotates per-piece across opponents (see [[garbage_shared_mode_granularity]])

Add more targeting modes, including:
- **"Everyone is javi"** — all attacks target one designated player (rule: a player who hasn't played a game in that room yet, so first-time joiners get focused). Currently only chaos952 has experienced this as a one-off.

## Notes

- See [[feature_garbage_mode]] for the existing taunt-button target-selection design
- New modes should be selectable in the room-create menu alongside Broadcast / Round-robin
