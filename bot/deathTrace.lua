-- FAITHFUL single-seed death trace: LOCAL stack (is_local=true, like the live bot), decide every frame.
-- One seed, deep. Captures: survival, last-clear (stall vs overwhelmed), the death board, and a sampled
-- trajectory of the final frames (tallest height + what the brain decided + total cleared) so we SEE the death.
require("bot.headlessBoot"); do local l=require("common.lib.logger"); l.setLogLevel(l.levels.ERROR) end
_G.loc=_G.loc or function(s) return tostring(s) end
local Match=require("common.engine.Match"); require("common.engine.checkMatches")
local GameModes=require("common.data.GameModes"); local LP=require("common.data.LevelPresets")
local GeneratorSource=require("common.engine.GeneratorSource")
local BoardState=require("bot.BoardState"); local EnvelopeBrain=require("bot.EnvelopeBrain"); local CursorController=require("bot.CursorController")
local SEED=tonumber(arg[1]) or 7
local m=Match(GeneratorSource(SEED,true), GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS).matchRules)  -- REAL endless: StackInteractions.NONE = NO garbage (vs VS_SELF which self-garbages)
local s=m:createStackWithSettings(LP.getModern(10), true, "controller"); s:setMaxRunsPerFrame(1)  -- LOCAL = faithful
m:start()  -- NO addTarget: endless has no garbage target (addTarget(s,s) was self-garbaging the bot)
local brain=EnvelopeBrain.new({}); local ctrl=CursorController.new({cursorMoveInterval=1,reactionFrames=1})
local function tallest() local mh=0; for c=1,6 do for r=#s.panels,1,-1 do local p=s.panels[r][c]; if p and ((p.color or 0)~=0 or p.isGarbage) then if r>mh then mh=r end; break end end end; return mh end
local lastClearF,clears,lastCleared,frame=0,0,0,0
local trace={}
local WAIT_D={type="WAIT"}; local decideCalls=0
local t0=os.clock()
while not s:game_ended() do  -- NO cap: run until the bot actually dies
  local st=BoardState.extract(s)
  local d; if ctrl:isBusy() then d=WAIT_D else d=brain:decide(st,s,m); decideCalls=decideCalls+1 end  -- only verify when the controller needs a NEW move
  local ch=ctrl:nextInput(st,d)
  s:receiveConfirmedInput(ch); m:run(); frame=frame+1
  local pc=s.panels_cleared or 0
  if pc>lastCleared then clears=clears+1; lastClearF=frame; lastCleared=pc end
  trace[frame]={h=tallest(), d=(d.type or "?"), pc=pc, sw=(s.swapCount or 0), cr=s.cur_row, cc=s.cur_col,
    tr=(d.pos and d.pos[1] or 0), tc=(d.pos and d.pos[2] or 0)}
  if frame>300 then trace[frame-300]=nil end  -- ring buffer: bound memory on long runs
  if frame%600==0 then local el=os.clock()-t0
    io.write(string.format("  ..f%d (%.0fs game) h=%-2d cleared=%d | sim %.0f fps = %.2fx realtime\n", frame, frame/60, tallest(), lastCleared, frame/el, frame/el/60)); io.flush() end
end
local elapsed=os.clock()-t0
print(string.format("SPEED: %d frames in %.1fs = %.0f fps (%.2fx realtime) | decided %d times = %.0f%% of frames (%.1fx fewer verifies)", frame, elapsed, frame/elapsed, frame/elapsed/60, decideCalls, 100*decideCalls/frame, frame/math.max(1,decideCalls)))
-- death board
local hs={}; local maxh,minh=0,99
for c=1,6 do hs[c]=0; for r=#s.panels,1,-1 do local p=s.panels[r][c]; if p and ((p.color or 0)~=0 or p.isGarbage) then hs[c]=r; break end end
  if hs[c]>maxh then maxh=hs[c] end; if hs[c]<minh then minh=hs[c] end end
print(string.format("seed %d: SURVIVED %d f (%.1fs)  cleared=%d in %d events (1 every %.1fs)", SEED, frame, frame/60, lastCleared, clears, clears>0 and frame/clears/60 or 0))
print(string.format("  death board cols=[%s]  tallest=%d  spread=%d", table.concat(hs,","), maxh, maxh-minh))
print("  death board colors (top row first):")
for r=math.min(#s.panels,12),1,-1 do local row={} for c=1,6 do local p=s.panels[r][c]; row[c]=(p and p.isGarbage and "G") or (p and tostring(p.color or 0)) or "." end print("    r"..r.."  "..table.concat(row," ")) end
print(string.format("  last clear @f%d -> died %d f (%.1fs) later  => %s", lastClearF, frame-lastClearF, (frame-lastClearF)/60, (frame-lastClearF)>120 and "STALLED" or "clearing till death"))
print("  --- final 80 frames (sampled every 8): height / brain-decision / state / totalCleared ---")
for f=math.max(1,frame-100),frame do if f%6==0 or f==frame then local t=trace[f]; if t then print(string.format("   f%-5d h=%-2d decide=%-5s target=(%d,%d) cursor=(%d,%d) swapCount=%d cleared=%d", f, t.h, t.d, t.tr, t.tc, t.cr, t.cc, t.sw, t.pc)) end end end
