-- Climbs straight up, digging, until it's in open air well above the ground:
-- for finding a lost turtle. Drinks lava sources with a bucket for fuel and
-- drops stone when its inventory is full. Logs what it passes, so the change
-- from deepslate to stone (around y 0) and the surface show how deep it was.
--
-- Usage: climb [air]   stop after this many open blocks above the last
--                      solid one (default 24)

local AIR = tonumber((...)) or 24
local JUNK = { "cobble", "deepslate", "stone", "dirt", "gravel", "tuff", "andesite", "diorite", "granite" }

local function isJunk(name)
  if name:find("ore", 1, true) or name:find("redstone", 1, true) then return false end
  for _, w in ipairs(JUNK) do if name:find(w, 1, true) then return true end end
  return false
end

local function makeRoom()
  if turtle.getItemCount(16) == 0 then
    local free = 0
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then free = free + 1 end end
    if free > 1 then return end
  end
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and isJunk(d.name) then turtle.select(s) turtle.dropDown() end
  end
  turtle.select(1)
end

local function drinkLava()
  local ok, b = turtle.inspectUp()
  if not (ok and b.name == "minecraft:lava" and b.state and b.state.level == 0) then return end
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == "minecraft:bucket" then
      turtle.select(s)
      if turtle.placeUp() then turtle.refuel() print("Drank lava: fuel " .. turtle.getFuelLevel()) end
      turtle.select(1)
      return
    end
  end
end

local climbed, air, last = 0, 0, nil
while air < AIR do
  if turtle.getFuelLevel() == 0 then
    print(("Out of fuel after %d up"):format(climbed))
    break
  end
  drinkLava()
  local ok, b = turtle.inspectUp()
  if ok and not (b.state and b.state.level) then
    if b.name:find("computercraft:", 1, true) then print("A computer is above me; stopping") break end
    if b.name ~= last then print(("+%d: %s"):format(climbed + 1, b.name)) last = b.name end
    for _ = 1, 32 do
      if not turtle.digUp() then break end
      if not turtle.detectUp() then break end
    end
    air = 0
  else
    air = air + 1
  end
  makeRoom()
  if not turtle.up() then
    print(("Can't go up after %d"):format(climbed))
    break
  end
  climbed = climbed + 1
end
print(("Climbed %d blocks; fuel %d"):format(climbed, turtle.getFuelLevel()))
return climbed
