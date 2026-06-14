-- Headless bootstrap for the bot client.
--
-- Loads the minimal globals the *reusable* client network layer expects
-- (TcpClient / Request / Response / ServerQueue), WITHOUT pulling in LÖVE,
-- graphics, audio, scenes, or NetClient. The engine + this net layer are
-- otherwise pure Lua and run under plain luajit, exactly like the server does.
--
-- Anything the net layer touches that is normally provided by the client's
-- LÖVE bootstrap is shimmed here, and nowhere else.

local util = require("common.lib.util") -- defines global table_to_string; provides addToCPath
util.addToCPath("./common/lib/??")

-- NOTE: we deliberately do NOT define a global `love`. logger/TcpClient/Response
-- branch on `love` and take a proper headless path when it's absent (the two
-- love.timer.getTime callsites were made love-optional). Faking a partial love
-- makes logger reach for love.filesystem and crash.

-- Globals the net layer reads (normally set by client/src/config.lua etc.)
json = require("common.lib.dkjson")     -- used by Request/NetworkProtocol/ServerQueue
require("client.src.server_queue")       -- defines global ServerQueue
require("client.src.TimeQueue")          -- defines global TimeQueue

-- Response writes GAME.crashTrace on a coroutine error; give it a home so an
-- error surfaces as an error rather than a nil-index masking it.
GAME = GAME or {}
