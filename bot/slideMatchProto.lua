require("bot.headlessBoot"); _G.loc=function(s) return s end
do local lg=require("common.lib.logger"); lg.setLogLevel(lg.levels.WARN) end
local Match=require("common.engine.Match"); require("common.engine.checkMatches"); local LP=require("common.data.LevelPresets"); local Puzzle=require("common.engine.Puzzle")
local BoardState=require("bot.BoardState"); local BoardSim=require("bot.BoardSim"); local PuzzleSet=require("client.src.PuzzleSet")
local sets=PuzzleSet.loadFromFile("client/assets/default_data/puzzles/Puzzles.json"); local flat={}
local function w(s) if s.puzzles then for _,p in ipairs(s.puzzles) do flat[#flat+1]={p=p} end end for _,c in ipairs(s.puzzleSets or {}) do w(c) end end
for _,s in ipairs(sets) do w(s) end
local function rtGrid(stack) local p=Puzzle({puzzleType="moves",stack=stack,moves=1}); local m=Match(p:toPanelSource(false),p:toGameMode().matchRules)
  local st=m:createStackWithSettings(LP.getModern(10),true,"controller",nil); st:setMaxRunsPerFrame(1); m:start()
  for i=1,200 do if st:game_ended() then break end st:receiveConfirmedInput("A") m:run() if i>=2 and not st:hasActivePanels() and not st:hasChainingPanels() then break end end
  local state=BoardState.extract(st); return BoardSim.colorGrid(state.board,#state.board),#state.board end
local function band(g,rows) local top=BoardSim.maxHeight(g,rows) return math.max(1,top-6),math.min(top+1,rows) end
-- a TEMPLATE = participating cells of a 1-swap fire = the matched cells + swap pair, as RELATIVE {dr,dc} with color-class
local function fireTemplate(g,rows,r,c)
  local gs=BoardSim.cloneGrid(g,rows); if gs[r] and gs[r][c+1] then gs[r][c],gs[r][c+1]=gs[r][c+1],gs[r][c] end
  local hit,any=BoardSim.findMatches(gs,rows); if not any then return nil end
  local cells={{r,c}}; for idx in pairs(hit) do cells[#cells+1]={math.floor((idx-1)/6)+1,((idx-1)%6)+1} end
  -- relative to the swap cell, with first-appearance color-class from the START grid g
  local r0,c0=cells[1][1],cells[1][2]; local relabel={}; local nc=0; local t={}
  for _,cell in ipairs(cells) do local col=g[cell[1]][cell[2]] or 0; if not relabel[col] then nc=nc+1 relabel[col]=nc end
    t[#t+1]={cell[1]-r0,cell[2]-c0,relabel[col]} end
  return t
end
-- does template t MATCH at offset (R,C) on board g? only t's cells must satisfy the same/diff color-classes; rest=don't-care
local function matches(g,rows,t,R,C)
  local seen={}
  for _,e in ipairs(t) do local rr,cc=R+e[1],C+e[2]
    if rr<1 or rr>rows or cc<1 or cc>6 or not g[rr] then return false end
    local col=g[rr][cc] or 0; if col==0 then return false end
    if seen[e[3]]==nil then for k,v in pairs(seen) do if v==col then return false end end seen[e[3]]=col
    elseif seen[e[3]]~=col then return false end end
  return true
end
-- author templates from even boards' fire-sites; slide-match on odd boards
local templates={}
for i,e in ipairs(flat) do if i%2==0 then local g,rows=rtGrid(e.p.stack); local lo,hi=band(g,rows)
  for r=lo,hi do for c=1,5 do local t=fireTemplate(g,rows,r,c); if t then templates[#templates+1]=t end end end end end
local n,recog=0,0
for i,e in ipairs(flat) do if i%2==1 then n=n+1 local g,rows=rtGrid(e.p.stack); local hit=false
  for _,t in ipairs(templates) do for R=1,rows do for C=1,6 do if matches(g,rows,t,R,C) then hit=true break end end if hit then break end end if hit then break end end
  if hit then recog=recog+1 end end end
print(string.format("SLIDING templates: %d authored | held-out boards where SOME template fits: %d/%d (%.0f%%)", #templates, recog, n, 100*recog/n))
