-- How many actions a CPU may press within a rolling window of frames. The limit belongs to the game: ComputerPlayer
-- applies it to every implementation the same way, so no CPU wins by pressing faster than the field.
--
-- An action is what the game's APM display counts: a direction or swap key going down. A held direction is one action
-- however far the repeat carries the cursor, so a CPU pays what a person holding the key pays. A window rather than an
-- even rhythm lets a CPU spend its allowance in a burst and then wait, the way people play.
local KeyDataEncoding = require("common.data.KeyDataEncoding")

---@class InputBudget
---@field limit integer
---@field window integer
---@field spent integer[] the frame each unexpired input was spent on, oldest first, at indices oldest to newest
---@field oldest integer index of the oldest entry still inside the window
---@field newest integer index of the most recent entry
---@field held table<integer, boolean> which keys the last input pressed, by bit
local InputBudget = {}
InputBudget.__index = InputBudget

-- The keys the display counts, by their position in a decoded input: swap, up, down, left, right.
-- Raise is not an action to the display and is not one here.
local COUNTED_KEYS = {2, 3, 4, 5, 6}

-- how many frames the game runs in a minute, which is what actions per minute is measured against
local FRAMES_PER_MINUTE = 60 * 60
-- The limit every computer player plays under: every solution recorded with the game's puzzles fits inside it with five
-- percent to spare. Ten seconds is long enough to spend everything on one flurry and too short to bank a match's worth.
local STANDARD_ACTIONS_PER_MINUTE = 456
InputBudget.STANDARD_WINDOW_FRAMES = 600

---@param limit integer how many actions may be spent within any window
---@param window integer the length of that window in frames
---@return InputBudget
function InputBudget.new(limit, window)
  ---@type InputBudget
  local budget = {limit = limit, window = window, spent = {}, oldest = 1, newest = 0, held = {}}

  return setmetatable(budget, InputBudget)
end

---A budget written the way the game reports a player's rate.
---@param actionsPerMinute number the sustained ceiling
---@param window integer how many frames of that allowance may be spent at once
---@return InputBudget
function InputBudget.forActionsPerMinute(actionsPerMinute, window)
  return InputBudget.new(math.floor(actionsPerMinute * window / FRAMES_PER_MINUTE), window)
end

-- Drops the inputs that have rolled out of the window. Entries are spent in frame order and expire
-- in the same order, so this only ever walks off the front.
---@param clock integer
function InputBudget:forget(clock)
  while self.spent[self.oldest] and clock - self.spent[self.oldest] >= self.window do
    self.spent[self.oldest] = nil
    self.oldest = self.oldest + 1
  end
end

---How many inputs may still be pressed on this frame.
---@param clock integer
---@return integer
function InputBudget:remaining(clock)
  self:forget(clock)

  return math.max(0, self.limit - self:count())
end

---Whether an input may be pressed on this frame.
---@param clock integer
---@return boolean
function InputBudget:allows(clock)
  return self:remaining(clock) > 0
end

---Records an input pressed on this frame.
---@param clock integer
function InputBudget:spend(clock)
  self:forget(clock)
  if self.oldest > self:count() then
    self:compact()
  end
  self.newest = self.newest + 1
  self.spent[self.newest] = clock
end

---Moves the entries still inside the window to the front of spent, so its indices stay within what the window holds
---instead of growing with the match. Spend does it once the expired slots outnumber the live ones, so it costs a
---constant per spend on average.
function InputBudget:compact()
  local spent, count = self.spent, self:count()
  for index = 1, count do
    spent[index] = spent[self.oldest + index - 1]
  end
  for index = count + 1, self.newest do
    spent[index] = nil
  end
  self.oldest, self.newest = 1, count
end

---Charges the actions in one frame's input: every counted key that is down now and was not down
---on the frame before. A key still held from the frame before costs nothing more, however far the
---repeat carries the cursor, which is the display's rule.
---@param input string one encoded frame of input
---@param clock integer
function InputBudget:press(input, clock)
  local keys = KeyDataEncoding.base64decode[input] or KeyDataEncoding.base64decode[KeyDataEncoding.idle]
  for _, bit in ipairs(COUNTED_KEYS) do
    if keys[bit] and not self.held[bit] then
      self:spend(clock)
    end
    self.held[bit] = keys[bit]
  end
end

-- how many inputs are currently inside the window
---@return integer
function InputBudget:count()
  return self.newest - self.oldest + 1
end

---How many frames ago each input still inside the window was spent, oldest first: the window as
---a watcher is shown it.
---@param clock integer
---@param into integer[]? a list to fill rather than make, for a caller that asks every frame
---@return integer[]
function InputBudget:ages(clock, into)
  self:forget(clock)
  local ages = into or {}
  local count = self:count()
  for index = 1, count do
    ages[index] = clock - self.spent[self.oldest + index - 1]
  end
  for index = #ages, count + 1, -1 do
    ages[index] = nil
  end

  return ages
end

---The limit every computer player plays under, in any arena.
---@return InputBudget
function InputBudget.standard()
  return InputBudget.forActionsPerMinute(STANDARD_ACTIONS_PER_MINUTE, InputBudget.STANDARD_WINDOW_FRAMES)
end

return InputBudget
