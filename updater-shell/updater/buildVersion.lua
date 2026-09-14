local helpers = require "updater.helpers"

-- Version processor for Panel Attack's BUILD_VERSION scheme: "<engine>.<patch>[-name]"
-- e.g. "049.0010-sat-cats". Collapse to one monotonically-increasing number so a
-- newer build compares greater; the human "-name" suffix is ignored for ordering.
-- engine*1e6 leaves room for 6-digit patches (patches are 4 digits). The embedded
-- base version is "0" -> 0.
local function toVersion(versionString, prefix)
  if prefix then
    versionString = versionString:gsub(helpers.escapeSpecialCharacters(prefix), "")
  end
  local engine, patch = versionString:match("^(%d+)%.(%d+)")
  if engine and patch then
    return tonumber(engine) * 1000000 + tonumber(patch)
  end
  return tonumber(versionString) or 0
end

local function getDefaultVersion()
  return 0
end

return { toVersion = toVersion, getDefaultVersion = getDefaultVersion }
