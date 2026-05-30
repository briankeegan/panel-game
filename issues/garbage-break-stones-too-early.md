# Garbage break: gray stones appear too early

**Reported:** Bramp, 5/26/26 playtest (chaos952's board screenshot)

## Symptom

On remote players' snapshot-rendered boards, the entire breaking garbage block shows as gray stone panels during the flash and face phases — before the canonical animation would reveal them.

## Diagnosis

The snapshot receiver's per-cell render for matched garbage is too greedy compared to the canonical local path.

### Canonical (`client/src/PlayerStack.lua:1328–1361`)

For `panel.state == "matched"` on a garbage cell:

```lua
local flash_time = panel.initial_time - panel.timer
if flash_time >= FLASH then
  if panel.timer > panel.pop_time then
    -- FACE: draw garbageCharacter.images.pop per cell
  elseif panel.y_offset == -1 then
    -- POP, bottom row ONLY: panelSet:addToDraw (reveals color)
  end
  -- POP, non-bottom rows: draw nothing per-cell
else
  -- FLASH: alternate flash sprite / pop sprite per cell
end
```

Plus the slab (line 1311): drawn when `state ~= "matched"` OR `timer <= pop_time`.

### Snapshot receiver (`client/src/network/DisplayClientStack.lua:543–546`)

```lua
if panel.state == "matched" and frameTimes then
  panelSet:addToDraw(panel, ...)
end
```

Unconditional `addToDraw` for every matched garbage cell in every sub-phase. `Panels:addToDraw` for `color == 9` paints `greyPanel` (`client/src/mods/Panels.lua:632–646`) → stone panels show during the entire matched window.

The slab condition on the snapshot path (lines 527–540) already matches canonical and is fine.

### Why it isn't the 20Hz smoothing

The data on the wire is sufficient — `state`, `timer`, `initial_time`, `pop_time`, `y_offset`, `isGarbage`, `color` are all shipped (`DisplayEventCapture.lua:111–145`). Even with perfectly fresh snapshots at 60Hz, this render path would still show stones during flash/face because the conditional is wrong.

## Fix

Replace lines 543–546 in `DisplayClientStack.lua` with the canonical flash_time / face / bottom-row-only branching. All required inputs are already in scope:

- `panel.initial_time`, `panel.timer`, `panel.pop_time`, `panel.y_offset` — from `expandCell`
- `frameTimes.FLASH` — already pulled at line 496
- `garbageCharacter.images.flash` / `.images.pop` — `garbageCharacter` resolved at line 503
- `metalPanelSet.images.metals.flash` / `.left` / `.right` — already resolved at line 505
- `shouldFlashForFrame()` — local function in `PlayerStack.lua:1283`; either lift to a shared module or inline the 2-line helper

Sketch:

```lua
if panel.state == "matched" and frameTimes and panel.initial_time and panel.timer then
  local flash_time = panel.initial_time - panel.timer
  if flash_time >= frameTimes.FLASH then
    if panel.pop_time and panel.timer > panel.pop_time then
      -- FACE: draw pop sprite per cell (metal or character)
    elseif panel.y_offset == -1 then
      panelSet:addToDraw(panel, draw_x, draw_y, viewStack.gfxScale,
        dangerCol, dangerTimer, snapshot.st or 0)
    end
  else
    if shouldFlashForFrame(flash_time) then
      -- draw flash sprite per cell
    else
      -- draw pop sprite per cell
    end
  end
end
```

`drawGfxScaled` is `PlayerStack`-local; the snapshot path will need its own equivalent (plain `love.graphics.draw` with the same scale math should work — no stack-relative offsets needed since draw coords are already computed).

## Test plan

- FFA match with broadcast garbage so every remote board takes attacks
- Verify on the receiver: garbage cells flash white, then show faces, then pop in sequence — matching the sender's view
- Verify heavy/stone garbage: final resolved gray panels still render correctly after the pop completes
- Verify metal garbage break renders the same on remote as on local
