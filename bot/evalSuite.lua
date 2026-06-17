-- evalSuite.lua — the ONE entry point to evaluate a bot config across every framework axis.
--
-- WHAT IT IS (per bot/BOT_CEILING_FRAMEWORK.md): a thin ORCHESTRATOR, not a new harness. It
-- runs the three validated measurement primitives as subprocesses, parses their reports, and
-- assembles ONE scorecard keyed to the 7 North-Star dimensions. Nothing is re-implemented here —
-- if a number is wrong, it's wrong in the underlying harness, and that harness is independently
-- runnable + validated. This file only SELECTS scenarios, FEEDS a config, and DIFFS results.
--
-- The three primitives it drives (each standalone, each its own luajit process => isolation):
--   bot/gateBench.lua       ⑤ MECHANICS  — anti-memorization puzzle gate (fixed/held-out/randomized)
--   bot/survivalStress.lua  ④ SURVIVAL   — time-to-topout under a controlled garbage faucet
--   bot/leagueTest.lua      ①②③⑥        — vs KILLABLE reacting opponents (win/pressure/timing/robustness)
--   ⑦ READING/ADAPTATION    — open axis, not yet instrumented (printed as "—").
--
-- USAGE:
--   eval "$(luarocks path --local --lua-version 5.1)"
--   luajit bot/evalSuite.lua [options]
--
-- OPTIONS:
--   --profile=PATH       bot profile json (bot/profiles/*.json); drives survival+league test bot.
--   --difficulty=hard    tier for the gate bot + as fallback when no profile (hard|medium|easy).
--   --brain=search|envelope   which brain the GATE scenario runs (default search). envelope = the EnvelopeBrain chain bot.
--   --wbuild=N           (unused; kept for compatibility)
--   --scenarios=a,b,c    subset of {gate,survival,league} (default: all).
--   --quick              small/fast sizes (smoke). Default is FULL sizes.
--   --ab=PATH            A/B mode: also eval this second profile, print side-by-side + deltas.
--   --ab-brain=X         A/B mode: eval a second BRAIN (e.g. --brain=envelope --ab-brain=search).
--   --ab-wbuild=N        A/B mode: eval a second wbuild weight (compare MPCBuild settings).
--   --raw                also dump each harness's full stdout (debugging the parse).
--
-- NOTE: --brain affects the GATE scenario only — survival/league harnesses construct SearchBrain
-- internally (EnvelopeBrain runs in survival via PA_BRAIN=envelope). Gate is where the planner is developed, so that's
-- the high-value 80%; wiring MPCBrain into survival/league is a follow-up.
--
-- This is the script the user asked for: "good script set up for running and evaluating
-- different scenarios." Add a scenario by appending to SCENARIOS; add an axis by extending the
-- scorecard. Deterministic: every harness uses a fixed seed set, so re-runs reproduce.

----------------------------------------------------------------------
-- args
----------------------------------------------------------------------
local opt = { profile = nil, difficulty = "hard", scenarios = nil, quick = false, ab = nil, raw = false,
              brain = "search", wbuild = nil, abBrain = nil, abWbuild = nil }
for _, a in ipairs(arg) do
  if a == "--quick" then opt.quick = true
  elseif a == "--raw" then opt.raw = true
  elseif a:match("^--profile=") then opt.profile = a:match("=(.+)$")
  elseif a:match("^--difficulty=") then opt.difficulty = a:match("=(.+)$")
  elseif a:match("^--brain=") then opt.brain = a:match("=(.+)$")          -- search|envelope (gate scenario)
  elseif a:match("^--wbuild=") then opt.wbuild = tonumber(a:match("=(.+)$"))
  elseif a:match("^--ab=") then opt.ab = a:match("=(.+)$")               -- A/B a second PROFILE
  elseif a:match("^--ab%-brain=") then opt.abBrain = a:match("=(.+)$")    -- A/B a second BRAIN
  elseif a:match("^--ab%-wbuild=") then opt.abWbuild = tonumber(a:match("=(.+)$"))
  elseif a:match("^--scenarios=") then
    opt.scenarios = {}
    for s in a:match("=(.+)$"):gmatch("[^,]+") do opt.scenarios[s] = true end
  elseif a == "--help" or a == "-h" then
    print("see header of bot/evalSuite.lua"); os.exit(0)
  else
    io.stderr:write("unknown arg: " .. a .. "\n"); os.exit(1)
  end
end

local function want(name) return opt.scenarios == nil or opt.scenarios[name] end

----------------------------------------------------------------------
-- subprocess helper — run a shell command, capture stdout+stderr, exit code.
----------------------------------------------------------------------
local function run(cmd)
  local f = io.popen(cmd .. " 2>&1", "r")
  local out = f:read("*a") or ""
  -- io.popen close() returns ok,reason,code on Lua5.1/LuaJIT
  local ok, _, code = f:close()
  return out, (code or (ok and 0 or 1))
end

local function num(s) return s and tonumber(s) or nil end

----------------------------------------------------------------------
-- SCENARIO REGISTRY — each: how to build the command for a config, and how to parse its report.
-- A scenario returns a flat metrics table; the scorecard maps those into dimensions.
----------------------------------------------------------------------
local SCENARIOS = {
  -- ⑤ MECHANICS — the puzzle gate, live bot.
  gate = {
    label = "⑤ GATE (mechanics)",
    cmd = function(cfg)
      local variants = opt.quick and 1 or 3
      local cap = opt.quick and " --max=40" or ""
      local brain = (cfg.brain and cfg.brain ~= "search") and (" --brain=" .. cfg.brain) or ""
      local wb = cfg.wbuild and (" --wbuild=" .. cfg.wbuild) or ""
      return ("luajit bot/gateBench.lua --bot --difficulty=%s --variants=%d%s%s%s")
        :format(cfg.difficulty, variants, cap, brain, wb)
    end,
    parse = function(out)
      local fixed, held, rand =
        out:match("OVERALL%s+fixed%s+([%d%.]+)%%"),
        out:match("held%-out%s+([%d%.]+)%%"),
        out:match("randomized%s+([%d%.]+)%%")
      return { fixed = num(fixed), heldOut = num(held), randomized = num(rand) }
    end,
  },

  -- ④ SURVIVAL — time-to-topout under the controlled faucet.
  survival = {
    label = "④ SURVIVAL (faucet)",
    cmd = function(cfg)
      local seeds = opt.quick and 3 or 8
      local maxF = opt.quick and 7200 or 10800
      local prof = cfg.profile or "(plain)"
      -- args: garbageEveryFrames maxFrames seeds profile difficulty
      return ("luajit bot/survivalStress.lua 300 %d %d %s %s")
        :format(maxF, seeds, prof, cfg.difficulty)
    end,
    parse = function(out)
      local med, p10 = out:match("SURVIVAL: median%s+([%d%.]+)s%s+p10%s+([%d%.]+)s")
      local brokeMed = out:match("GARBAGE%-BROKEN: median%s+([%d%.]+)")
      return { survMedianS = num(med), survP10S = num(p10), garbBrokenMed = num(brokeMed) }
    end,
  },

  -- ①②③⑥ CONTESTED — vs killable, reacting opponents.
  league = {
    label = "①②③⑥ LEAGUE (contested)",
    cmd = function(cfg)
      local seeds = opt.quick and 2 or 6
      local maxF = opt.quick and 7200 or 10800
      local pool = opt.quick and "PA_POOL=tier:medium,tier:hard " or ""
      local prof = cfg.profile or cfg.difficulty -- "hard"/path both accepted by leagueTest
      return ("%sluajit bot/leagueTest.lua %s %d %d"):format(pool, prof, seeds, maxF)
    end,
    parse = function(out)
      local winAll = out:match("win%%%(all%)=([%d%.]+)")
      local leadP10 = out:match("LEAD%-MARGIN.-p10=(%-?[%d%.]+)")
      local undug = out:match("EFFECTIVE PRESSURE.-mean/match=([%d%.]+)")
      local counter = out:match("TACTICAL TIMING.-=%s*([%d%.]+)%%")
      local robust = out:match("ROBUSTNESS.-p10 lead%-margin.-%)%:?%s*(%-?[%d%.]+)")
      return { winPct = num(winAll), leadP10 = num(leadP10), undug = num(undug),
               counterPct = num(counter), robustP10 = num(robust) }
    end,
  },
}

local ORDER = { "gate", "survival", "league" }

----------------------------------------------------------------------
-- evaluate one config across the selected scenarios -> {metrics by scenario}
----------------------------------------------------------------------
local function evaluate(cfg, tag)
  local results = {}
  for _, name in ipairs(ORDER) do
    if want(name) then
      local sc = SCENARIOS[name]
      io.write(("  [%s] running %-22s ... "):format(tag, sc.label)); io.flush()
      local cmd = sc.cmd(cfg)
      local out, code = run(cmd)
      local m = sc.parse(out)
      m._ok = (code == 0)
      m._cmd = cmd
      m._raw = out
      results[name] = m
      print(m._ok and "ok" or ("ERR(exit " .. tostring(code) .. ")"))
      if opt.raw then print("    cmd: " .. cmd); print(out:gsub("\n", "\n    ")) end
    end
  end
  return results
end

----------------------------------------------------------------------
-- scorecard rendering
----------------------------------------------------------------------
local function fmt(v, suffix, decimals)
  if v == nil then return "  —" end
  return string.format("%." .. (decimals or 1) .. "f%s", v, suffix or "")
end

-- one row: label, value(A), [value(B), delta]. higher is the assumed-better direction unless noted.
local function rows(res)
  local g, s, l = res.gate or {}, res.survival or {}, res.league or {}
  return {
    { "① WIN  win% (vs killable)",        l.winPct,        "%" },
    { "① ROBUST  p10 lead-margin (f)",    l.robustP10 or l.leadP10, "" },
    { "② PRESSURE  un-dug/match",         l.undug,         "" },
    { "③ TIMING  counter-window hit%",    l.counterPct,    "%" },
    { "④ SURVIVAL  median (s)",           s.survMedianS,   "s" },
    { "④ SURVIVAL  p10 (s)",              s.survP10S,      "s" },
    { "④ garbage-broken median",          s.garbBrokenMed, "" },
    { "⑤ GATE  fixed solve%",             g.fixed,         "%" },
    { "⑤ GATE  held-out solve%",          g.heldOut,       "%" },
    { "⑤ GATE  randomized solve%",        g.randomized,    "%" },
    { "⑦ READING/ADAPTATION",             nil,             "" }, -- open axis, not yet measured
  }
end

local function bar() print(string.rep("=", 72)) end

local function render(resA, tagA, resB, tagB)
  print(); bar()
  print(" BOT EVAL SCORECARD — North Star dimensions (bot/BOT_CEILING_FRAMEWORK.md)")
  bar()
  local rA = rows(resA)
  if not resB then
    print(string.format(" %-34s %12s", "DIMENSION", tagA))
    print(string.rep("-", 72))
    for _, r in ipairs(rA) do
      print(string.format(" %-34s %12s", r[1], fmt(r[2], r[3])))
    end
  else
    local rB = rows(resB)
    print(string.format(" %-34s %11s %11s %9s", "DIMENSION", tagA, tagB, "Δ"))
    print(string.rep("-", 72))
    for i, r in ipairs(rA) do
      local a, b = r[2], rB[i][2]
      local d = (a ~= nil and b ~= nil) and string.format("%+.1f", b - a) or "—"
      print(string.format(" %-34s %11s %11s %9s", r[1], fmt(a, r[3]), fmt(b, r[3]), d))
    end
  end
  bar()
  print(" higher = better on every row EXCEPT none here (lead-margin/undug/timing/survival/gate all up).")
  print(" ⑦ reading/adaptation: open axis, no instrument yet. ⑥ robustness = league p10 lead-margin.")
  print(" missing (—) = scenario not run (see --scenarios) or harness parse miss (--raw to inspect).")
  bar()
end

----------------------------------------------------------------------
-- main
----------------------------------------------------------------------
local function tag(cfg)
  local t = cfg.profile or cfg.difficulty
  if cfg.brain == "mpc" then t = t .. "/mpc" .. (cfg.wbuild and ("+wb" .. cfg.wbuild) or "") end
  return t
end

print(string.format("EVAL SUITE  profile=%s  difficulty=%s  brain=%s  scenarios=%s  mode=%s",
  tostring(opt.profile or "(plain)"), opt.difficulty, opt.brain,
  opt.scenarios and table.concat((function() local t = {} for k in pairs(opt.scenarios) do t[#t+1]=k end return t end)(), ",") or "all",
  opt.quick and "quick" or "full"))

local cfgA = { profile = opt.profile, difficulty = opt.difficulty, brain = opt.brain, wbuild = opt.wbuild }
local resA = evaluate(cfgA, "A")

-- A/B if a second profile (--ab) OR a second brain (--ab-brain/--ab-wbuild) is given.
if opt.ab or opt.abBrain or opt.abWbuild then
  local cfgB = { profile = opt.ab or opt.profile, difficulty = opt.difficulty,
                 brain = opt.abBrain or opt.brain, wbuild = opt.abWbuild or (opt.abBrain and opt.wbuild) }
  local resB = evaluate(cfgB, "B")
  render(resA, "A", resB, "B")
  print(" A = " .. tag(cfgA) .. "   B = " .. tag(cfgB))
else
  render(resA, "score")
end
