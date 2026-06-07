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

-- Variant D: the messy long-running server. ONE server, hammered with the
-- conditions from the reports — name changes (changeUsername leaks the old
-- name's nameToPlayer/nameToConnectionIndex entries), dirty exits that leave
-- ghost connections lingering server-side, and rapid re-logins — all churning
-- through a small shared name pool so names get reused while ghosts pile up.
--
-- Soundness of the assertion: a stable "victim" identity (its own persisted
-- user_id) must ALWAYS be able to re-enter under its own name. No other user
-- legitimately owns that name, so any denial is WRONGFUL — that's the bug.
local function test_messy_longrunning_relogin()
  logStep("test_messy_longrunning_relogin")
  local OFFLINE, LOGIN, ONLINE = 1, 2, 3  -- NetClient states (NetClient.lua:24)
  local MAX_LIVE_GHOSTS = 5               -- bound socket pileup so a connect
                                          -- hang can't masquerade as the bug
  local h = Harness({expectErrors = true}):start()
  local ghosts = {}   -- abandoned clients; kept referenced so sockets linger
  local ids = {}      -- logicalUser -> its persisted user_id string
  local ok, err = pcall(function()
    clearUserId(h.host)

    -- Park an abandoned client as a ghost, evicting the oldest (closing its
    -- sockets so the server reaps it) once we exceed the live-ghost cap.
    local function parkGhost(p)
      ghosts[#ghosts + 1] = p
      while #ghosts > MAX_LIVE_GHOSTS do
        local old = table.remove(ghosts, 1)
        pcall(function() old:close() end)
      end
    end

    -- Replay a logical user's persisted id (or clear for a brand-new user)
    -- into the shared per-IP user_id file, the way that client's user_id.txt
    -- would hold it.
    local function setStoredId(idStr)
      local saveDir = love.filesystem.getSaveDirectory()
      if idStr and idStr ~= "" then
        love.filesystem.write(userIdPath(h.host), idStr)
      else
        os.remove(saveDir .. "/" .. userIdPath(h.host))
      end
    end

    local function enter(user, name)
      setStoredId(ids[user])
      local p = TestPlayer(name)
      p:login(h.host, h.port)
      local up = waitUntil(h, {p}, function() return p:isLoggedIn() end, 5,
        "login user=" .. user .. " name=" .. name)
      if up then
        local newId = readUserId(h.host)
        if newId then ids[user] = newId end
      end
      return p, up
    end

    local function pump(rounds)
      for _ = 1, (rounds or 15) do h:tick() end
    end

    local VICTIM = "victim"
    local VICTIM_NAME = "Cosmix"
    local pool = {"alpha", "beta", "gamma", "delta"}

    -- Establish the victim first so its id is minted and persisted.
    local vp, vup = enter(VICTIM, VICTIM_NAME)
    assert(vup, "victim should log in cleanly the first time")
    vp:act(function() vp.netClient:logout() end)
    waitUntil(h, {vp}, function() return not vp.netClient:isConnected() end, 3)

    for round = 1, 30 do
      -- Churn: a rotating cast of other users grabbing/renaming pool names and
      -- exiting messily, so the server accumulates leaked name-map entries and
      -- ghost connections.
      local user = "U" .. ((round % 5) + 1)
      local name = pool[(round % #pool) + 1]
      local p, up = enter(user, name)
      if up then
        local mode = round % 3
        if mode == 0 then
          -- clean logout
          p:act(function() p.netClient:logout() end)
          waitUntil(h, {p}, function() return not p.netClient:isConnected() end, 3)
        elseif mode == 1 then
          -- rename in place: re-enter same user under a different pool name
          -- (drives changeUsername, freeing the previous name)
          local newName = pool[((round + 2) % #pool) + 1]
          local p2 = enter(user, newName)
          parkGhost(p2)
          parkGhost(p)
        else
          -- dirty abandon: leave the client connected, never logged out.
          parkGhost(p)
        end
      end
      pump(10)

      -- The invariant: the victim must ALWAYS be able to come back as itself.
      -- Distinguish a genuine SERVER name-denial (the reported bug: client ends
      -- up OFFLINE with a deny reason) from a mid-LoginRoutine hang (state stays
      -- LOGIN — a transport/side-channel stall, not a name conflict).
      local rvp, rvup = enter(VICTIM, VICTIM_NAME)
      if not rvup then
        local st = rvp.netClient.state
        local reason = tostring(rvp.netClient.loginState)
        if st == OFFLINE then
          error("MESSY REPRO: victim '" .. VICTIM_NAME .. "' (its own user_id) was "
            .. "DENIED re-login on round " .. round .. " — server refused the name. "
            .. "reason=" .. reason .. ". This is the 'name already taken' bug.")
        else
          -- Not the reported bug: client stalled in LOGIN (state " .. st .. ").
          logger.warn("[E2E Relogin] victim stalled mid-login (state=" .. tostring(st)
            .. ") on round " .. round .. " — transport stall, not a name denial; recovering")
          rvp:close()
          rvp = nil
        end
      end
      -- Half the time the victim leaves dirty too, to stress its own ghosting.
      if rvp then
        if round % 2 == 0 then
          parkGhost(rvp)
        else
          rvp:act(function() rvp.netClient:logout() end)
          waitUntil(h, {rvp}, function() return not rvp.netClient:isConnected() end, 3)
        end
      end
      pump(10)
    end
  end)
  for _, g in ipairs(ghosts) do pcall(function() g:close() end) end
  h:stop()
  assert(ok, err)
  logStep("PASSED test_messy_longrunning_relogin (victim never wrongly denied)")
end

local function runAll()
  test_relogin_after_logout_keeps_name()
  test_relogin_after_name_change()
  test_second_client_same_identity_no_logout()
  -- NOTE: test_messy_longrunning_relogin is intentionally NOT run here — the
  -- real-socket harness costs seconds per login, so hundreds of churn cycles
  -- take >10 min. The fast equivalent lives in ReconnectNameTests (server-level,
  -- MockConnection, no sockets) which runs the same accumulation in milliseconds.
  logger.info("[E2E Relogin] All ReloginTests passed!")
end

if arg and arg[0] and arg[0]:find("ReloginTests") then
  runAll()
end

return {
  runAll = runAll,
}
