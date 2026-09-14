local lfs = require("lfs")
local logger = require("common.lib.logger")
local csvfile = require("server.simplecsv")

local sep = package.config:sub(1, 1) --determines os directory separator (i.e. "/" or "\")

local FileIO = {}

function FileIO.makeDirectory(path)
  local status, error = pcall(
    function()
      lfs.mkdir(path)
    end
  )
  if not status then
    logger.error("Failed to make directory: " .. path .. " error: " .. error)
  end
end

function FileIO.makeDirectoryRecursive(path)
  local sep, pStr = package.config:sub(1, 1), ""
  for dir in path:gmatch("[^" .. sep .. "]+") do
    pStr = pStr .. dir .. sep
    FileIO.makeDirectory(pStr)
  end
end

function FileIO.fileExists(name)
  local f=io.open(name,"r")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

function FileIO.writeAsJson(data, filePath)
  local status, error = pcall(
    function()
      local f = assert(io.open(filePath, "w"))
      io.output(f)
      io.write(json.encode(data))
      io.close(f)
    end
  )
  if not status then
    logger.error("Failed to write file " .. filePath .. " with error: " .. error)
  end
end

function FileIO.readJson(filename)
  local success, json =
  pcall(
    function()
      local f = io.open(filename, "r")
      if f then
        io.input(f)
        local data = io.read("*all")
        io.close(f)
        return json.decode(data)
      end
    end
  )

  return json
end


function FileIO.logGameResult(player1ID, player2ID, player1Won, rankedValue)
  local status, error = pcall(
    function()
      local f = assert(io.open("GameResults.csv", "a"))
      io.output(f)
      io.write(player1ID .. "," .. player2ID .. "," .. player1Won .. "," .. rankedValue .. "," .. os.time() .. "\n")
      io.close(f)
    end
  )
  if not status then
    logger.error("Failed to log game result: " .. error)
  end
end

function FileIO.write_error_report(error_report_json)
  local json_string = json.encode(error_report_json)
  if json_string:len() >= 5000 --[[5kB]] then
    return false
  end
  local sep = package.config:sub(1, 1)
  local now = os.date("*t", to_UTC(os.time()))
  local filename = "v" .. (error_report_json.engine_version or "000") .. "-" .. string.format("%04d-%02d-%02d-%02d-%02d-%02d", now.year, now.month, now.day, now.hour, now.min, now.sec) .. "_" .. (error_report_json.name or "Unknown") .. "-ErrorReport.json"
  return pcall(
    function()
      FileIO.makeDirectoryRecursive("." .. sep .. "reports")
      local f = assert(io.open("reports" .. sep .. filename, "w"))
      io.output(f)
      io.write(json_string)
      io.close(f)
    end
  )
end

---@param leaderboard Leaderboard
function FileIO.write_leaderboard_file(leaderboard, path)
  local leaderboard_table, public_leaderboard_table = leaderboard:toSheetData()

  local status, error = pcall(
    function()
      csvfile.write("." .. sep .. path, leaderboard_table)
      FileIO.makeDirectoryRecursive("." .. sep .. "ftp")
      csvfile.write("." .. sep .. "ftp" .. sep .. "PA_public_" .. path, public_leaderboard_table)
    end
  )
  if not status then
    logger.error("Failed to write leaderboard file with error: " .. error)
  end
end

function FileIO.readCsvFile(filePath)
  if FileIO.fileExists(filePath) == false then
    return nil
  end
  local csv_table = {}
  local status, error = pcall(
    function()
      csv_table = csvfile.read("." .. sep .. filePath)
    end
  )

  if not status then
    logger.error("Failed reading file " .. filePath .. " with the csv reader:\n" .. tostring(error))
    return nil, error
  else
    return csv_table
  end
end

function FileIO.read_user_placement_match_file(user_id)
  return pcall(
    function()
      local sep = package.config:sub(1, 1)
      local csv_table = csvfile.read("./placement_matches/incomplete/" .. user_id .. ".csv")
      if not csv_table or #csv_table < 2 then
        logger.debug("csv_table from read_user_placement_match_file was nil or <2 length")
        return nil
      else
        logger.debug("csv_table from read_user_placement_match_file :")
        logger.debug(json.encode(csv_table))
      end
      local ret = {}
      for row = 2, #csv_table do
        csv_table[row][1] = tostring(csv_table[row][1]) --change the op_user_id to a string
        ret[#ret + 1] = {}
        for col = 1, #csv_table[1] do
          --Note csv_table[row][1] will be the player's user_id
          --csv_table[1][col] will be a property name such as "rating"
          if csv_table[row][col] == "" then
            csv_table[row][col] = nil
          end
          --player with this user_id gets this property equal to the csv_table cell's value
          if csv_table[1][col] == "op_name" then
            ret[#ret][csv_table[1][col]] = tostring(csv_table[row][col])
          elseif csv_table[1][col] == "op_rating" then
            ret[#ret][csv_table[1][col]] = tonumber(csv_table[row][col])
          elseif csv_table[1][col] == "op_user_id" then
            ret[#ret][csv_table[1][col]] = tostring(csv_table[row][col])
          elseif csv_table[1][col] == "outcome" then
            ret[#ret][csv_table[1][col]] = tonumber(csv_table[row][col])
          else
            ret[#ret][csv_table[1][col]] = csv_table[row][col]
          end
        end
      end
      logger.debug("read_user_placement_match_file ret: ")
      logger.debug(tostring(ret))
      logger.debug(json.encode(ret))
      return ret
    end
  )
end

function FileIO.move_user_placement_file_to_complete(user_id)
  local status, error = pcall(
    function()
      local sep = package.config:sub(1, 1)
      FileIO.makeDirectoryRecursive("./placement_matches/complete")
      local moved, err = os.rename("./placement_matches/incomplete/" .. user_id .. ".csv", "./placement_matches/complete/" .. user_id .. ".csv")
    end
  )
  if not status then
    logger.error("Failed to move user placement file to complete: " .. error)
  end
end

function FileIO.write_user_placement_match_file(user_id, placement_matches)
  local sep = package.config:sub(1, 1)
  local pm_table = {}
  pm_table[#pm_table + 1] = {"op_user_id", "op_name", "op_rating", "outcome"}
  for k, v in ipairs(placement_matches) do
    pm_table[#pm_table + 1] = {v.op_user_id, v.op_name, v.op_rating, v.outcome}
  end
  FileIO.makeDirectoryRecursive("placement_matches" .. sep .. "incomplete")
  local fullFileName = "placement_matches" .. sep .. "incomplete" .. sep .. user_id .. ".csv"
  local status, error = pcall(
    function()
      csvfile.write(fullFileName, pm_table)
    end
  )
  if not status then
    logger.error("Failed to write user placement match file: " .. fullFileName .. " with error: " .. error)
  end
end

function FileIO.write_replay_file(replay, path, filename)
  local sep = package.config:sub(1, 1)
  local status, error = pcall(
    function()
      FileIO.makeDirectoryRecursive(path)
      local f = assert(io.open(path .. sep .. filename, "w"))
      io.output(f)
      io.write(json.encode(replay))
      io.close(f)
    end
  )
  if not status then
    logger.error("Failed to write replay file: " .. path .. sep .. filename .. " with error: " .. error)
  end
end

-- Derive a FRESH csprng seed on every startup. The old behaviour read a static
-- number out of csprng_seed.txt and used it verbatim, so the MT/ISAAC sequence
-- (and thus the user_ids cs_random hands out) replayed identically after every
-- server restart — that's the source of repeated/predictable ids. We now pull
-- real OS entropy from /dev/urandom (available on the Linux server and macOS),
-- fall back to time + the previously persisted seed, and write the new value
-- back so each boot starts from a different point.
function FileIO.read_csprng_seed_file()
  pcall(
    function()
      local seed

      -- 1) Preferred: 4 bytes of real entropy → a fresh 32-bit seed each boot.
      local urandom = io.open("/dev/urandom", "rb")
      if urandom then
        local bytes = urandom:read(4)
        io.close(urandom)
        if bytes and #bytes == 4 then
          seed = 0
          for i = 1, 4 do
            seed = seed * 256 + bytes:byte(i)
          end
        end
      end

      -- 2) Fallback: mix wall-clock + CPU time + the previously persisted seed
      --    so each boot still differs even without /dev/urandom.
      if not seed then
        local prev = 0
        local f = io.open("csprng_seed.txt", "r")
        if f then
          prev = tonumber(f:read("*all")) or 0
          io.close(f)
        end
        seed = (os.time() + math.floor((os.clock() % 1) * 1e6) + prev) % (2 ^ 32 - 1)
      end

      csprng_seed = math.floor(seed)

      -- 3) Persist the new seed so the next boot starts somewhere different.
      local out = io.open("csprng_seed.txt", "w")
      if out then
        out:write(tostring(csprng_seed))
        io.close(out)
      end
    end
  )
end

---@param game ServerGame
function FileIO.saveReplay(game)
  for i, player in ipairs(game.players) do
    if player.save_replays_publicly == "not at all" then
      logger.debug("replay not saved because a player didn't want it saved")
      return
    end
  end

  local path = "ftp" .. sep .. game.replay:generatePath(sep)
  -- game_<n> sequence within the roster folder; count existing replays there.
  -- lfs.dir throws on a not-yet-created folder, so guard and default to 0.
  local gameIndex = 0
  pcall(function()
    for f in lfs.dir(path) do
      if f:sub(-5) == ".json" then gameIndex = gameIndex + 1 end
    end
  end)
  local filename = game.replay:generateFileName(gameIndex) .. ".json"

  logger.debug("saving replay as " .. path .. sep .. filename)
  FileIO.write_replay_file(game.replay, path, filename)
end

return FileIO