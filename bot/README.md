# Upstream Panel Attack bot

A headless bot that sits in the lobby of an **upstream** Panel Attack server
(panel-attack/panel-game) and auto-accepts challenges. It is the fork's
weighted-evaluator bot (Beverly/Plamp) with a client rewritten for upstream's
protocol.

## This folder is dropped onto upstream, not merged into it

`bot/` touches nothing outside itself. The `bot-prod-smoke-test.yml` workflow
(on `bramp/multi-player`), with `mode: live` and server
`betaserver.panelattack.com:59569`, fetches
upstream **at run time**, copies this folder in, and runs `bot/plamp.sh`, so
the bot runs the server's engine with no one merging updates. Only this folder
of this branch is used.

Which upstream: the server does not report its build, so the workflow takes
the `upstream_ref` input if given, else the `betaserver-live` tag if someone
moved it on deploy, else the latest `beta`. If the server runs something else,
the login is refused with a version message and `playBot.lua` says to pin
`upstream_ref`.

## How it differs from the fork's bot

- **Lockstep.** Upstream has no garbage/death/display messages. The bot
  simulates both stacks: its own from its inputs, the opponent's from the
  inputs the server relays. Garbage, rollback and game over come out of the
  engine's own `Match:run`. The result is reported as the winner's player
  number (0 for a draw).
- **Keeping pace is a rule.** An input is owed every frame; if one side's
  inputs trail by `MAX_LAG` (~3 s) both clients abort. The brain runs as a
  coroutine with an 8 ms budget per frame and resumes next frame, so an input
  always goes out on time. `playBot.lua` prints the worst drift from the 60 Hz
  schedule after every match (it stays under a frame).
- **Engine tables.** Upstream keeps `COMBO_GARBAGE` / `SCORE_*` local to
  `checkMatches.lua`; `EngineTables.lua` finds them there (or on `Stack`, as
  the fork exports them) and errors if they are gone.
- **Accounts.** Upstream always assigns a new name a random id. The bot saves
  it to `bot/identities/<name>_<host>.txt`, and the workflow commits it back
  here so the name can be reused. Ranked is always off.
- `headlessBoot.lua`, `LoveStub.lua`, `LoveRandom.lua` (a copy of LÖVE's
  RandomGenerator, matched against LÖVE 11.5 on 100,000 draws) and
  `PanelStateCodes.lua` are here so nothing outside `bot/` is needed.

## Checks (run from an upstream checkout with this folder in it)

```sh
luajit bot/tests/boardSimVerify.lua      # 0/941 swaps mismatch the engine
luajit bot/tests/decisionVerify.lua      # 381/400 agree, same as on the fork
luajit bot/tests/panelEvalVerify.lua     # output identical to the fork's
luajit bot/tests/comboPartitionVerify.lua
```
