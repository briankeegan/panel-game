# Task 13 — Client: route relayed input by playerNumber

## Files touched
- `client/src/network/TcpClient.lua` — `queueMessage`: replaced the `isInputPrefix(type)`
  branch with `type == serverMessageTypes.input.prefix` → `NetworkProtocol.decodeInput(data)`
  → push `{[input.prefix] = {playerNumber, input}}`. `dropOldInputMessages`: detect input
  messages by `message[serverMessageTypes.input.prefix] ~= nil` instead of scanning for any
  input prefix. (`activateDelayedProcessing`/`deactivateDelayedProcessing` untouched.)
- `client/src/network/NetClient.lua` — `processInputMessages` pops only
  `serverMessageTypes.input.prefix`; for each, `match:receiveInput(body.playerNumber, body.input)`.
- `client/src/ClientMatch.lua` — `receiveInput(playerNumber, input)` now keys directly off
  `playerNumber` (`if self.stacks[playerNumber] then ...`); removed the prefix→index lookup and
  the now-unused `NetworkProtocol` require.
- `client/src/server_queue.lua` — `ServerQueue.push` log-suppression collapsed to a single
  `msg[NetworkProtocol.serverMessageTypes.input.prefix]` check.
- `client/tests/RelayedInputRoutingTests.lua` — NEW unit test file (registered in
  `testLauncher.lua`): (1) `TcpClient:queueMessage` decodes a relayed input to `{playerNumber, input}`;
  (2) `ClientMatch:receiveInput(n, payload)` lands the payload on `stacks[n]` only and is a
  no-op for a slot with no stack.

## Verification
- `luac5.1 -p` on all touched .lua files → OK
- `zsh run_tests.sh`: `RelayedInputRoutingTests` GREEN, `ServerQueueTests` GREEN. Remaining
  failures: `RoomTests:138`/`ServerTests:236` (pre-existing), `LooseSyncTests`/`LooseSyncServerTests`
  (task 21). No regressions.
- Not committed.
