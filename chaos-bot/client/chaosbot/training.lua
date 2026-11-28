-- THE CHAOS v3 TRAINING PATTERNS, copied verbatim from the chaos client (client/src/scenes/TrainingMenu.lua, lines 28-258: getNextTime,
-- getNextChain, getNextCombo, createBasicTrainingMode), where they are local and so out of reach. Drawn from math.random: seeded
-- (math.randomseed) before make, the same pattern every time.
local M = {}
local function getNextTime(width, height, multi, speed, match, pop)
  local height_time = (height * (height + 1)) / 2
  local delayKey = ((match * height) + (width * height_time * pop)) * multi
  return delayKey * (speed * (1 + math.random(-250, 250) / 1000)) + 1
end

local function getNextChain(number, name, difficulty)
  local height = 1
  local min_height
  local max_height
  local min_opening_height = math.ceil(difficulty / 3)
  local max_opening_height = min_opening_height + (min_opening_height * ((difficulty - 1) % 3)) + 1
  local value1
  local rand = math.random()
  local sum1 = 0
  local counter1 = 0

  if number <= 2 then -- opening chains
    if name == "" or name == loc("combo_storm") or name == loc("thicc_combo_storm") or name == loc("insane_combo_storm") then
      -- overrides for combo storms and custom garbage sizes
      min_opening_height = 1
      max_opening_height = math.ceil(difficulty / 3)
    end
    height = min_opening_height
    -- probability
    for i = 1, max_opening_height - min_opening_height + 1 do
      sum1 = sum1 + 1 * ((1 + math.sqrt(5)) / 2) ^ (i - 1)
    end
    value1 = 1 - (1 * ((1 + math.sqrt(5)) / 2) ^ (max_opening_height - counter1 - min_opening_height)) / sum1
    while value1 < rand and (max_opening_height - counter1 - min_opening_height) > 0 do
      height = height + 1
      counter1 = counter1 + 1
      value1 = 1 - (1 * ((1 + math.sqrt(5)) / 2) ^ (max_opening_height - counter1 - min_opening_height)) / sum1
    end
  else
    min_height = 1
    max_height = math.random(math.ceil((difficulty + 1) / 2))
    -- overrides for factory and large garbage
    if name == loc("large_garbage") then
      min_height = math.ceil(difficulty / 4)
      max_height = min_height + ((difficulty - 1) % 4) + 1
    end
      height = min_height
    -- probability
    for i = 1, max_height - min_height + 1 do
      sum1 = sum1 + 1 * ((1 + math.sqrt(5)) / 2) ^ (i - 1)
    end
    value1 = 1 - (1 * ((1 + math.sqrt(5)) / 2) ^ (max_height - counter1 - min_height)) / sum1
    while value1 < rand and (max_height - counter1 - min_height) > 0 do
      height = height + 1
      counter1 = counter1 + 1
      value1 = 1 - (1 * ((1 + math.sqrt(5)) / 2) ^ (max_height - counter1 - min_height)) / sum1
    end
  end
  return height
end

local function getNextCombo()
  local min_width = 3
  local max_width = 5
  local width = min_width
  local rand = math.random()
  local sum1 = 0
  local counter1 = 0
  -- probability
  for i = 1, max_width - min_width + 1 do
    sum1 = sum1 + 1 * ((1 + math.sqrt(5)) / 2) ^ (i - 1)
  end
  local value1 = 1 - (1 * ((1 + math.sqrt(5)) / 2) ^ (max_width - counter1 - min_width)) / sum1
  while value1 < rand and (max_width - counter1 - min_width) > 0 do
    width = width + 1
    counter1 = counter1 + 1
    value1 = 1 - (1 * ((1 + math.sqrt(5)) / 2) ^ (max_width - counter1 - min_width)) / sum1
  end
  return width
end

-- garbage randomizer
local function createBasicTrainingMode(name, width, height, difficulty, garbage_speed, queue_type)
  local delayBeforeStart = math.random(210, 360)
  local attacksPerVolley = 1
  local delayBeforeRepeat
  local attackPatterns = {}
  local GarbageQueueType = queue_type
  local ChaosMode = false
  -- (QUEUE LIMIT, the launcher's CHAOSBOT_QLIMIT=1 -- the owner's mode table: the attack engine's limit on, so a pattern sends only while
  -- six or fewer of its attacks are in transit (AttackEngine.lua); off, as a training pattern has it, by default)
  local disableQueueLimit = os.getenv("CHAOSBOT_QLIMIT") ~= "1"
  -- set the pattern name in the replay correctly
  local patternName = tostring(name .. " - Difficulty " .. difficulty .. "-" .. garbage_speed)
  if name == "" then
    patternName = tostring("Custom " .. width .. "x" .. height .. " - Difficulty " .. difficulty)
  end

  if math.random() < 0.25 then
    ChaosMode = true
  end
  local ChainStartTime = math.random(120, 300)
  local ComboStartTime = math.random(300)
  local timeLimit = 10 * 60 * 60 -- loop time in minutes
  local chain_line_count = 0
  local combo_line_count = 0
  local speed_modifier = (3.25 - 0.25 * garbage_speed)
  local chainSpeed
  local comboSpeed
  local baseTargetGPM = 10 + 2 * garbage_speed
  local chainTargetGPM
  local comboTargetGPM
  local match = 46
  local pop = 7
  local bias_direction = 1
  if math.random() < 0.5 then
    bias_direction = -1
  end

  -- sets garbage speeds and biases
  local bias = bias_direction * (math.random(1000, 4000) / 1000)
  if bias < 0 then -- combo heavy
    comboSpeed = speed_modifier
    chainSpeed = speed_modifier * math.abs(bias)
  else -- chain heavy or balanced
    chainSpeed = speed_modifier
    comboSpeed = speed_modifier * math.abs(bias)
  end

  if name == loc("large_garbage") then
    -- overrides for large garbage
    comboSpeed = speed_modifier * math.random(3000, 5000) / 1000
  elseif name == loc("factory") then
  -- overrides for factory
    comboSpeed = speed_modifier * math.random(2000, 4000) / 1000
  elseif name == "" or name == loc("combo_storm") or name == loc("thicc_combo_storm") or name == loc("insane_combo_storm") then
    -- overrides for combo storms and custom garbage sizes
    if name == loc("thicc_combo_storm") then
      -- chaos mode stays on only for thicc combo storm
      ChaosMode = true
    else
      ChaosMode = false
    end
    comboSpeed = 1
    chainSpeed = math.random(3000, 5000) / 1000
  end
  chainTargetGPM = baseTargetGPM * comboSpeed / (comboSpeed + chainSpeed)
  comboTargetGPM = baseTargetGPM * chainSpeed / (comboSpeed + chainSpeed)

  for i = 1, attacksPerVolley do
    -- chain garbage sends
    for chain_number = 1, 5000 do
      local chain_height = getNextChain(chain_number, name, difficulty)
      local ChainLink = 67
      if ChainStartTime < timeLimit then
        if chain_number >= 3 and chain_line_count * 3600 / (delayBeforeStart + ChainStartTime) > chainTargetGPM then
          ChainLink = ChainLink * 5
        end
        table.insert(attackPatterns, {width = 6, height = chain_height, startTime = ChainStartTime, metal = false, chain = ChainLink, endsChain = false})
        chain_line_count = chain_line_count + chain_height
        ChainStartTime = ChainStartTime +  math.max((ChainLink * (chain_height + 1)) + 1, math.ceil(getNextTime(6, chain_height, 1, chainSpeed, match, pop)))
      else
        break
      end
    end
    -- combo and metal garbage sends
    for combo_number = 1, 5000 do
      local combo_width = getNextCombo()
      local combo_height = 1
      local multi_chance = 0.025 * difficulty
      local metal_chance = 0.0625
      local isMetal = false
      local multi_combo = 1
      local combo_throttle = 424
      -- multi chance overrides for combo storms and custom garbage sizes
      if name == "" or name == loc("combo_storm") or name == loc("thicc_combo_storm") then
        multi_chance = 0.125 + 0.025 * difficulty
        if name == loc("insane_combo_storm") then
          metal_chance = 0.125 + 0.025 * difficulty
        end
        if name == "" then
          combo_width = width
          combo_height = height
        end
      end
      if math.random() < multi_chance then
        if ChaosMode then
          if name == loc("thicc_combo_storm") then
            -- override for thicc combo storm
            combo_height = math.random(math.ceil(difficulty / 3) + 1)
          else
            combo_height = 2
          end
        else
          if name == "" or name == loc("combo_storm") then
            -- overrides for normal combo storm and custom sizes
            multi_combo = math.random(math.ceil(difficulty / 3) + 1)
          else
            multi_combo = 2
          end
        end
      end
      -- metal chances
      if math.random() < metal_chance then
        if name ~= loc("insane_combo_storm") and ComboStartTime >= 3600 then
          combo_width = 6
          combo_height = 1
          isMetal = true
        elseif name == loc("insane_combo_storm") then
          isMetal = true
        end
      end
      if ComboStartTime < timeLimit then
        if ComboStartTime > 900 and combo_line_count * 3600 / (delayBeforeStart + ComboStartTime) > comboTargetGPM then
          ComboStartTime = ComboStartTime + combo_throttle
        end
        for multi = 1, multi_combo do
          table.insert(attackPatterns, {width = combo_width, height = combo_height, startTime = ComboStartTime, metal = isMetal, chain = false, endsChain = false})
        end
        combo_line_count = combo_line_count + (combo_width / 6) * combo_height * multi_combo
        if math.random() < 0.5 then
          ComboStartTime = ComboStartTime + math.ceil(getNextTime(combo_width, combo_height, multi_combo, comboSpeed, match, pop))
        else
          ComboStartTime = ComboStartTime + math.max(92, math.ceil(getNextTime(combo_width, combo_height, multi_combo, comboSpeed, match, pop)))
        end
      else
        break
      end
    end
  end
  delayBeforeRepeat = math.max(ChainStartTime, ComboStartTime) - timeLimit

  local customTrainingModeData = {patternName = patternName, delayBeforeStart = delayBeforeStart, delayBeforeRepeat = delayBeforeRepeat, GarbageQueueType = GarbageQueueType, ChaosMode = ChaosMode, disableQueueLimit = disableQueueLimit, attackPatterns = attackPatterns}

  return customTrainingModeData
end


M.make = createBasicTrainingMode
return M
