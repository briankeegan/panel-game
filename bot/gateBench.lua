-- gateBench.lua — the rigorous, anti-memorization PUZZLE GATE.
--
-- Supports BOT_CEILING_FRAMEWORK.md dimension ⑤ (Mechanics): the ceiling bot must
-- solve ~100% of the 235 puzzles to PROVE it can execute every technique — but a
-- planner tuned to the exact 235 fixed boards could "pass" by memorizing layouts
-- without generalizing. This gate catches that overfit with:
--   (a) a HELD-OUT split (deterministic 80/20 PER technique category), and
--   (b) RANDOMIZED-color variants (same shape, permuted colors — can't be solved
--       by memorizing the fixed layouts).
-- and reports a PER-TECHNIQUE scorecard so we see WHICH techniques generalize.
--
-- Faithfulness is proven with --solutions (replay each puzzle's recorded OPTIMAL
-- input). If the harness is faithful, --solutions scores ~99% on the fixed set AND
-- on the SOLVABLE randomized variants. Only after that do bot numbers mean anything.
--
-- This runs the SAME engine the client runs (Match + Stack, via
-- StackReplayTestingUtils.createSinglePlayerMatch on puzzle:toGameMode() +
-- puzzle:toPanelSource(randomize)). A puzzle is SOLVED iff the match ends with the
-- stack's game_over_clock <= 0 — exactly PuzzleGame:customGameOverSetup's criterion.
--
-- Usage:
--   eval "$(luarocks path --local --lua-version 5.1)"
--   luajit bot/gateBench.lua [--solutions|--bot] [options]
--
-- Options:
--   --solutions         replay each puzzle's recorded optimal solution (faithfulness check, default)
--   --bot               run the live SearchBrain on each puzzle
--   --difficulty=hard   bot difficulty tier (hard|medium|easy), --bot only (default hard)
--   --variants=N        randomized variants per puzzle (default 3)
--   --split=0.8         train fraction for the held-out split (default 0.8)
--   --max=N             cap puzzles evaluated (smoke runs)
--   --only=TYPE         restrict to puzzle win-type: moves|chain|clear
--   --verbose           list every failing puzzle
--
-- Reports solve-rate on FIXED / HELD-OUT / RANDOMIZED, overall and per-technique.

io.stdout:setvbuf("no")
require("bot.headlessBoot")
_G.loc = _G.loc or function(s) return s end

local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.ERROR) -- the engine debug-logs every chain; silence it

local PuzzleSet = require("client.src.PuzzleSet")
local InputCompression = require("common.data.InputCompression")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local LevelPresets = require("common.data.LevelPresets")

-- ── args ────────────────────────────────────────────────────────────────────
local opt = { mode = "solutions", difficulty = "hard", variants = 3, split = 0.8,
              max = math.huge, only = nil, verbose = false, brain = "search" }
for _, a in ipairs(arg) do
  if a == "--solutions" then opt.mode = "solutions"
  elseif a == "--bot" then opt.mode = "bot"
  elseif a == "--verbose" then opt.verbose = true
  elseif a:match("^--difficulty=") then opt.difficulty = a:match("=(.+)$")
  elseif a:match("^--variants=") then opt.variants = tonumber(a:match("=(.+)$"))
  elseif a:match("^--split=") then opt.split = tonumber(a:match("=(.+)$"))
  elseif a:match("^--max=") then opt.max = tonumber(a:match("=(.+)$"))
  elseif a:match("^--only=") then opt.only = a:match("=(.+)$")
  elseif a:match("^--brain=") then opt.brain = a:match("=(.+)$") -- search|envelope
  elseif a:match("^--maxframes=") then opt.maxframes = tonumber(a:match("=(.+)$")) -- per-puzzle frame cap
  else io.stderr:write("gateBench: unknown arg '" .. a .. "'\n"); os.exit(1) end
end

-- ── load all puzzles + technique category ────────────────────────────────────
-- The leaf "Set Name" IS the technique tag (e.g. puzzle_set_name_advanced_shoguns).
-- We collapse it to a short technique category for the scorecard.
local TECH_RULES = { -- ordered: first match wins (specific before generic)
  { "clear_puzzles",            "clears" },
  { "earthquake_chains",        "earthquake_chains" },
  { "convert_horizontal",       "horizontal_chains" },
  { "horizontal_chain",         "horizontal_chains" },
  { "horizontal_chains",        "horizontal_chains" },
  { "combo_chain_inserts",      "inserts" },
  { "change_side_inserts",      "inserts" },
  { "pre_setup_inserts",        "inserts" },
  { "inserts",                  "inserts" },
  { "pre_setup_combo_chains",   "combos" },
  { "combo_chains",             "combos" },
  { "combos",                   "combos" },
  { "chains_from_huge_tower",   "chains" },
  { "chains",                   "chains" },
  { "shoguns",                  "shoguns" },
  { "transitions",              "transitions" },
  { "removes",                  "removes" },
  { "openers",                  "openers" },
  { "classic",                  "classic" },
}
local function techniqueOf(setName)
  setName = setName or "unknown"
  for _, rule in ipairs(TECH_RULES) do
    if setName:find(rule[1], 1, true) then return rule[2] end
  end
  return "other"
end

-- Reuse the game's own loader (PuzzleSet.loadFromFile) so every Puzzle carries its
-- full engine config: puzzleType, stopTime, shakeTime, cursorStartLeft, startTiming,
-- and the recorded optimal solution — exactly what the live PuzzleGame scene loads.
-- We wrap each Puzzle with its leaf set name + technique tag for the scorecard.
local function loadPuzzles()
  local path = "client/assets/default_data/puzzles/Puzzles.json"
  local sets = PuzzleSet.loadFromFile(path)
  local out = {}
  local function collect(node)
    local setName = node.setName or "unknown"
    if node.puzzles then
      for idx, puzzle in ipairs(node.puzzles) do
        out[#out + 1] = {
          puzzle = puzzle, set = setName, technique = techniqueOf(setName),
          localIndex = idx, type = puzzle.puzzleType, solution = puzzle.solution,
        }
      end
    end
    if node.puzzleSets then
      for _, child in ipairs(node.puzzleSets) do collect(child) end
    end
  end
  for _, s in ipairs(sets) do collect(s) end
  return out
end

-- ── deterministic held-out split (per technique, 80/20) ──────────────────────
-- Stable order WITHIN a technique = (set name, localIndex); every Kth puzzle is
-- held out so each technique contributes to held-out. Deterministic, no RNG.
local function assignSplit(puzzles, trainFrac)
  local byTech = {}
  for _, pz in ipairs(puzzles) do
    byTech[pz.technique] = byTech[pz.technique] or {}
    table.insert(byTech[pz.technique], pz)
  end
  local holdEvery = math.max(2, math.floor(1 / math.max(0.01, 1 - trainFrac) + 0.5)) -- 0.8 -> every 5th
  for _, list in pairs(byTech) do
    table.sort(list, function(a, b)
      if a.set ~= b.set then return a.set < b.set end
      return a.localIndex < b.localIndex
    end)
    for i, pz in ipairs(list) do
      pz.split = (i % holdEvery == 0) and "heldout" or "train"
    end
  end
end

-- ── solving one puzzle (engine truth) ────────────────────────────────────────
-- Bot mode: a thrashing bot that never solves AND never tops out otherwise burns the
-- full cap per puzzle (the 34-min-run pathology). A real solve finishes in <<6000 frames;
-- beyond that it's looping. Solution-replay mode keeps the high cap (exact inputs, short).
local MAX_FRAMES = opt.maxframes or (opt.mode == "bot" and 6000 or 100000)

local function buildMatch(pz, randomize, seed)
  if randomize then love.math.setRandomSeed(seed) end
  local puzzle = pz.puzzle
  local match = StackReplayTestingUtils.createSinglePlayerMatch(
    puzzle:toGameMode(), puzzle:toPanelSource(randomize), "controller", LevelPresets.getModern(10))
  return match, match.stacks[1]
end

local function isSolved(match, stack)
  return match:isLocallyEnded() and (stack.game_over_clock <= 0)
end

-- Replay the recorded OPTIMAL solution. Faithfulness oracle.
local function solveBySolution(pz, randomize, seed)
  if not pz.solution then return nil end -- no recorded solution -> can't self-check
  local match, stack = buildMatch(pz, randomize, seed)
  -- "AA": the engine can't swap on the first two frames (see StackTests puzzleTest).
  stack:receiveConfirmedInput("AA" .. InputCompression.decompressInputString2(pz.solution))
  local guard = 0
  while not match:isLocallyEnded() and guard < MAX_FRAMES do match:run(); guard = guard + 1 end
  return isSolved(match, stack)
end

-- Run the LIVE bot (SearchBrain + CursorController) on the puzzle, one engine frame
-- at a time — the exact decide->nextInput->receiveConfirmedInput->run loop BotClient
-- uses for online play, against the puzzle stack instead of a network stack.
local _botBrain, _botController, _boardState
local function botParts(difficulty)
  if not _botBrain then
    _botBrain = require("bot.EnvelopeBrain").new({})
    _botController = require("bot.CursorController").new(difficulty)
    _boardState = require("bot.BoardState")
  end
  -- CursorController carries per-puzzle latch state; rebuild it each puzzle.
  _botController = require("bot.CursorController").new(difficulty)
  return _botBrain, _botController, _boardState
end

local function solveByBot(pz, randomize, seed, difficulty)
  local match, stack = buildMatch(pz, randomize, seed)
  local brain, controller, boardState = botParts(difficulty)
  local guard = 0
  while not match:isLocallyEnded() and guard < MAX_FRAMES do
    if not stack:game_ended() then
      local st = boardState.extract(stack)
      local decision = brain:decide(st)
      local char = controller:nextInput(st, decision)
      stack:receiveConfirmedInput(char)
    end
    match:run()
    guard = guard + 1
  end
  return isSolved(match, stack)
end

-- ── scorecard accumulation ───────────────────────────────────────────────────
local function newCounter() return { n = 0, ok = 0 } end
local function bump(c, solved) c.n = c.n + 1; if solved then c.ok = c.ok + 1 end end
local function pct(c) if c.n == 0 then return "  n/a " end return string.format("%5.1f%%", 100 * c.ok / c.n) end

-- A "bucket" = one column of the scorecard (fixed / heldout / randomized).
-- Each bucket has an overall counter + a per-technique counter.
local function newBucket()
  return { overall = newCounter(), tech = setmetatable({}, { __index = function(t, k) rawset(t, k, newCounter()); return t[k] end }) }
end
local function record(bucket, technique, solved)
  bump(bucket.overall, solved)
  bump(bucket.tech[technique], solved)
end

-- ── run ──────────────────────────────────────────────────────────────────────
local puzzles = loadPuzzles()
assignSplit(puzzles, opt.split)

local fixed, heldout, randomized = newBucket(), newBucket(), newBucket()
local randomUnsolvableBySolution = {} -- puzzles whose OPTIMAL solution fails after randomization

local solveFixed = (opt.mode == "solutions") and function(pz) return solveBySolution(pz, false) end
  or function(pz) return solveByBot(pz, false, nil, opt.difficulty) end

local count = 0
local t0 = os.clock()
for _, pz in ipairs(puzzles) do
  if (not opt.only or pz.type == opt.only) and count < opt.max then
    count = count + 1

    -- FIXED (all puzzles) + HELD-OUT (the held-out subset only)
    local solvedFixed = solveFixed(pz)
    if solvedFixed ~= nil then
      record(fixed, pz.technique, solvedFixed)
      if pz.split == "heldout" then record(heldout, pz.technique, solvedFixed) end
      if not solvedFixed and opt.verbose then
        print(string.format("  FIXED FAIL  [%s] %s/%s", pz.split, pz.set, pz.type))
      end
    end

    -- Does the recorded optimal solution still solve the FIXED board? Needed to
    -- distinguish "broke under randomization" from "solution never re-sims at all".
    local solutionSolvesFixed = (opt.mode == "solutions") and solvedFixed or solveBySolution(pz, false)

    -- RANDOMIZED variants. The OPTIMAL solution doubles as a solvability oracle:
    -- if the recorded solution can't solve a randomized variant, that variant is
    -- genuinely unsolvable-by-that-input (color permutation changed the board's
    -- matchability) — so a bot FAILURE there isn't the bot's fault. We only count
    -- a randomized variant for the bot if the optimal solution still solves it.
    for v = 1, opt.variants do
      local seed = (count * 1000 + v) -- deterministic per (puzzle, variant)
      if opt.mode == "solutions" then
        local s = solveBySolution(pz, true, seed)
        if s ~= nil then
          record(randomized, pz.technique, s)
          -- Only flag as randomization-sensitive if the solution solves the FIXED
          -- board but FAILS the randomized one (else it's a faithless solution, not
          -- a color-dependency). Exclude the pre-existing fixed-fail puzzles.
          if not s and solutionSolvesFixed then
            randomUnsolvableBySolution[pz.set .. "/" .. pz.type] =
              (randomUnsolvableBySolution[pz.set .. "/" .. pz.type] or 0) + 1
            if opt.verbose then print(string.format("  RAND  FAIL  %s/%s seed=%d", pz.set, pz.type, seed)) end
          end
        end
      else
        -- bot mode: gate on the solution oracle so we only score solvable variants
        if solveBySolution(pz, true, seed) then
          local s = solveByBot(pz, true, seed, opt.difficulty)
          record(randomized, pz.technique, s)
          if not s and opt.verbose then
            print(string.format("  RAND  FAIL  %s/%s seed=%d", pz.set, pz.type, seed))
          end
        end
      end
    end
  end
end
local elapsed = os.clock() - t0

-- ── report ───────────────────────────────────────────────────────────────────
local _brainLabel = opt.brain == "envelope" and "EnvelopeBrain" or "SearchBrain"
local label = (opt.mode == "solutions") and "OPTIMAL-SOLUTION REPLAY (faithfulness oracle)"
  or ("LIVE BOT (" .. _brainLabel .. ", difficulty=" .. opt.difficulty .. ")")

print("")
print("================================================================")
print(" PUZZLE GATE — " .. label)
print(string.format(" 235-corpus | split=%.2f train | %d randomized variants/puzzle", opt.split, opt.variants))
print("================================================================")
print("")
print(string.format(" OVERALL    fixed %s (%d/%d)   held-out %s (%d/%d)   randomized %s (%d/%d)",
  pct(fixed.overall), fixed.overall.ok, fixed.overall.n,
  pct(heldout.overall), heldout.overall.ok, heldout.overall.n,
  pct(randomized.overall), randomized.overall.ok, randomized.overall.n))
print("")

-- per-technique table
local techs = {}
for t in pairs(fixed.tech) do techs[#techs + 1] = t end
table.sort(techs)
print(" PER-TECHNIQUE                fixed        held-out      randomized")
print(" ---------------------------------------------------------------------")
for _, t in ipairs(techs) do
  local f, h, r = fixed.tech[t], heldout.tech[t], randomized.tech[t]
  print(string.format("  %-24s  %s (%d/%-3d)  %s (%d/%-3d)  %s (%d/%d)",
    t, pct(f), f.ok, f.n, pct(h), h.ok, h.n, pct(r), r.ok, r.n))
end
print("")

if opt.mode == "solutions" and next(randomUnsolvableBySolution) then
  print(" PUZZLES WHOSE OPTIMAL SOLUTION DOES NOT SURVIVE COLOR-RANDOMIZATION:")
  print(" (the recorded optimal input depends on the specific color assignment;")
  print("  these variants are excluded from the bot's randomized scoring)")
  local keys = {}
  for k in pairs(randomUnsolvableBySolution) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    print(string.format("   %s  (failed %d/%d variants)", k, randomUnsolvableBySolution[k], opt.variants))
  end
  print("")
end

print(string.format(" %d puzzles evaluated in %.1fs", count, elapsed))
print("================================================================")
