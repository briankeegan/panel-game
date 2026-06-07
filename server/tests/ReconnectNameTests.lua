-- Repro tests for the "name already taken after backing out of the lobby"
-- bug (CosmixBro / chaos952 reports on the Sat Cats build).
--
-- Real-world sequence being modeled:
--   1. Player sets a name, enters an online lobby  -> full triple-socket login
--   2. Player backs out (e.g. to configure controls) -> client logout()
--   3. Player re-enters the lobby                  -> login again with same id
--   4. Server rejects: "name already taken" / "Cannot login with the same name twice"
--
-- These are integration-shaped (real Server via ServerTesting), driving the
-- actual Server:login / Server:closeConnection paths through MockConnections.

local logger = require("common.lib.logger")
local ServerTesting = require("server.tests.ServerTesting")
local ClientProtocol = require("common.network.ClientProtocol")
local MockConnection = require("server.tests.MockConnection")
local json = require("common.lib.dkjson")

-- Pull the loginResponse content ({approved=, reason=, newUserId=, ...}) out
-- of a connection's outgoing queue, scanning newest-first. Returns nil if the
-- connection never got a login response.
local function lastLoginResult(conn)
  local q = conn.outgoingMessageQueue
  for i = q.last, q.first, -1 do
    local mi = q[i]
    local content = mi and mi.messageText and mi.messageText.content
    if content and content.approved ~= nil then
      return content
    end
  end
  return nil
end

-- Drive a login on `conn` with the given id/name and return the result content.
local function doLogin(server, conn, userId, name)
  if server.connectionToPlayer[conn] == nil then
    server:addConnection(conn)
  end
  conn:receiveMessage(json.encode(
    ClientProtocol.requestLogin(userId, name, 10, "controller", "pacci",
      nil, nil, nil, nil, true, "with my name").messageText))
  server:update()
  return lastLoginResult(conn)
end

local function doSessionClaim(server, conn, userId, name)
  server:addConnection(conn)
  conn:receiveMessage(json.encode(ClientProtocol.requestSessionClaim(userId, name).messageText))
  server:update()
  return lastLoginResult(conn)
end

-- Full triple-socket login like the real LoginRoutine: gameplay does the real
-- login, lobby + spectate attach via session claim. Returns the three conns.
local function tripleLogin(server, userId, name)
  local gameplay = MockConnection("gameplay")
  local r = doLogin(server, gameplay, userId, name)
  assert(r and r.approved, "gameplay login should succeed for " .. name
    .. " (got: " .. (r and tostring(r.reason) or "no response") .. ")")
  local effectiveId = r.newUserId or userId
  local lobby = MockConnection("lobby")
  assert(select(1, doSessionClaim(server, lobby, effectiveId, name)).approved,
    "lobby session claim should attach")
  local spectate = MockConnection("spectate")
  assert(select(1, doSessionClaim(server, spectate, effectiveId, name)).approved,
    "spectate session claim should attach")
  gameplay.outgoingMessageQueue:clear()
  return gameplay, lobby, spectate, effectiveId
end

-- ===========================================================================
-- Scenario 1: returning user (already in playerbase), backs out, re-enters.
-- Mirrors Cosmix: name persisted client-side, re-login carries the real id.
-- The client logout() sends `logout` on the LOBBY socket, then closes all three.
-- ===========================================================================
local function test_returning_user_relogin_after_lobby_logout()
  logger.info("test_returning_user_relogin_after_lobby_logout")
  local server = ServerTesting.getTestServer()
  local bob = ServerTesting.players[1]  -- userId "1", name "Bob", already in playerbase

  local gameplay, lobby, spectate = tripleLogin(server, bob.userId, bob.name)
  assert(server.nameToPlayer["Bob"], "Bob should be registered after login")

  -- Back out: client sends logout on the LOBBY socket (NetClient:logout ->
  -- _sendLobby(ClientMessages.logout())), then closes all three sockets.
  lobby:receiveMessage(json.encode(ClientProtocol.logout().messageText))
  server:update()
  -- The client then tears down its sockets. Model the realistic race: the
  -- server has processed the lobby logout but NOT yet detected the gameplay
  -- TCP close when the player re-enters and reconnects.

  -- Re-enter the lobby: brand new gameplay socket, same persisted id.
  local gameplay2 = MockConnection("gameplay")
  local result = doLogin(server, gameplay2, bob.userId, bob.name)

  assert(result, "re-login should get a response")
  assert(result.approved,
    "RE-LOGIN DENIED: " .. tostring(result.reason) ..
    " -- backing out of the lobby and re-entering must not lock out the name")
end

-- ===========================================================================
-- Scenario 2: same, but the gameplay + spectate closes ARE processed first
-- (no race). Should always be clean. If THIS fails too, teardown itself is broken.
-- ===========================================================================
local function test_returning_user_relogin_after_full_disconnect()
  logger.info("test_returning_user_relogin_after_full_disconnect")
  local server = ServerTesting.getTestServer()
  local bob = ServerTesting.players[1]

  local gameplay, lobby, spectate = tripleLogin(server, bob.userId, bob.name)

  -- Full clean teardown: logout on lobby, then server detects all three closes.
  lobby:receiveMessage(json.encode(ClientProtocol.logout().messageText))
  server:update()
  server:closeConnection(spectate, "client closed spectate")
  server:closeConnection(gameplay, "client closed gameplay")

  assert(not server.nameToPlayer["Bob"],
    "after full disconnect Bob's name should be released; still present = stale-map bug")

  local gameplay2 = MockConnection("gameplay")
  local result = doLogin(server, gameplay2, bob.userId, bob.name)
  assert(result and result.approved,
    "RE-LOGIN DENIED after clean disconnect: " .. tostring(result and result.reason))
end

-- ===========================================================================
-- Scenario 3: brand-new user (not in playerbase). First login mints an id;
-- on re-entry the client carries that minted id. Models Cosmix's "changed my
-- name a bit" fresh-name attempt.
-- ===========================================================================
local function test_new_user_relogin_with_minted_id()
  logger.info("test_new_user_relogin_with_minted_id")
  local server = ServerTesting.getTestServer()
  local name = "Cosmix"

  local gameplay, lobby, spectate, mintedId = tripleLogin(server, "need a new user id", name)
  assert(mintedId and mintedId ~= "need a new user id", "server should mint a new id")

  lobby:receiveMessage(json.encode(ClientProtocol.logout().messageText))
  server:update()

  -- Re-enter carrying the minted id (what a correctly-persisting client sends).
  local gameplay2 = MockConnection("gameplay")
  local result = doLogin(server, gameplay2, mintedId, name)
  assert(result and result.approved,
    "RE-LOGIN DENIED for new user carrying minted id: " .. tostring(result and result.reason))
end

-- ===========================================================================
-- Scenario 4: new user whose client FAILS to persist the minted id, so on
-- re-entry it sends "need a new user id" again while the name is now in the
-- playerbase. This is the "key was lost" path -> expect the symptom today.
-- ===========================================================================
local function test_new_user_relogin_without_persisted_id()
  logger.info("test_new_user_relogin_without_persisted_id")
  local server = ServerTesting.getTestServer()
  local name = "Cosmix2"

  local gameplay, lobby, spectate = tripleLogin(server, "need a new user id", name)

  lobby:receiveMessage(json.encode(ClientProtocol.logout().messageText))
  server:update()
  server:closeConnection(spectate, "client closed spectate")
  server:closeConnection(gameplay, "client closed gameplay")

  -- Client lost the id -> sends "need a new user id" again.
  local gameplay2 = MockConnection("gameplay")
  local result = doLogin(server, gameplay2, "need a new user id", name)
  logger.info("  scenario 4 result: approved=" .. tostring(result and result.approved)
    .. " reason=" .. tostring(result and result.reason))
end

test_returning_user_relogin_after_lobby_logout()
test_returning_user_relogin_after_full_disconnect()
test_new_user_relogin_with_minted_id()
test_new_user_relogin_without_persisted_id()
logger.info("All ReconnectNameTests passed!")
