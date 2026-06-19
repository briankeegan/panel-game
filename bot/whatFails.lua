-- whatFails.lua — for each board, recall the cache plan DIRECTLY (get the stored claim), play it on the real engine,
-- and bucket: PHANTOM (claimed a clear, fired nothing) / CHAIN DOWNGRADE (claimed chain N, fired < N) / OK.
require("bot.headlessBoot"); _G.loc=_G.loc or function(s) return tostring(s) end
do local l=require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
local Match=require("common.engine.Match"); require("common.engine.checkMatches")
local LP=require("common.data.LevelPresets"); local KDE=require("common.data.KeyDataEncoding")
local Puzzle=require("common.engine.Puzzle"); local BoardState=require("bot.BoardState"); local PuzzleSet=require("client.src.PuzzleSet")
local BoardSim=require("bot.BoardSim"); local planCache=require("bot.planCache"); local STORE=planCache.store()
local sets=PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json"); local flat={}
local function w(s) if s.puzzles then for _,p in ipairs(s.puzzles) do flat[#flat+1]={p=p} end end for _,c in ipairs(s.puzzleSets or {}) do w(c) end end
for _,s in ipairs(sets) do w(s) end
local function bld(stack) local p=Puzzle({puzzleType="moves",stack=stack,moves=99}); local m=Match(p:toPanelSource(false),p:toGameMode().matchRules)
  local st=m:createStackWithSettings(LP.getModern(10),true,"controller",nil); st:setMaxRunsPerFrame(1); m:start()
  for i=1,200 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run() if i>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end return m,st end
local function gridOf(st) return BoardSim.colorGrid(BoardState.extract(st).board, st.height), st.height end
local function measure(stack, moves)
  local ok, cs, mc, gb = pcall(function()
    local m,st=bld(stack); local c={}; local x=0; local g=0; local sub={}
    st:connectSignal("matched", sub, function(_,_,_,_,v) if type(v)=="number" then c[#c+1]=v end end)
    st:connectSignal("garbageMatched", sub, function(_,v) g=g+(v or 0) end)
    for _,mv in ipairs(moves) do st.cur_row,st.cur_col=mv[1],mv[2]; st:receiveConfirmedInput(KDE.swap); m:run()
      for k=1,120 do if st:game_ended() then break end st:receiveConfirmedInput("A"); m:run()
        if (st.chain_counter or 0)>x then x=st.chain_counter end
        if k>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end end
    return c, x, g end)
  if not ok then return nil, 0, 0 end
  return cs, mc, gb
end
local phantom, downgrade, ok_, byClaim = 0, 0, 0, {}
for _, e in ipairs(flat) do
  local okb, st = pcall(function() local _,s=bld(e.p.stack); return s end)
  if okb and st then local g, rows = gridOf(st)
    local m = planCache.match(g, rows)
    if m and m.key and STORE[m.key] then
      local eff = STORE[m.key].effect or {}
      local claimChain = eff.chain or 1
      local claim = (claimChain>=2) and ("CHAIN_"..claimChain) or ("COMBO_"..(eff.total or 0))
      local cs, mc, gb = measure(e.p.stack, m.plan)
      if not cs or #cs==0 then phantom=phantom+1; byClaim[claim]=byClaim[claim] or {p=0,d=0,o=0}; byClaim[claim].p=byClaim[claim].p+1
      elseif claimChain>=2 and mc<claimChain then downgrade=downgrade+1; byClaim[claim]=byClaim[claim] or {p=0,d=0,o=0}; byClaim[claim].d=byClaim[claim].d+1
      else ok_=ok_+1; byClaim[claim]=byClaim[claim] or {p=0,d=0,o=0}; byClaim[claim].o=byClaim[claim].o+1 end
    end
  end
end
print(string.format("recalls measured: OK %d | PHANTOM (fired nothing) %d | CHAIN-DOWNGRADE (claimed deeper) %d", ok_, phantom, downgrade))
print("\nby STORED claim  (ok / phantom / downgrade):")
local cl={}; for k in pairs(byClaim) do cl[#cl+1]=k end; table.sort(cl)
for _,k in ipairs(cl) do local b=byClaim[k]; print(string.format("  %-12s ok=%-3d phantom=%-3d downgrade=%-3d", k, b.o, b.p, b.d)) end
