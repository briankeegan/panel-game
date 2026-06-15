-- Verifies the bot applies a human's garbage attack correctly (the
-- human-attacks-bot path that can't be exercised bot-vs-bot since neither
-- heuristic attacks). Run: luajit bot/tests/GarbageApplyTest.lua
require("bot.headlessBoot")
local BotClient = require("bot.BotClient")

local bot = BotClient({ ip = "127.0.0.1", name = "t" })
local applied = {}
bot.myStack = { applyNetworkGarbage = function(_, g, s) applied[#applied + 1] = { g = g, s = s } end }
bot.localPlayerNumber = 1

-- opponent (sender=2) attacks us (recipient 1) -> applied to our stack
bot:dispatch({ ["G"] = { sender = 2, senderFrame = 50, recipients = { 1 }, garbage = { { width = 3, height = 1 } } } })
assert(#applied == 1, "opponent G should apply, got " .. #applied)
assert(applied[1].s == 2, "sender passed through")

-- our OWN garbage relayed back (sender=1=us) -> must NOT re-apply (echo skip)
bot:dispatch({ ["G"] = { sender = 1, senderFrame = 60, recipients = { 1 }, garbage = { { width = 2, height = 1 } } } })
assert(#applied == 1, "self-echo G must not apply, got " .. #applied)

-- G aimed at someone else (recipients={2}) -> not ours
bot:dispatch({ ["G"] = { sender = 2, recipients = { 2 }, garbage = { {} } } })
assert(#applied == 1, "G not targeting us must not apply, got " .. #applied)

print("GarbageApplyTest passed")
