# Kicked out of level select when another player joins

**Reported:** Dyalon, 6/12/26 playtest

## Symptom

While a player is selecting their level in the character/level select screen, a new
player joining the room kicks the selecting player out — they suddenly find their
cursor "moving around the menus" instead of staying in their selection.

## Repro

1. Start a 3-player FFA
2. P1 (host) + P2 in the room
3. P1 is on the level/character select screen, actively selecting
4. P3 joins
5. P1 (the one selecting) gets kicked out of the selection / loses control

Bramp's shorthand: "3p ffa, p2 joins, p3 joins, kicked."

## Notes

- A late join appears to re-init or reset the select screen for players already in it
- Look at how the select scene handles a roster change mid-selection — likely a full
  rebuild of the select UI on player-join rather than appending the new player
- Confirm whether it's specifically the 3rd joiner (slot count change) or any join
