-- Quiets the game's logger to LEVEL ("WARN", "ERROR") on whichever build the bot is laid on: upstream's logger has
-- setLogLevel and levels; the chaos build's older logger has neither (and logs everything from DEBUG up), so there
-- the calls below the level are turned into no-ops.
return function(logger, level)
  if logger.setLogLevel and logger.levels then logger.setLogLevel(logger.levels[level]); return end
  local order = { "trace", "debug", "info", "warn", "error" }
  local cut = ({ TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5 })[level] or 4
  for i = 1, cut - 1 do logger[order[i]] = function() end end
end
