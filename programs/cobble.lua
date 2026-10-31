-- Cobblestone generator turtle for the factory (phase 2).
--
-- A mining turtle faces the spot where a lava/water generator forms
-- cobblestone (a second generator above it doubles the output). It digs
-- whatever forms there and drops it into the chest below, which sits on the
-- factory's wired network, so the furnaces turn it into stone.
--
-- It never moves and needs no fuel. It only ever digs cobblestone or stone,
-- and pauses while the chest is full so nothing spills on the ground.
--
-- Usage: cobble [up]   ("up" also mines a second generator above the turtle;
--                       off by default so it never touches a stone ceiling)

local MINEABLE = { ["minecraft:cobblestone"] = true, ["minecraft:stone"] = true }
local SIDES = { { name = "front", inspect = turtle.inspect, dig = turtle.dig } }
if ... == "up" then
  SIDES[2] = { name = "above", inspect = turtle.inspectUp, dig = turtle.digUp }
end
local REPORT_EVERY = 640 -- blocks
local FULL_WAIT = 30     -- seconds between checks while the chest is full

if not peripheral.hasType("bottom", "inventory") then
  error("No chest below the turtle. The cobble goes into a chest on the factory network.", 0)
end

local mined = 0
local said -- last status line, so waiting messages print once

local function say(msg)
  if msg ~= said then print(msg) end
  said = msg
end

-- Drops everything into the chest below. Returns false if it is full.
local function unload()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      if not turtle.dropDown() then
        turtle.select(1)
        return false
      end
    end
  end
  turtle.select(1)
  return true
end

say("Cobble generator running")
while true do
  if not unload() then
    say("Chest below is full, waiting")
    sleep(FULL_WAIT)
  else
    local dug, problem = false, nil
    for _, side in ipairs(SIDES) do
      local ok, block = side.inspect()
      if ok and MINEABLE[block.name] then
        local done, err = side.dig()
        if done then
          dug = true
          mined = mined + 1
          if mined % REPORT_EVERY == 0 then print(("Mined %d cobblestone"):format(mined)) end
        else
          problem = ("Can't dig %s: %s"):format(side.name, tostring(err))
        end
      end
    end
    if problem then
      say(problem)
      sleep(FULL_WAIT)
    elseif dug then
      said = nil -- so the next wait gets reported again
    else
      if mined == 0 then say("No cobblestone in front or above yet, waiting") end
      sleep(0.5)
    end
  end
end
