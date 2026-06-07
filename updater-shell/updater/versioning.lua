local semanticVersion = require("updater.semanticVersion")
local timestampVersion = require("updater.timestampVersion")
local buildVersion = require("updater.buildVersion")

local versioning = {}

function versioning.getVersionProcessor(type)
  if type == "semantic" then
    return semanticVersion
  elseif type == "timestamp" then
    return timestampVersion
  elseif type == "build" then
    return buildVersion
  end
end

function versioning.toVersion(versionString, type)
  local versionProcessor = versioning.getVersionProcessor(type)
  return versionProcessor.toVersion(versionString)
end

return versioning