-- Stationary wheat farm for a crafty farming turtle (diamond hoe + crafting table).
--
-- Layout: the turtle sits on top of the output chest, with a buffer chest on
-- top of it and one wheat crop on each of its four sides (farmland one block
-- down, water in the four diagonal corners). It never moves, so it needs no fuel.
--
-- Each pass: harvest fully grown wheat (using any bone meal it has on growing
-- crops first), replant, bake bread (3 wheat each) and
-- drop bread plus surplus seeds into the chest below.
--
-- Usage: farm [seconds between passes | once]

local SEEDS = "minecraft:wheat_seeds"
local WHEAT = "minecraft:wheat"
local CROP = "minecraft:wheat"
local BONEMEAL = "minecraft:bone_meal"
local MAX_AGE = 7
local KEEP_SEEDS = 16

local arg1 = ...
local once = arg1 == "once"
local interval = tonumber(arg1) or 60
local canCraft = peripheral.find("workbench") ~= nil

local function findSlot(name)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then return s end
  end
end

local function count(name)
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then n = n + d.count end
  end
  return n
end

-- Tends the spot in front: harvests it when ripe, plants it when empty.
-- Returns "harvested", "planted", "growing", "no_seeds", "blocked" or "cant_plant".
local function tend()
  local harvested = false
  local ok, block = turtle.inspect()
  if ok then
    if block.name ~= CROP then return "blocked" end
    if (block.state and block.state.age or 0) < MAX_AGE then
      -- Speed it up with bone meal if we have some.
      local bm = findSlot(BONEMEAL)
      if not bm then return "growing" end
      turtle.select(bm)
      while turtle.getItemCount(bm) > 0 and turtle.place() do
        local _, b = turtle.inspect()
        if (b.state and b.state.age or 0) >= MAX_AGE then break end
      end
      local _, b = turtle.inspect()
      if (b.state and b.state.age or 0) < MAX_AGE then return "growing" end
    end
    turtle.dig()
    harvested = true

    -- On this server a mod replants the crop and pops the drops out as
    -- items, which only become collectable after ~0.5s.
    for _ = 1, 20 do
      turtle.suck()
      sleep(0.1)
    end
    if turtle.inspect() then return "harvested" end
  end

  local s = findSlot(SEEDS)
  if not s then return harvested and "harvested" or "no_seeds" end
  turtle.select(s)
  if turtle.place() then return harvested and "harvested" or "planted" end
  return harvested and "harvested" or "cant_plant"
end

-- Crafts as much bread as possible. Crafting needs an otherwise empty
-- inventory, so everything else is parked in the chest above meanwhile.
local function bakeBread()
  local n = math.min(64, math.floor(count(WHEAT) / 3))
  if n == 0 then return 0 end

  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name ~= WHEAT then
      turtle.select(s)
      turtle.dropUp()
    end
  end

  -- Gather the wheat in slots 13-16, outside the 3x3 crafting grid.
  for s = 1, 12 do
    for t = 13, 16 do
      if turtle.getItemCount(s) == 0 then break end
      turtle.select(s)
      turtle.transferTo(t)
    end
  end

  -- Lay out n wheat in each of slots 1, 2, 3 (the bread recipe), park the rest.
  for target = 1, 3 do
    local need = n
    for s = 13, 16 do
      local c = turtle.getItemCount(s)
      if need > 0 and c > 0 then
        local m = math.min(c, need)
        turtle.select(s)
        turtle.transferTo(target, m)
        need = need - m
      end
    end
  end
  for s = 4, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      turtle.dropUp()
    end
  end

  turtle.select(1)
  local ok, err = turtle.craft()
  if not ok then printError("Craft failed: " .. tostring(err)) end

  while turtle.suckUp() do end
  return ok and n or 0
end

-- Keeps KEEP_SEEDS seeds (and spare wheat if we can bake), drops the rest below.
local function store()
  local seedsLeft = KEEP_SEEDS
  local full = false
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then
      local drop = d.count
      if d.name == SEEDS then
        local keep = math.min(d.count, seedsLeft)
        seedsLeft = seedsLeft - keep
        drop = d.count - keep
      elseif (d.name == WHEAT and canCraft) or d.name == BONEMEAL then
        drop = 0
      end
      if drop > 0 then
        turtle.select(s)
        if not turtle.dropDown(drop) then full = true end
      end
    end
  end
  if full then printError("Output chest is full!") end
end

print(("Wheat farm: crafting %s, %s"):format(canCraft and "on" or "off (no crafting table)",
  once and "single pass" or "every " .. interval .. "s"))

while true do
  local counts = {}
  for _ = 1, 4 do
    local r = tend()
    counts[r] = (counts[r] or 0) + 1
    turtle.turnLeft()
  end
  local bread = canCraft and bakeBread() or 0
  store()

  local parts = {}
  for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
  table.sort(parts)
  print(("Pass: %s, bread=%d"):format(table.concat(parts, " "), bread))
  if counts.no_seeds then printError("Out of seeds: put wheat seeds in the turtle") end
  if counts.cant_plant then printError("Could not plant: is the ground hoed farmland?") end

  if once then return counts end
  sleep(interval)
end
