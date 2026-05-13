# Task 19 — Remove connectionTimeoutSeconds/sendRetryLimit; restore upstream timeout/retry

## Files touched
- `server/Connection.lua` — restored upstream's module-local `TIME_OUT = 10` (replacing
  `DEFAULT_TIMEOUT_SECONDS`/`DEFAULT_SEND_RETRY_LIMIT`); removed the `timeoutSeconds` field; the
  constructor sets `self.sendRetryLimit = 5` (as upstream); the inactivity-timeout check uses
  `TIME_OUT` directly again.
- `server/Player.lua` — `addToRoom` / `removeFromRoom` no longer poke
  `connection.timeoutSeconds` / `connection.sendRetryLimit` from `room.gameMode` (matches upstream).
- `client/src/network/TcpClient.lua` — no change needed; its `sendRetryLimit = 5` already matches
  upstream and there's no fork-added timeout knob there.

## Verification
- `luac5.1 -p server/Connection.lua server/Player.lua` → OK; server boots cleanly.
- `zsh run_tests.sh`: unchanged failure set. No regressions.
- Diffed `server/Connection.lua` / `server/Player.lua` against `upstream/beta` for the
  timeout/retry pieces — restored.
- Not committed.
