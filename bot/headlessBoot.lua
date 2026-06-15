-- Headless bootstrap for the bot client.
--
-- The bot runs the SAME engine + net code the live client runs, just headless:
-- no graphics, no sound, no UI. We reuse the server E2E test's LÖVE stub (it's
-- the project's existing headless `love`: love.math RNG, love.filesystem on real
-- disk, no-op graphics/audio) so we don't invent a second one.
--
-- NOTE on determinism: LoveStub.love.math is an LCG, not LÖVE's real
-- RandomGenerator. That's consistent bot-vs-bot, but facing a REAL client (which
-- uses LÖVE's RNG) needs a bit-exact love-RNG reimplementation — see Phase 3b.

local util = require("common.lib.util") -- defines global table_to_string; provides addToCPath
util.addToCPath("./common/lib/??")

local socket = require("socket")

-- Full headless LÖVE stub. Set before requiring any client/engine module so
-- they all branch on a consistent `love`.
_G.love = require("server.tests.E2E.LoveStub")
-- The bot needs wall-clock timing (request timeouts, aligned start instant),
-- not the stub's os.clock CPU time.
love.timer.getTime = function() return socket.gettime() end

-- `love` is truthy now, so common/lib/utf8Additions takes its require("utf8")
-- branch (LÖVE bundles utf8); headless we alias it to the luarocks luautf8.
package.loaded["utf8"] = require("lua-utf8")

-- Globals the net layer + engine read (normally set by client bootstrap).
json = require("common.lib.dkjson")     -- used by Request/NetworkProtocol/ServerQueue
require("client.src.server_queue")       -- defines global ServerQueue
require("client.src.TimeQueue")          -- defines global TimeQueue
require("client.src.globals")            -- engine constants (GARBAGE_TRANSIT_TIME, LOOSE_SYNC_GARBAGE, ...)

-- Response writes GAME.crashTrace on a coroutine error; give it a home.
GAME = GAME or {}
