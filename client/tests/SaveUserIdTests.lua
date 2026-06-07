-- Regression test for the "name already taken after backing out of the lobby"
-- bug (CosmixBro / chaos952). Root cause, confirmed from the live server logs:
-- on re-login the client sends user_id "need a new user id" (deny reason
-- "Player tried to create a new user with an already taken name"), i.e. it
-- fails to read back the user_id it persisted on first login.
--
-- The game runs on love 12 (README: "uses CI builds of love 12.0 to run"),
-- whose love.filesystem does not see files written AFTER the client launched
-- (the same staleness FileUtils.readJsonFileFresh already dodges for replays).
-- user_id.txt is written on first login (after launch), so love.filesystem.read
-- returns nil on re-login -> "need a new user id" -> server rejects the name.
--
-- We can't run love 12 here (dev box is 11.5), so the BUG test SIMULATES the
-- quirk: place the id on disk (what a real client's first-login write produces)
-- and stub love.filesystem.read to return nil for it (the stale love-12 view).
-- A passing fix must recover the id via an io read of the real save-dir path.

local save = require("client.src.save")

local function uidRel(serverIP)
  return "servers/" .. serverIP .. "/user_id.txt"
end

local function placeUserIdOnDisk(serverIP, id)
  local saveDir = love.filesystem.getSaveDirectory()
  os.execute("mkdir -p '" .. saveDir .. "/servers/" .. serverIP .. "'")
  local f = assert(io.open(saveDir .. "/" .. uidRel(serverIP), "w"))
  f:write(id)
  f:close()
  return saveDir
end

-- CONTROL: a server with no stored id reads back nil. This holds both before
-- and after the fix — it proves the fix is targeted (not a blanket pass) and
-- that read_user_id_file still returns nil (not "" or garbage) when truly absent.
local function test_missing_id_returns_nil()
  local got = save.read_user_id_file("test_uid_absent_zzz")
  assert(got == nil, "expected nil for a server with no stored id, got '" .. tostring(got) .. "'")
end

-- BUG: love 12's love.filesystem.read can't see the post-launch write. With the
-- old love.filesystem-only read this returns nil; only an io read recovers it.
local function test_read_recovers_id_invisible_to_love_filesystem()
  local serverIP, id = "test_uid_stale", "2809615061"  -- CosmixBro's real server id
  local saveDir = placeUserIdOnDisk(serverIP, id)

  local realRead = love.filesystem.read
  love.filesystem.read = function(path)
    if type(path) == "string" and path:find(serverIP, 1, true) then
      return nil  -- love 12: stale view, file invisible to love.filesystem
    end
    return realRead(path)
  end

  local ok, result = pcall(save.read_user_id_file, serverIP)

  love.filesystem.read = realRead
  os.remove(saveDir .. "/" .. uidRel(serverIP))

  assert(ok, "read_user_id_file errored under stale love.filesystem.read: " .. tostring(result))
  assert(result == id,
    "read_user_id_file returned '" .. tostring(result) .. "' but the persisted id '" .. id
      .. "' is on disk — love 12 stale-read not handled, so the client sends 'need a new "
      .. "user id' on re-login and the server rejects the already-taken name")
end

test_missing_id_returns_nil()
test_read_recovers_id_invisible_to_love_filesystem()
print("SaveUserIdTests passed!")
