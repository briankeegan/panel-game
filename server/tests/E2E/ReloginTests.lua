-- E2E repro for the "name already taken after backing out of the lobby" bug
-- (CosmixBro / chaos952). Drives a REAL NetClient (real LoginRoutine + real
-- save round-trip) against a real Server, reproducing the exact user sequence:
--
--   1. New player sets a name, enters the lobby   -> full login, server mints id
--   2. Player backs out (configure controls, etc.) -> NetClient:logout()
--   3. Player re-enters the lobby                  -> login() again
--
-- Reported symptom: step 3 fails with "name already taken". The server is
-- known-good for a returning user that presents its persisted user_id (see
-- ReconnectNameTests), so this test exists to prove whether the CLIENT
-- correctly persists + replays that id across a logout/login cycle.

---@diagnostic disable: invisible, undefined-field, need-check-nil
local Harness = require("server.tests.E2E.Harness")
local TestPlayer = require("server.tests.E2E.TestPlayer")
local logger = require("common.lib.logger")
local socket = require("common.lib.socket")

local function logStep(name)
  logger.info("[E2E Relogin] " .. name)
end

-- Pump the harness + the given players until predicate() or timeout.
local function waitUntil(h, players, predicate, timeout, message)
  local deadline = socket.gettime() + (timeout or 8)
  while socket.gettime() < deadline do
    h:tick()
    for _, p in ipairs(players) do p:update() end
    if predicate() then return true end
    socket.sleep(0.005)
  end
  logger.warn("[E2E Relogin] waitUntil timed out" .. (message and (": " .. message) or ""))
  return false
end

-- Path of the per-server user_id file the client persists, relative to the
-- love save dir. Keyed by server IP, so all players on one harness share it.
local function userIdPath(host)
  return "servers/" .. host .. "/user_id.txt"
end

local function readUserId(host)
  return love.filesystem.read(userIdPath(host))
end

-- Ensure a clean "first login is a brand-new user" by clearing any user_id
-- another scenario's bot may have left for this host.
local function clearUserId(host)
  local saveDir = love.filesystem.getSaveDirectory()
  os.remove(saveDir .. "/" .. userIdPath(host))
end

local function test_relogin_after_logout_keeps_name()
  logStep("test_relogin_after_logout_keeps_name")
  local h = Harness():start()
  local ok, err = pcall(function()
    clearUserId(h.host)
    assert(readUserId(h.host) == nil, "precondition: no stored user_id before first login")

    local p = TestPlayer("Cosmix_" .. string.format("%04x", math.random(0, 0xffff)))

    -- 1. First login (brand-new user). Server mints + returns a user_id.
    p:login(h.host, h.port)
    assert(waitUntil(h, {p}, function() return p:isLoggedIn() end, 8, "first login"),
      "first login should succeed")

    -- Checkpoint: the client must have persisted the minted id to disk.
    local persisted = readUserId(h.host)
    assert(persisted and persisted:match("%S"),
      "after first login the client must persist a user_id to "
        .. userIdPath(h.host) .. " (got: " .. tostring(persisted) .. ")")
    logStep("persisted user_id after first login: " .. tostring(persisted))

    -- 2. Back out of the lobby: the real exitMenu path calls NetClient:logout().
    p:act(function() p.netClient:logout() end)
    assert(waitUntil(h, {p}, function() return not p.netClient:isConnected() end, 4, "logout"),
      "logout should disconnect the client")
    logStep("logged out; stored user_id still on disk: " .. tostring(readUserId(h.host)))

    -- 3. Re-enter the lobby with the SAME client (as a real session would).
    p:login(h.host, h.port)
    local reLoggedIn = waitUntil(h, {p}, function() return p:isLoggedIn() end, 8, "re-login")
    assert(reLoggedIn,
      "RE-LOGIN FAILED after backing out — client did not get back to a logged-in "
        .. "state (NetClient.state=" .. tostring(p.netClient.state) .. "). This is the "
        .. "reported 'name already taken' bug.")

    p:close()
  end)
  h:stop()
  assert(ok, err)
  logStep("PASSED test_relogin_after_logout_keeps_name")
end

-- Variant B: Cosmix's exact second attempt — change the name "a bit", enter,
-- back out, re-enter. A renamed client reuses the same persisted user_id (the
-- file is keyed by server IP, not name), so it sends id + new name.
local function test_relogin_after_name_change()
  logStep("test_relogin_after_name_change")
  local h = Harness():start()
  local ok, err = pcall(function()
    clearUserId(h.host)
    local suffix = string.format("%04x", math.random(0, 0xffff))

    local p1 = TestPlayer("Cos_" .. suffix)
    p1:login(h.host, h.port)
    assert(waitUntil(h, {p1}, function() return p1:isLoggedIn() end, 8, "first login"),
      "first login should succeed")
    assert(readUserId(h.host), "user_id persisted after first login")
    p1:act(function() p1.netClient:logout() end)
    assert(waitUntil(h, {p1}, function() return not p1.netClient:isConnected() end, 4, "logout"))

    -- Re-enter with a slightly different name (same persisted user_id on disk).
    local p2 = TestPlayer("Cos2_" .. suffix)
    p2:login(h.host, h.port)
    assert(waitUntil(h, {p2}, function() return p2:isLoggedIn() end, 8, "re-login renamed"),
      "RE-LOGIN with changed name FAILED (NetClient.state="
        .. tostring(p2.netClient.state) .. ")")
    p2:close()
  end)
  h:stop()
  assert(ok, err)
  logStep("PASSED test_relogin_after_name_change")
end

-- Variant C: the first session never cleanly logs out — its sockets linger
-- server-side (network drop / crash / half-open) when the SAME identity logs
-- in again from a fresh client. Models "my previous session is still ghosting
-- on the server" — the case the server's attach/reconnect path must absorb.
local function test_second_client_same_identity_no_logout()
  logStep("test_second_client_same_identity_no_logout")
  local h = Harness():start()
  local ok, err = pcall(function()
    clearUserId(h.host)
    local name = "Ghost_" .. string.format("%04x", math.random(0, 0xffff))

    local first = TestPlayer(name)
    first:login(h.host, h.port)
    assert(waitUntil(h, {first}, function() return first:isLoggedIn() end, 8, "first login"),
      "first login should succeed")
    assert(readUserId(h.host), "user_id persisted")

    -- A fresh client (same persisted id + name) logs in WITHOUT the first
    -- having logged out. The first's sockets are still attached server-side.
    local second = TestPlayer(name)
    second:login(h.host, h.port)
    local reLoggedIn = waitUntil(h, {first, second},
      function() return second:isLoggedIn() end, 8, "second client login")
    assert(reLoggedIn,
      "SECOND CLIENT with same identity FAILED to log in while first still "
        .. "attached (NetClient.state=" .. tostring(second.netClient.state)
        .. "). This is the 'name already taken' bug.")
    first:close()
    second:close()
  end)
  h:stop()
  assert(ok, err)
  logStep("PASSED test_second_client_same_identity_no_logout")
end

local function runAll()
  test_relogin_after_logout_keeps_name()
  test_relogin_after_name_change()
  test_second_client_same_identity_no_logout()
  logger.info("[E2E Relogin] All ReloginTests passed!")
end

if arg and arg[0] and arg[0]:find("ReloginTests") then
  runAll()
end

return {
  runAll = runAll,
}
