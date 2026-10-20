-- One-time setup for the stationary farm (see farm.lua): tills the dirt under
-- the four crop spots.
--
-- A hoe only tills dirt with air directly above it, so the turtle can't till
-- the dirt from on top of it. Instead, for each side it goes two blocks out,
-- digs down next to the dirt, tills it from the side, puts the dug-out block
-- back and returns home.
--
-- Needs: the hoe equipped on the right, a pickaxe or shovel in the inventory
-- (swapped in for the crafting table during setup), ~6 fuel per side.
--
-- Usage: setupfarm [test]   ("test" stops after the first side)

local testOnly = ... == "test"

local function findSlot(match)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and match(d.name) then return s end
  end
end

local function counts()
  local c = {}
  for s = 1, 16 do c[s] = turtle.getItemCount(s) end
  return c
end

-- Moves, retrying for a while if a player or mob is in the way.
local function move(fn, what)
  for _ = 1, 20 do
    if fn() then return end
    sleep(1)
  end
  error("Blocked while trying to move " .. what .. ", stopping here", 0)
end

local function ensureFuel(needed)
  if turtle.getFuelLevel() == "unlimited" then return end
  while turtle.getFuelLevel() < needed do
    local s = findSlot(function(n) return n == "minecraft:coal" or n == "minecraft:charcoal" end)
    if not s then error("Not enough fuel: put coal in the turtle", 0) end
    turtle.select(s)
    turtle.refuel(1)
  end
end

-- Tills the block in front with the equipped hoe, falling back to using the
-- hoe as an item (like a player right-click) if digging doesn't till.
local function tillFront()
  turtle.dig("right")
  local _, b = turtle.inspect()
  if b.name == "minecraft:farmland" then return true end

  local empty
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then empty = s break end end
  if not empty then return false, "no empty slot to unequip the hoe into" end
  turtle.select(empty)
  turtle.equipRight()
  turtle.place()
  turtle.select(empty)
  turtle.equipRight()
  _, b = turtle.inspect()
  return b.name == "minecraft:farmland", b.name
end

-- Handles the side the turtle is facing. Returns a description of what happened.
local function tillSide()
  local ok, front = turtle.inspect()
  if ok then return "skipped (" .. front.name .. " in the crop spot)" end

  ensureFuel(6)
  move(turtle.forward, "into the crop spot")
  move(turtle.forward, "past the crop spot")

  local hadBlock, below = turtle.inspectDown()
  if hadBlock and below.name:find("water") or hadBlock and below.name:find("lava") then
    move(turtle.back, "back")
    move(turtle.back, "home")
    return "skipped (" .. below.name .. " where I need to dig)"
  end

  local before = counts()
  if hadBlock and not turtle.digDown() then
    move(turtle.back, "back")
    move(turtle.back, "home")
    return "skipped (can't dig " .. below.name .. ")"
  end
  local dugSlot
  for s = 1, 16 do
    if turtle.getItemCount(s) > before[s] then dugSlot = s break end
  end

  move(turtle.down, "down next to the dirt")
  turtle.turnLeft()
  turtle.turnLeft()

  local _, dirt = turtle.inspect()
  local result
  if dirt.name == "minecraft:farmland" then
    result = "already farmland"
  else
    local tilled, what = tillFront()
    result = tilled and ("tilled " .. dirt.name) or ("FAILED to till " .. tostring(dirt.name) .. " (" .. tostring(what) .. ")")
  end

  move(turtle.up, "back up")
  if dugSlot then
    turtle.select(dugSlot)
    turtle.placeDown()
  end
  move(turtle.forward, "into the crop spot")
  move(turtle.forward, "home")
  turtle.turnLeft()
  turtle.turnLeft()
  return result
end

-- Swap the crafting table (left) for the digging tool.
local tool = findSlot(function(n) return n:find("pickaxe") or n:find("shovel") end)
if not tool then error("Put a pickaxe or shovel in the turtle first", 0) end
turtle.select(tool)
turtle.equipLeft()
print("Equipped digging tool, crafting table is in the inventory")

local results = {}
local okAll, err = pcall(function()
  for i = 1, 4 do
    local r = tillSide()
    results[i] = r
    print("Side " .. i .. ": " .. r)
    if testOnly or r:find("FAILED") then break end
    turtle.turnLeft()
  end
end)

-- Swap the crafting table back, whatever happened.
local table_ = findSlot(function(n) return n == "minecraft:crafting_table" end)
if table_ then
  turtle.select(table_)
  turtle.equipLeft()
  print("Crafting table re-equipped, digging tool is back in the inventory")
end

if not okAll then error(err, 0) end
return results
