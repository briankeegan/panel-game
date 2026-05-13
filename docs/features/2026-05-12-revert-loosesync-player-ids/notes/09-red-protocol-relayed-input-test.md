# Task 09 — RED: protocol test for player-numbered relayed input + absence of removed types

## Files touched
- `common/tests/network/NetworkProtocolTests.lua` — replaced the loose-sync G/D/K round-trip
  + registration tests with:
  - a round-trip block: `NetworkProtocol.encodeInput(n, payload)` → `getMessageFromString` →
    `NetworkProtocol.decodeInput(body)` == `(n, payload)`, for n ∈ {1,2,3,8,9,37} (9 and 37 are
    past the old 8-slot prefix alphabet).
  - assertions that `G`/`D`/`K` are not registered prefixes, `garbageEvent`/`deathEvent`/
    `koArbitration` message types are gone, `secondOpponentInput..eighthOpponentInput` are gone,
    and `playerInputPrefixes`/`getInputPrefixForPlayer`/`playerIndexForInputPrefix`/`isInputPrefix`
    are gone.
  - added `require("common.data.KeyDataEncoding")` for a realistic payload sample.

## Design chosen (implemented in task 10)
Relayed input = `serverMessageTypes.input` (prefix `"I"`, variable-length, verbose), body =
`json.encode({playerNumber = n, input = payload})`. Helpers `NetworkProtocol.encodeInput` /
`NetworkProtocol.decodeInput` are the canonical encode/decode points (used by `Room:broadcastInput`,
`TcpClient`, and this test).

## Verification (RED)
- `zsh run_tests.sh` → `NetworkProtocolTests.lua:51: attempt to call field 'encodeInput' (a nil value)`.
  Fails for the right reason (helper + new message type don't exist yet). Other pre-existing/expected
  failures unchanged.
- Not committed.
