# Tests to Write

Notes from the audit/cleanup. These tests are missing — many were "deleted" but had no real test code behind them (just print-based analysis scripts). Real assertions against the server/engine code still need to be written.

## Multi-slot invite system

The 10 deleted `server/tests/*.lua` files (EdgeCaseAnalysis*, EdgeCases*, FinalSummary, Phase3Summary, SafetyChecksTest, MultiSlotInviteTest, MultiSlotPreservationTest, OutOfOrderSlotBug) were print scripts describing scenarios — not real tests. The functionality they enumerated is real and untested.

Consolidate into one file (e.g. `server/tests/MultiSlotInviteTests.lua`) using the `ServerTesting` harness, asserting against the real `server.lua` proposal/invite code. Scenarios to cover:

- `clearProposals(P)` removes only P's proposals, not unrelated proposals to/from other players when P joins a slot
- Multi-slot invite preservation: P2 requests slot 2, P3 requests slot 3 — P2 joining must not clear P3's pending request
- Out-of-order slot joining: 4-slot room, P2/P3/P4 request slots; any joining order must not invalidate the remaining proposals
- Withdrawal flow: withdraw after mutual acceptance but before slot is filled — state reverts cleanly
- Concurrency: `clearProposals` called during proposal iteration (table-mutation-during-traversal safety)
- Disconnect cleanup: P requesting a slot then disconnecting clears their pending proposals (`Connection:close` → `clearProposals`)
- `handleJoinRoom` safety checks: rejects joining `playing` rooms, full rooms, mismatched slot indices

## Regression tests for deleted investigation docs

Deleted docs described bugs that were fixed. Some have regression tests already (`WrongDrawRegressionTest`, `BadconchReplayTest`, `CrashReplayRegressionTests`); verify the rest are also covered or add:

- **3p FFA stuck match** (was `INVESTIGATION_3PFFA_STUCK_MATCH.md`) — should have a `LooseSyncTests` or `E2E` scenario that asserts a 3-player FFA reaches `gameResult` after one player dies mid-match. Confirm `LooseSyncServerTests` covers this; if not, add.
- **4-player desync** (was `DESYNC_FIX_PLAN.md`) — assert that under high input throughput, 4 clients produce identical `state_vector` hashes through end of match. May already be in `LooseSyncContractTests`.
- **Trace-replay shape parity** (was `TRACE_REPLAY_SHAPE_FIX_PLAN.md`) — assert server-side trace capture records the same message shape clients send on the wire. May already be in `TraceDiffTests` / E2E `TraceReplayTests`; verify.
- **Fragility — `Match:hasEnded` foot-gun** (was `FRAGILITY_FIX_PLAN.md`) — assert `Match:evaluateEndConditions()` is pure (no mutations). Add a small unit test that calls it twice in a row and verifies no state on `self` changed.

## Catch-up & end-of-match playout

Recently added (this session) and worth pinning with tests:

- **Dead view-stack drains after `self.ended`** — `ClientMatch:runGameOver` now calls `self.engine:run()`. Assert that a view-stack with `clock < game_over_clock` continues to consume queued inputs after match-end and reaches `game_over_clock` for the death animation.
- **`_smoothedRateAccum` reset on pendingDeath** — assert no carry-over fractional frame from pre-death smoothing into the post-death max-rate catch-up.

## Lower-priority

- `Stack:shouldRun` catch-up under input lag (multi-frame-per-tick when buffer ≥ threshold) — referenced as a follow-up in the deleted `PRE_EXISTING_TEST_AUDIT.md`. Not loose-sync-specific; was the `liveDesync1` test's original concern.
- `TcpClient` integration test (`client.tests.TcpClientTests`) is disabled in `testLauncher.lua` — needs a real server on localhost. Gate behind an env var so it can run optionally without breaking the default suite.
