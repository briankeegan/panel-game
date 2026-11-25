-- HEADLESS BOOT for the chaos v3 engine under plain LuaJIT (no LÖVE).
--   require("headless")(chaosRoot)   -- chaosRoot: the folder holding common/
-- Stubs only what common/engine needs to load and run: lua-utf8, socket.core,
-- and love.math / love.timer. The random generator is NOT LÖVE's: recordings
-- feed the rows and garbage colours they dealt to the C engine, so the C side
-- never depends on how they were generated.
return function(root)
  root = root or "."
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

  package.preload["lua-utf8"] = function()
    local u = {}
    u.charpattern = "[%z\1-\127\194-\244][\128-\191]*"
    function u.len(s) local n = 0; for _ in s:gmatch(u.charpattern) do n = n + 1 end; return n end
    function u.offset(s, n) if n == 1 then return 1 end; local i = 0; for p in s:gmatch("()" .. u.charpattern) do i = i + 1; if i == n then return p end end end
    function u.char(...)
      local out = {}
      for _, c in ipairs({...}) do
        if c < 0x80 then out[#out + 1] = string.char(c)
        elseif c < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(c / 0x40), 0x80 + c % 0x40)
        elseif c < 0x10000 then out[#out + 1] = string.char(0xE0 + math.floor(c / 0x1000), 0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
        else out[#out + 1] = string.char(0xF0 + math.floor(c / 0x40000), 0x80 + math.floor(c / 0x1000) % 0x40, 0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40) end
      end
      return table.concat(out)
    end
    function u.codepoint(s, i) return s:byte(i or 1) end
    return u
  end
  package.preload["utf8"] = package.preload["lua-utf8"]   -- with `love` defined, utf8Additions asks for LÖVE's utf8
  package.preload["socket.core"] = function()
    return { gettime = os.clock, connect = function() return nil, "headless" end }
  end
  package.preload["socket"] = package.preload["socket.core"]
  package.preload["table.clear"] = package.preload["table.clear"] or function()
    return function(t) for k in pairs(t) do t[k] = nil end end
  end
  package.preload["table.new"] = package.preload["table.new"] or function()
    return function() return {} end
  end

  -- a small deterministic generator with LÖVE's RandomGenerator API (not LÖVE's numbers)
  local function newRng()
    local g = { s = 1 }
    function g:setSeed(seed) self.s = (math.floor(seed or 1) % 2147483646) + 1 end
    function g:random(a, b)
      self.s = (self.s * 48271) % 2147483647
      local r = (self.s - 1) / 2147483646
      if not a then return r end
      if not b then a, b = 1, a end
      return a + math.floor(r * (b - a + 1))
    end
    function g:getState() return tostring(self.s) end
    function g:setState(st) self.s = tonumber(st) end
    return g
  end
  local t0 = os.clock()
  love = love or {
    math = { newRandomGenerator = newRng, random = function(a, b) return newRng():random(a, b) end },
    timer = { getTime = function() return os.clock() - t0 end },
  }

  -- client/src/globals.lua (v3): the engine reads these as globals
  GARBAGE_TRANSIT_TIME = 45
  GARBAGE_TELEGRAPH_TIME = 45
  GARBAGE_DELAY_LAND_TIME = 60
  MAX_LAG = 155 + GARBAGE_TELEGRAPH_TIME + GARBAGE_TRANSIT_TIME

  -- the engine logs and profiles through these globals
  prof = prof or { push = function() end, pop = function() end }
  local ok, logger = pcall(require, "common.lib.logger")
  if ok and logger.setLogLevel and logger.levels then logger.setLogLevel(logger.levels.ERROR) end
end
