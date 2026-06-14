-- Phase 0, step 1 spike: prove a headless bot can connect + log in.
-- Usage: zsh run_bot.sh [ip] [port] [name]
io.stdout:setvbuf("no")
require("bot.headlessBoot")

local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.INFO)

local BotClient = require("bot.BotClient")

local bot = BotClient({
  ip = arg[1] or "127.0.0.1",
  port = tonumber(arg[2]) or 49569,
  name = arg[3] or "BotBella",
})

local ok, err = bot:login()
if ok then
  print("=== BOT LOGIN OK ===")
  os.exit(0)
else
  print("=== BOT LOGIN FAILED: " .. tostring(err) .. " ===")
  os.exit(1)
end
