-- replayFrames.lua REPLAY.json OUT.json [FROM_FRAME]
-- Plays a saved game (the bot's REPLAY line) back through the engine and writes both boards, frame by frame.
require("bot.headlessBoot")
do local l = require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local json = require("common.lib.dkjson")
local Match = require("common.engine.Match")
local rp = json.decode(io.open(arg[1]):read("*a"))
local fromFrame = tonumber(arg[3]) or 0
local toFrame = tonumber(arg[4]) or 1e9
local match = Match.createFromReplay(rp.settings)
match.isIrrecoverablyDesynced = function() return false end
match:start()
for i, st in ipairs(match.stacks) do
  for _, c in ipairs(rp.inputs[i] or {}) do st:receiveConfirmedInput(c) end
  st:setMaxRunsPerFrame(1)
end
local grids, gidx, frames = {}, {}, {}
local STATE = { normal = "n", swapping = "s", matched = "m", popping = "p", popped = "x", hovering = "h", falling = "f", landing = "l", dimmed = "d" }
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n) n = math.max(0, math.min(1295, math.floor(n))); return string.sub(B36, math.floor(n / 36) + 1, math.floor(n / 36) + 1) .. string.sub(B36, n % 36 + 1, n % 36 + 1) end
-- the board as the real game draws it: rows from height+1 (above the top) down to row 0 (the dimmed row rising in from below); six
-- characters a cell: colour, state, piece id, timer (two, base 36), swap direction
local function grid(st)
  local rows = {}
  for r = st.height + 1, 0, -1 do
    local cells = {}
    for c = 1, st.width do
      local p = st.panels[r] and st.panels[r][c]
      if not p or (not p.isGarbage and p.color == 0) then cells[c] = "000000" else
        local col = p.isGarbage and (p.metal and "G" or "g") or tostring(p.color)
        local gid = "0"
        if p.isGarbage and p.garbageId then gid = string.sub(B36, (p.garbageId % 36) + 1, (p.garbageId % 36) + 1) end
        local sl = STATE[tostring(p.state)] or "n"
        local tm = "00"
        if sl == "m" or sl == "p" or sl == "s" or sl == "l" or sl == "x" then tm = b36(p.timer or 0) end
        local dir = sl == "s" and (p.isSwappingFromLeft and "L" or "R") or "0"
        -- a matched garbage panel of the bottom row already has the colour it turns into: the page shows it as the panel pops
        if sl == "m" and p.isGarbage and p.color and p.color ~= 0 then dir = tostring(p.color) end
        cells[c] = col .. sl .. gid .. tm .. dir
      end
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return table.concat(rows, "|")
end
local function piece(g) return g.width .. "x" .. g.height .. (g.isMetal and "m" or (g.isChain and "c" or "p")) end
local function incoming(st)
  local t = {}
  for _, src in ipairs(match.garbageSources[st] or {}) do
    local oq = src.outgoingGarbage
    for _, g in ipairs(oq.stagedGarbage) do t[#t + 1] = "s:" .. piece(g) end
    local q = oq.transitTimers
    if q and q.first and q.last then
      for k = q.first, q.last do
        local at = q[k]
        -- transit times are on the stopWatch (the clock minus the countdown); the viewer counts on the frame clock
        for _, g in ipairs(oq.garbageInTransit[at] or {}) do t[#t + 1] = "t" .. (at + (st.clock - st.stopWatch)) .. ":" .. piece(g) end
      end
    end
  end
  for _, g in ipairs(st.incomingGarbage.stagedGarbage) do t[#t + 1] = "w:" .. piece(g) end
  return table.concat(t, ";")
end
local queues, qidx = {}, {}
local function snap()
  local f = { match.clock }
  for _, st in ipairs(match.stacks) do
    local g = grid(st)
    local k = gidx[g]
    if not k then k = #grids; grids[#grids + 1] = g; gidx[g] = k end
    local qs = incoming(st)
    local qk = qidx[qs]
    if not qk then qk = #queues; queues[#queues + 1] = qs; qidx[qs] = qk end
    f[#f + 1] = { st.clock, st.health or 0, st.stop_time or 0, st.shake_time or 0, st.cur_row or 0, st.cur_col or 0, k, qk, st.displacement or 0 }
  end
  return f
end
local n = 0
while not match:hasEnded() and n < 200000 do
  match:run()
  n = n + 1
  if match.clock >= fromFrame and match.clock <= toFrame then frames[#frames + 1] = snap() end
  if match.clock > toFrame then break end
  local done = true
  for _, st in ipairs(match.stacks) do if st.clock < #st.confirmedInput then done = false end end
  if done then break end
end
local out = io.open(arg[2], "w")
out:write(json.encode({ mine = rp.mine, width = match.stacks[1].width, grids = grids, queues = queues, frames = frames, ended = match:hasEnded(),
  fc = (function() local f = match.stacks[1].levelData and match.stacks[1].levelData.frameConstants or {}; return { flash = f.FLASH, face = f.FACE, pop = f.POP } end)() }))
out:close()
print(string.format("frames %d, distinct boards %d, clock %d, ended %s", #frames, #grids, match.clock, tostring(match:hasEnded())))
