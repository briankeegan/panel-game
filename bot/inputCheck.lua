-- FAITHFUL input check: LOCAL stack (is_local=true, like the live bot), decide every frame.
-- Drive the real CursorController to a series of targets and verify the cursor ACTUALLY reaches
-- each one and the swap fires. Pure routing fidelity -- "does the input land where commanded."
require("bot.headlessBoot"); do local l=require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc=_G.loc or function(s) return tostring(s) end
local Match=require("common.engine.Match"); require("common.engine.checkMatches")
local GameModes=require("common.data.GameModes"); local LP=require("common.data.LevelPresets")
local GeneratorSource=require("common.engine.GeneratorSource")
local BoardState=require("bot.BoardState"); local CursorController=require("bot.CursorController")
local m=Match(GeneratorSource(7,true), GameModes.getPreset(GameModes.IDs.ONE_PLAYER_VS_SELF).matchRules)
local s=m:createStackWithSettings(LP.getModern(10), true, "controller"); s:setMaxRunsPerFrame(1)  -- LOCAL
m:addTarget(s,s); m:start()
-- raise some material so there are cells to land on
for i=1,250 do s:receiveConfirmedInput("A"); m:run() end
local ctrl=CursorController.new({cursorMoveInterval=1,reactionFrames=1})
-- sweep targets across the board (row, col) -- col 1..5 so col+1 is in-bounds for a swap
local targets={}
for _,r in ipairs({s.cur_row, 3, 6, 9, 4, 7}) do for _,c in ipairs({1,5,3,2,4}) do targets[#targets+1]={r,c} end end
local reached,swapped,total=0,0,0
local fails={}
for _,t in ipairs(targets) do
  total=total+1
  local sw0=s.swapCount or 0
  local arrived,usedF=false,0
  for f=1,150 do  -- generous window: rule out "just slow at DAS speed"
    s.stop_time=9999999  -- FREEZE the rise during routing: isolate pure cursor fidelity from the rising-board push
    local st=BoardState.extract(s)
    local ch=ctrl:nextInput(st, {type="SWAP", pos={t[1],t[2]}})
    s:receiveConfirmedInput(ch); m:run()
    usedF=f
    if s.cur_row==t[1] and s.cur_col==t[2] then arrived=true end
    if (s.swapCount or 0)>sw0 then break end
  end
  if arrived then reached=reached+1 else
    fails[#fails+1]=string.format("NOT REACHED target(%d,%d): cursor stuck at (%d,%d) after %df  cur_timer=%s dir=%s",
      t[1],t[2], s.cur_row,s.cur_col, usedF, tostring(s.cur_timer), tostring(s.cursorDirection)) end
  if (s.swapCount or 0)>sw0 then swapped=swapped+1 end
end
print(string.format("INPUT CHECK (local stack): cursor REACHED target %d/%d  |  swap FIRED %d/%d  |  engine swapCount=%d",
  reached,total,swapped,total,s.swapCount or 0))
for _,f in ipairs(fails) do print("  "..f) end
