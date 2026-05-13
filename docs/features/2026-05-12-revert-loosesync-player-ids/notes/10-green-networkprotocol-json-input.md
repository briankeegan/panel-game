# Task 10 — GREEN: NetworkProtocol — JSON relayed-input message, drop per-slot prefixes, bump version

## Files touched
- `common/network/NetworkProtocol.lua` — rewritten:
  - `clientMessageTypes`: dropped `garbageEvent`, `deathEvent` (kept `playerInput` `"I"` raw).
  - `serverMessageTypes`: dropped `secondOpponentInput`..`eighthOpponentInput`,
    `garbageEvent`, `deathEvent`, `koArbitration`; renamed `opponentInput` → `input`
    (still prefix `"I"`, variable-length, `verbose = true`), body = JSON `{playerNumber, input}`.
  - Removed `playerInputPrefixes`, `inputPrefixSet`, `playerIndexForInputPrefix`,
    `isInputPrefix`, `getInputPrefixForPlayer`.
  - Added `NetworkProtocol.encodeInput(playerNumber, input)` and
    `NetworkProtocol.decodeInput(body)` (require `common.lib.dkjson` at module top).
  - `isMessageTypeVerbose` → true for `ping` prefix or `input` prefix.
  - `NETWORK_VERSION` `"006"` → `"007"` (+ changelog comment).
- `common/tests/network/NetworkProtocolTests.lua` — updated the pre-existing "I and U"
  unicode-split test to use `"I"` twice (no more `"U"` prefix).

## Verification
- `luac5.1 -p common/network/NetworkProtocol.lua` → OK
- `zsh run_tests.sh`: `NetworkProtocolTests` GREEN (task 09's new assertions pass). Remaining
  failures are task 12/13 territory (`server/Room.lua:650 getInputPrefixForPlayer`,
  `client/src/server_queue.lua:53 opponentInput`) plus the pre-existing/expected ones.
- Not committed.
