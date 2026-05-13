# Task 11 — RED: server relay test (3–4 player room)

## Files touched
- `server/tests/MockConnection.lua` — dropped `incomingGarbageQueue`/`incomingDeathQueue`;
  `send()` now only buffers `"I"` (relayed input) and `"J"` (JSON) messages.
- `server/tests/TeamRoomTests.lua` — added `require("common.network.NetworkProtocol")`;
  replaced `test2v2Room_inputPrefixes` (which implicitly asserted the per-slot prefix scheme)
  with `test2v2Room_inputCarriesPlayerNumber`: builds a 2v2 room + a spectator, has player 3
  broadcast input "C", asserts every other player AND the spectator each receive exactly one
  relayed-input message decoding to `(3, "C")` and the sender receives nothing; repeats for
  player 1. Added a `decodeRelayedInput(message)` helper. Updated the bottom-of-file invocation.

## Verification (RED)
- `luac5.1 -p server/tests/TeamRoomTests.lua server/tests/MockConnection.lua` → OK
- `zsh run_tests.sh` → `TeamRoomTests` fails at `server/Room.lua:650: attempt to call field
  'getInputPrefixForPlayer' (a nil value)` — i.e. `broadcastInput` still uses the removed
  prefix helper; rewritten in task 12. (`RoomTests` fails at the same line for the same reason.)
- Not committed.
