-- First job of a newborn cobble turtle: build a cobblestone generator on top
-- of the factory, then become the cobble turtle (programs/cobble.lua).
--
-- The turtle starts on the birth spot B in front of the factory F, with a
-- lava bucket, a water bucket and cobblestone. Coordinates are relative to
-- B; z points away from the factory and x to the right, seen from F.
--
-- Side view (looking along x):     Top view of the build layer (y=2):
--      z: -1  0                        x: -2 -1  0  1  2  3
--   y=2   S  [C]   S = seat            z=1    #  #  #  #  #
--   y=1   I   #    I = input chest     z=0 #  L  C  w  W  #
--   y=0   F   B    F = factory         z=-1   #  S  #  #
--
-- L lava, C where cobble forms, w empty above a 1-block hole, W water, # a
-- solid block (placed only where there is air). The turtle ends up on S,
-- on top of the input chest, facing C, and drops its cobble into the chest.
--
-- A 3x3 lid at y=3 covers L and everything around it: lava starts fires by
-- reaching up into air within a block of it, and the lid leaves it none.
--
-- It never digs while building: if a cell it must pass through is taken,
-- it stops and says where.

local STATE = "/.cobblesetup"
local COBBLE = "minecraft:cobblestone"
local FLUIDS = { ["minecraft:water"] = true, ["minecraft:lava"] = true }
-- Not walls: water and lava flow through these, and a block placed there replaces them.
local SOFT = {
  ["minecraft:snow"] = true, ["minecraft:short_grass"] = true, ["minecraft:tall_grass"] = true,
  ["minecraft:fern"] = true, ["minecraft:large_fern"] = true, ["minecraft:dead_bush"] = true,
  ["regions_unexplored:frozen_grass"] = true,
}
local FACTORY = { ["computercraft:turtle_normal"] = true, ["computercraft:turtle_advanced"] = true }

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local pos = { x = 0, y = 0, z = 0 }
local dir = 0

local function fail(msg) error(msg, 0) end

local function where(x, y, z) return ("(%d,%d,%d)"):format(x, y, z) end

if fs.exists(STATE) then
  fail("A previous setup was interrupted part-way, so this turtle no longer knows where it is. It needs a hand.")
end

local function turnTo(d)
  while dir ~= d do
    turtle.turnRight()
    dir = (dir + 1) % 4
  end
end

-- Faces away from the factory: the newborn may come out facing either way.
local function orient()
  for _ = 1, 4 do
    local ok, block = turtle.inspect()
    if ok and FACTORY[block.name] then
      turtle.turnRight()
      turtle.turnRight()
      return
    end
    turtle.turnRight()
  end
  fail("Can't find the factory turtle next to me; was I placed by it?")
end

local function blockedBy(inspect)
  local ok, block = inspect()
  return ok and block.name or "something"
end

local function step(d)
  local x, y, z = pos.x, pos.y, pos.z
  local ok
  if d == "up" then
    ok = turtle.up()
    y = y + 1
  elseif d == "down" then
    ok = turtle.down()
    y = y - 1
  else
    turnTo(d)
    ok = turtle.forward()
    x, z = x + DX[d], z + DZ[d]
  end
  if not ok then
    local inspect = d == "up" and turtle.inspectUp or d == "down" and turtle.inspectDown or turtle.inspect
    fail(("Can't move to %s: %s is in the way"):format(where(x, y, z), blockedBy(inspect)))
  end
  pos.x, pos.y, pos.z = x, y, z
end

local function selectItem(name)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Makes the neighbouring cell (x,y,z) solid, placing cobblestone only if it
-- is air or fluid. Anything solid already there is left alone.
local function solid(x, y, z)
  local inspect, place
  if y == pos.y + 1 then
    inspect, place = turtle.inspectUp, turtle.placeUp
  elseif y == pos.y - 1 then
    inspect, place = turtle.inspectDown, turtle.placeDown
  else
    for d = 0, 3 do
      if pos.x + DX[d] == x and pos.z + DZ[d] == z then turnTo(d) end
    end
    inspect, place = turtle.inspect, turtle.place
  end
  local ok, block = inspect()
  if ok and not FLUIDS[block.name] and not SOFT[block.name] then return end
  if not selectItem(COBBLE) then fail("Ran out of cobblestone at " .. where(x, y, z)) end
  if not place() then fail("Couldn't place a block at " .. where(x, y, z)) end
end

local function pour(bucket, d)
  turnTo(d)
  if not selectItem(bucket) then fail("No " .. bucket) end
  if not turtle.place() then fail("Couldn't pour the " .. bucket) end
end

if not selectItem("minecraft:lava_bucket") or not selectItem("minecraft:water_bucket") then
  fail("I need a lava bucket and a water bucket")
end

orient()
-- From here on the turtle moves; a reboot would leave it lost.
local h = fs.open(STATE, "w")
h.write("building")
h.close()
print("Building the cobble generator")
step("up")                 -- (0,1,0)
solid(-1, 1, 0)            -- floor under L
step("up")                 -- C (0,2,0)
solid(0, 1, 0)             -- floor under C
solid(0, 2, 1)
step(3)                    -- L (-1,2,0)
solid(-2, 2, 0)
solid(-1, 2, 1)
solid(-1, 2, -1)
step(1)                    -- C
step(1)                    -- w (1,2,0)
solid(1, 2, 1)
solid(1, 2, -1)
step("down")               -- the hole (1,1,0)
solid(1, 1, 1)
solid(1, 1, -1)
solid(1, 0, 0)
step("up")                 -- w
step(1)                    -- W (2,2,0)
solid(2, 2, 1)
solid(2, 2, -1)
solid(3, 2, 0)
solid(2, 1, 0)
step(3)                    -- w
step(3)                    -- C
step("up")                 -- (0,3,0), a lid cell
step("up")                 -- (0,4,0): walk round above the lid, placing it
solid(0, 3, 0)
step(0)  solid(0, 3, 1)    -- (0,4,1)
step(3)  solid(-1, 3, 1)   -- (-1,4,1)
step(3)  solid(-2, 3, 1)   -- (-2,4,1)
step(2)  solid(-2, 3, 0)   -- (-2,4,0)
step(2)  solid(-2, 3, -1)  -- (-2,4,-1)
step(1)  solid(-1, 3, -1)  -- (-1,4,-1)
step(1)  solid(0, 3, -1)   -- (0,4,-1), above the seat
step(3)                    -- (-1,4,-1)
step(0)                    -- (-1,4,0)
step("down")               -- (-1,3,0), the last lid cell
step("down")               -- L
solid(-1, 3, 0)
step(1)                    -- C
step(1)                    -- w
pour("minecraft:water_bucket", 1) -- into W; it flows into the hole once we leave
step(3)                    -- C
pour("minecraft:lava_bucket", 3)  -- into L
turnTo(0)
if not turtle.back() then fail("Can't back onto the seat above the input chest " .. where(0, 2, -1)) end
pos.z = -1

fs.delete(STATE)
print("Generator built; switching to the cobble program")
local auto = fs.open("/.agent/autorun", "w")
auto.write(textutils.serialise({ program = "cobble", args = {} }))
auto.close()
os.reboot()
