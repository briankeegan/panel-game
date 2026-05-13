# Task 12 — GREEN: Room:broadcastInput emits player-numbered input

## Files touched
- `server/Room.lua` — `broadcastInput` now relays `NetworkProtocol.encodeInput(senderNum, input)`
  (JSON `{playerNumber, input}`) to every other player + every spectator. Removed the
  `getInputPrefixForPlayer` lookup and the implicit per-slot prefix message. The
  disconnected/eliminated drop guards still `return` before `game:receiveInput`.
- `server/tests/ServerTests.lua` — `testGameplay` now decodes the relayed input with
  `NetworkProtocol.decodeInput` and also asserts the carried `playerNumber` matches the sender.

## Verification
- `luac5.1 -p server/Room.lua` → OK
- `zsh run_tests.sh`: `TeamRoomTests` GREEN (task 11's `test2v2Room_inputCarriesPlayerNumber`
  passes, incl. the spectator path). `ServerTests` back to its pre-existing failure
  (now line 236, was 234 — shifted by my 2-line edit; not a new regression). Remaining failures:
  `RoomTests:138` (pre-existing), `ServerQueueTests:53 opponentInput` (task 13), `LooseSync*`
  (task 21).
- Not committed.
