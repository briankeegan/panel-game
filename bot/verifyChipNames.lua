-- verifyChipNames.lua — recall each CACHE chip on the corpus, PLAY it on the real engine, measure the ACTUAL effect
-- (first-combo size, max chain depth, garbage broken) and name it engine-truth: [BREAK_]COMBO_<X>[_CHAIN_<N>].
require("bot.headlessBoot"); _G.loc = _G.loc or function(s) return tostring(s) end
do local l=require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local Match=require("common.engine.Match"); require("common.engine.checkMatches")
local LP=require("common.data.LevelPresets"); local KDE=require("common.data.KeyDataEncoding")
local Puzzle=require("common.engine.Puzzle"); local BoardState=require("bot.BoardState"); local PuzzleSet=require("client.src.PuzzleSet")
local BoardSim=require("bot.BoardSim"); local useChips=require("bot.useChips").useChips
local sets=PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json"); local flat={}
local function w(s) if s.puzzles then for _,p in ipairs(s.puzzles) do flat[#flat+1]={p=p} end end for _,c in ipairs(s.puzzleSets or {}) do w(c) end end
for _,s in ipairs(sets) do w(s) end
local function bld(stack) local p=Puzzle({puzzleType="moves",stack=stack,moves=99}); local m=Match(p:toPanelSource(false),p:toGameMode().matchRules)
  local st=m:createStackWithSettings(LP.getModern(10),true,"controller",nil); st:setMaxRunsPerFrame(1); m:start()
  for i=1,200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end return m,st end
local function gridOf(st) return BoardSim.colorGrid(BoardState.extract(st).board, st.height), st.height end
local function measure(stack, moves)
  local ok, combos, maxChain, garbage = pcall(function()
    local m,st=bld(stack); local cs={}; local mc=0; local gb=0; local sub={}
    st:connectSignal("matched", sub, function(_,_,_,_,c) if type(c)=="number" then cs[#cs+1]=c end end)
    st:connectSignal("garbageMatched", sub, function(_,c) gb=gb+(c or 0) end)
    for _,mv in ipairs(moves) do st.cur_row,st.cur_col=mv[1],mv[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for k=1,120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run()
        if (st.chain_counter or 0)>mc then mc=st.chain_counter end
        if k>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
    return cs, mc, gb end)
  if not ok then return nil end
  return combos, maxChain, garbage
end
local function nameOf(cs, mc, gb)
  if not cs or #cs==0 then return nil end
  local n=(gb>0 and "BREAK_" or "").."COMBO_"..cs[1]
  if mc>=2 then n=n.."_CHAIN_"..mc end
  return n
end
local tally, recalled, fired, comboChain = {}, 0, 0, 0
for _, e in ipairs(flat) do
  local ok, st = pcall(function() local _,s=bld(e.p.stack); return s end)
  if ok and st then local g, rows = gridOf(st)
    local chip = useChips(g, rows, {st.cur_row, st.cur_col}, { chipPriorities={"CACHE"}, searchPriorities={"LEFT","RIGHT","UP","DOWN"} })
    if chip then recalled=recalled+1
      local cs, mc, gb = measure(e.p.stack, chip.swaps)
      local nm = nameOf(cs, mc, gb)
      if nm then fired=fired+1; tally[nm]=(tally[nm] or 0)+1; if mc>=2 and cs[1]>3 then comboChain=comboChain+1 end end
    end
  end
end
local names={}; for n in pairs(tally) do names[#names+1]=n end; table.sort(names)
print(string.format("ENGINE-TRUTH: recalled %d, FIRED %d (%.0f%%) -> %d distinct verified names", recalled, fired, recalled>0 and 100*fired/recalled or 0, #names))
for _,n in ipairs(names) do print(string.format("  %-26s %d", n, tally[n])) end
print("\nCOMBO_X_CHAIN_Y with trigger combo >3 (a real combo AND a chain): "..comboChain)
