-- Outcome-reward extraction for self-play RL (DATA_CONTRACT §18). Reads what the
-- match produced OFF THE STACK — garbage dealt/taken + survival. Strictly outcome,
-- zero strategy: the policy learns WHEN to combo/chain from the player + what wins,
-- this only measures the result.
--
-- Also a human-readable readout of the blocks a stack actually sent (combo vs
-- chain vs metal, and size), for inspecting what a bot does.

local Reward = {}

local function hist(stack)
  return stack and stack.outgoingGarbage and stack.outgoingGarbage.history or {}
end

-- every garbage piece this stack SENT: { kind = combo|chain|metal, w, h }
-- combo = flat block (width = combo size); chain = isChain (height grows with the
-- chain); metal = shock/metal bar. isMetal/isChain are mutually exclusive.
function Reward.outgoingBlocks(stack)
  local out = {}
  for _, g in ipairs(hist(stack)) do
    out[#out + 1] = {
      kind = g.isMetal and "metal" or (g.isChain and "chain" or "combo"),
      w = g.width, h = g.height,
    }
  end
  return out
end

-- compact one-line readout, e.g.
--   "6 sent | combo x4 [6x1,4x1,3x1,5x1]  chain x2 [6x2,6x3]"
function Reward.summary(stack)
  local blocks = Reward.outgoingBlocks(stack)
  if #blocks == 0 then return "0 sent" end
  local order, byKind = {}, {}
  for _, b in ipairs(blocks) do
    if not byKind[b.kind] then byKind[b.kind] = {}; order[#order + 1] = b.kind end
    byKind[b.kind][#byKind[b.kind] + 1] = b.w .. "x" .. b.h
  end
  local parts = {}
  for _, k in ipairs(order) do
    parts[#parts + 1] = string.format("%s x%d [%s]", k, #byKind[k], table.concat(byKind[k], ","))
  end
  return string.format("%d sent | %s", #blocks, table.concat(parts, "  "))
end

-- ===== scalar outcome-reward components (read each frame / at terminal) =====

-- garbage dealt: count of pieces sent (optionally weighted by area; chains hit
-- harder so area is a fair proxy for damage).
function Reward.dealt(stack, byArea)
  local n = 0
  for _, g in ipairs(hist(stack)) do
    n = n + (byArea and (g.width * g.height) or 1)
  end
  return n
end

-- garbage taken: total pieces ever aimed at this stack (staged + in-transit +
-- already absorbed). incomingGarbage drains as garbage lands, so we track the
-- cumulative count the queue has seen via its own history if present, else the
-- live queue size. Caller diffs across frames for a per-frame penalty.
function Reward.taken(stack, byArea)
  local iq = stack and stack.incomingGarbage
  if not iq then return 0 end
  local n = 0
  local function add(list) for _, g in ipairs(list or {}) do n = n + (byArea and (g.width * g.height) or 1) end end
  if iq.history then add(iq.history); return n end
  add(iq.stagedGarbage)
  for _, pieces in pairs(iq.garbageInTransit or {}) do add(pieces) end
  return n
end

-- alive this frame? (engine sentinel: game_over_clock == -1 is ALIVE)
function Reward.alive(stack)
  return (stack.game_over_clock or -1) <= 0
end

-- terminal outcome for a finished stack: +1 win (opponent died first), -1 loss.
function Reward.outcome(stack, opponentStack)
  local meDead = (stack.game_over_clock or -1) > 0
  local oppDead = (opponentStack.game_over_clock or -1) > 0
  if oppDead and not meDead then return 1 end
  if meDead and not oppDead then return -1 end
  return 0 -- mutual / unfinished
end

-- net outcome reward = dealt - taken (area-weighted) + terminal win/loss bonus.
-- Pure outcome: no per-tactic shaping (DATA_CONTRACT §18).
function Reward.net(stack, opponentStack, winBonus)
  return Reward.dealt(stack, true) - Reward.taken(stack, true)
    + (Reward.outcome(stack, opponentStack) * (winBonus or 0))
end

return Reward
