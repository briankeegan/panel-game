-- Puzzle benchmark (GOAL #5 — "Solve the mechanics"): drop the HARD bot on each of
-- the game's 235 hand-authored, technique-tagged puzzles (frozen boards) and ask the
-- ENGINE'S OWN win condition whether the bot solved it. A deterministic, win-rate-free
-- per-set pass-rate: "does the bot understand this technique."
--
-- FAITHFULNESS (same discipline as survivalStress.lua): we do NOT re-implement the
-- board, the puzzle loader, or the win check.
--   * Puzzles are loaded through the GAME'S OWN loader, PuzzleSet.loadFromFile, so every
--     field (stopTime/shakeTime/panelBuffer/cursorStartLeft/derived startTiming) is the
--     literal in-game value. (A hand-rolled JSON parse silently dropped Stop/Shake/cursor
--     and made every `clear` puzzle unsolvable — caught by the --solutions self-check.)
--   * The Match is built exactly as the client does: Puzzle:toGameMode() +
--     Puzzle:toPanelSource() -> Match(panelSource, matchRules) -> createStackWithSettings
--     -> match:start().
--   * The bot is driven with the SAME decide->nextInput->receiveConfirmedInput->run loop
--     the live bot uses (BotClient:tickMatch / survivalStress).
--   * Solved is read straight off the engine: a puzzle Match ends because the stack WON
--     (checkGameWin -> game_ended, game_over_clock stays <=0) or DIED/topped-out/ran out
--     of swaps (game_over_clock > 0). Exact discriminator PuzzleGame.lua:362 uses.
--
-- Level 10 by default: the bot's play/training target is L10 (BotClient.lua:90), and the
-- recorded solutions self-check ~98% at L10 vs ~50% at L5 — i.e. the puzzle SOLUTIONS are
-- L10-authored too, so L10 is the faithful environment.
--
-- Usage: luajit bot/puzzleBench.lua [setFilter] [maxPuzzles] [profile] [difficulty] [level] [maxFrames]
--        luajit bot/puzzleBench.lua --solutions [setFilter] ...   (harness self-check: replay
--                                                                   each puzzle's own solution)
--   setFilter : substring of the leaf set name (e.g. "insert", "combo_chain", "chain",
--               "clear") or "all" (default). Case-insensitive.
-- e.g.: luajit bot/puzzleBench.lua insert
--       luajit bot/puzzleBench.lua --solutions all     # should be ~100% if harness is sound
io.stdout:setvbuf("no")
require("bot.headlessBoot")

do local logger = require("common.lib.logger"); logger.setLogLevel(logger.levels.WARN) end
_G.loc = _G.loc or function(s) return tostring(s) end -- localization stub for PuzzleSet

local Match = require("common.engine.Match")
require("common.engine.checkMatches") -- registers match/garbage logic on Stack
local PuzzleSet = require("client.src.PuzzleSet")
local LevelPresets = require("common.data.LevelPresets")
local BoardState = require("bot.BoardState")
local SearchBrain = require("bot.SearchBrain")
local CursorController = require("bot.CursorController")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local InputCompression = require("common.data.InputCompression")

-- CLI (optional leading --solutions flag = harness self-check mode)
local A = { unpack and unpack(arg) or table.unpack(arg) }
local solutionMode = false
if A[1] == "--solutions" then solutionMode = true; table.remove(A, 1) end
local setFilter = (A[1] and A[1] ~= "" and A[1] ~= "all") and A[1]:lower() or nil
local maxPuzzles = tonumber(A[2]) or 9999
local profilePath = (A[3] and A[3] ~= "" and A[3] ~= "hard") and A[3] or nil
local difficulty = A[4] or "hard"
local level = tonumber(A[5]) or 10            -- bot play/training target (BotClient.lua:90)
local maxFrames = tonumber(A[6]) or 2000      -- ~33s cap; never-solving puzzles fail here

-- Load via the game's own loader, then flatten to { puzzle=<Puzzle>, set=<setName> }.
local sets = PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json")
local flat = {}
local function walk(s)
  if s.puzzles then
    for _, p in ipairs(s.puzzles) do flat[#flat + 1] = { puzzle = p, set = s.setName } end
  end
  for _, c in ipairs(s.puzzleSets or {}) do walk(c) end
end
for _, s in ipairs(sets) do walk(s) end

-- Build a real puzzle Match for a loaded Puzzle object.
local function buildMatch(puzzle)
  local match = Match(puzzle:toPanelSource(false), puzzle:toGameMode().matchRules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(level), true, "controller", nil)
  stack:setMaxRunsPerFrame(1) -- one engine frame per fed input, like live ticks
  match:start()
  return match, stack
end

-- Engine's verdict (PuzzleGame.lua:362): ended without dying = solved.
local function verdict(stack)
  local died = (stack.game_over_clock or -1) > 0
  return stack:game_ended() and not died
end

-- Drive the bot (or, with useSolution, replay the puzzle's recorded optimal solution).
local function play(puzzle, useSolution)
  local match, stack = buildMatch(puzzle)
  if useSolution then
    local inputs = InputCompression.decompressInputString
      and InputCompression.decompressInputString(puzzle.solution)
      or InputCompression.decompressInputString2(puzzle.solution)
    for i = 1, #inputs do
      if stack:game_ended() then break end
      stack:receiveConfirmedInput(inputs:sub(i, i)); match:run()
    end
    for _ = 1, 180 do -- let the final chain/clear settle after inputs end
      if stack:game_ended() then break end
      stack:receiveConfirmedInput("A"); match:run()
    end
    return verdict(stack), 0, 0
  end
  local brain = profilePath and SearchBrain.load(profilePath, difficulty)
    or SearchBrain.new({ difficulty = difficulty })
  local controller = CursorController.new(difficulty)
  local swaps, frame = 0, 0
  while frame < maxFrames and not stack:game_ended() do
    local st = BoardState.extract(stack)
    local decision = brain:decide(st)
    local char = controller:nextInput(st, decision)
    if char == KeyDataEncoding.swap then swaps = swaps + 1 end
    stack:receiveConfirmedInput(char); match:run()
    frame = frame + 1
  end
  return verdict(stack), frame, swaps
end

-- Run
local results, byType = {}, {}
local function bump(t, k, solved)
  t[k] = t[k] or { pass = 0, total = 0 }
  t[k].total = t[k].total + 1
  if solved then t[k].pass = t[k].pass + 1 end
end

print(string.format("PUZZLE-BENCH%s (real engine + real loader): filter=%s profile=%s difficulty=%s level=%d maxFrames=%d",
  solutionMode and " [SELF-CHECK: optimal-solution replay]" or "",
  setFilter or "all", tostring(profilePath or "(plain)"), difficulty, level, maxFrames))

local n = 0
for _, e in ipairs(flat) do
  local nameMatch = (not setFilter) or (e.set and e.set:lower():find(setFilter, 1, true))
  local hasSol = (not solutionMode) or (e.puzzle.solution ~= nil)
  if nameMatch and hasSol and n < maxPuzzles then
    local ok, solved = pcall(play, e.puzzle, solutionMode)
    if not ok then
      print(string.format("  ERR  %-48s %s", e.set or "?", tostring(solved):sub(1, 80)))
      solved = false
    end
    bump(results, e.set or "?", solved)
    bump(byType, e.puzzle.puzzleType or "?", solved)
    n = n + 1
  end
end

local function pct(p, t) return t > 0 and (100 * p / t) or 0 end
local names = {}
for k in pairs(results) do names[#names + 1] = k end
table.sort(names)

print("\n=== PER-SET PASS-RATE ===")
for _, s in ipairs(names) do
  local r = results[s]
  print(string.format("  %5.0f%%  %3d/%-3d  %s", pct(r.pass, r.total), r.pass, r.total, s))
end
print("\n=== PER-TYPE ===")
for _, t in ipairs({ "moves", "chain", "clear" }) do
  local r = byType[t]
  if r then print(string.format("  %5.0f%%  %3d/%-3d  %s", pct(r.pass, r.total), r.pass, r.total, t)) end
end
local tp, ta = 0, 0
for _, r in pairs(results) do tp = tp + r.pass; ta = ta + r.total end
print(string.format("\nOVERALL: %d/%d solved (%.1f%%)", tp, ta, pct(tp, ta)))
os.exit(0)
