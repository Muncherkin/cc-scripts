-- Pine farm turtle (phase 3): a mining turtle with a chunk controller,
-- born on the factory's birth spot. It plants saplings on a few spots east of
-- the factory, chops the pines that grow there, replants, and brings the
-- logs to the factory's input chest. When fuel runs low it parks on the birth
-- spot, where the factory hands it charcoal.
--
-- Usage: treefarm [x,z ...]   farm spots, relative to the factory with x east
--                            and z south (default 4,2 7,2 4,5 7,5)
--
-- Coordinates. The world frame used for spots has the factory at (0,0,0),
-- x east, z south. Internally it uses lib/nav's frame, which starts on the
-- birth spot B = world (0,0,-1) facing north: nav (x, y, z) = world (x, y, -1 - z).
--
-- Around the factory (world frame):
--   input chest (0,1,0), cobble turtle on top of it, cobble generator and its
--   lid north of it up to y=3. Home is (-1,1,0), west of the input chest.
--
-- It only digs leaves, snow, plants and pine branches while travelling. It
-- chops logs only in its own spots. If something else blocks it, it stops
-- and says where.

local nav = require("lib.nav")

local STATE = "/.treefarm"
local CRUISE = 4         -- travel height (world y), clear of the generator lid at y=3
local LOW_FUEL = 400     -- go to the fuel station below this
local FULL_FUEL = 1500   -- leave the fuel station at this
local WAIT = 120         -- seconds between rounds
local KEEP_SAPLINGS = 32

local SOFT = {
  ["minecraft:snow"] = true, ["minecraft:short_grass"] = true, ["minecraft:tall_grass"] = true,
  ["minecraft:fern"] = true, ["minecraft:large_fern"] = true, ["minecraft:dead_bush"] = true,
  ["regions_unexplored:frozen_grass"] = true,
}
local FACTORY = { ["computercraft:turtle_normal"] = true, ["computercraft:turtle_advanced"] = true }

local function isLog(b) return b.name:find("_log", 1, true) ~= nil or (b.tags or {})["minecraft:logs"] == true end
local function isBranch(b) return b.name:find("branch", 1, true) ~= nil end
local function isLeaves(b) return b.name:find("leaves", 1, true) ~= nil end
local function isSoil(b) return (b.tags or {})["minecraft:dirt"] == true end
local function clearable(b) return SOFT[b.name] or isLeaves(b) or isBranch(b) end

-- World frame -> nav frame.
local function N(wx, wz) return wx, -1 - wz end

local spots = {}
for _, a in ipairs({ ... }) do
  local x, z = a:match("^(-?%d+),(-?%d+)$")
  if x then spots[#spots + 1] = { x = tonumber(x), z = tonumber(z) } end
end
if #spots == 0 then spots = { { x = 4, z = 2 }, { x = 7, z = 2 }, { x = 4, z = 5 }, { x = 7, z = 5 } } end

-- Logs may be cut only inside our own spot columns (e.g. what's left of a
-- tree after a reboot mid-chop), never in wild trees on the way.
local function inSpot()
  local p = nav.pos()
  for _, s in ipairs(spots) do
    local x, z = N(s.x, s.z)
    if p.x == x and p.z == z then return true end
  end
  return false
end
local TRAVEL = { canDig = function(b) return clearable(b) or (isLog(b) and inSpot()) end }

---------------------------------------------------------------------------
-- State that survives reboots
---------------------------------------------------------------------------

local state
do
  local h = fs.open(STATE, "r")
  if h then
    state = textutils.unserialise(h.readAll())
    h.close()
  end
end

local function save()
  local h = fs.open(STATE, "w")
  h.write(textutils.serialise(state))
  h.close()
end

local function fail(msg) error(msg, 0) end

if not state then
  -- First start, on the birth spot: face away from the factory.
  local found = false
  for _ = 1, 4 do
    local ok, b = turtle.inspect()
    if ok and FACTORY[b.name] then
      turtle.turnRight()
      turtle.turnRight()
      found = true
      break
    end
    turtle.turnRight()
  end
  if not found then fail("Can't find the factory next to me; was I placed by it?") end
  state = {}
end
nav.init(state, save)
nav.recover()
save()

local function at(x, y, z)
  local p = nav.pos()
  return p.x == x and p.y == y and p.z == z
end

-- Burns coal or charcoal it carries (the factory's fuel station may have
-- handed over more than it burned) whenever the tank runs low.
local function topUp()
  if turtle.getFuelLevel() >= LOW_FUEL then return end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name == "minecraft:charcoal" or item.name == "minecraft:coal") then
      turtle.select(slot)
      while turtle.getFuelLevel() < FULL_FUEL and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

local function move(kind, opts)
  topUp()
  local ok, why = nav.move(kind, opts)
  if not ok then
    local p = nav.pos()
    fail(("Stuck at world (%d,%d,%d): %s"):format(p.x, p.y, -1 - p.z, why))
  end
end

local function stepTo(axis, value, opts)
  topUp()
  local ok, why = nav.stepTo(axis, value, opts or TRAVEL)
  if not ok then
    local p = nav.pos()
    fail(("Stuck at world (%d,%d,%d): %s"):format(p.x, p.y, -1 - p.z, why))
  end
end

---------------------------------------------------------------------------
-- Travel
---------------------------------------------------------------------------

-- Up to cruise height, then across to the column above nav (x, z).
local function travelTo(x, z)
  local p = nav.pos()
  -- The birth spot has the generator's floor above it: leave northwards first.
  if p.x == 0 and p.y == 0 and (p.z == 0 or p.z == 1) then stepTo("z", 2) end
  stepTo("y", CRUISE)
  stepTo("x", x)
  stepTo("z", z)
end

-- Down until standing on something that isn't leaves, snow or a plant.
local function descend()
  while true do
    local ok, b = turtle.inspectDown()
    if ok and not clearable(b) then return end
    if not nav.move("down", TRAVEL) then return end
  end
end

---------------------------------------------------------------------------
-- Farming
---------------------------------------------------------------------------

local function selectSapling()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name:find("sapling", 1, true) then
      turtle.select(slot)
      return true
    end
  end
  return false
end

local function plantDown()
  if not selectSapling() then return "out of saplings" end
  local ok = turtle.placeDown()
  turtle.select(1)
  return ok and "planted" or "couldn't plant"
end

-- Clears leaves and branches on the four sides: that's where saplings come from.
local function ring()
  for _ = 1, 4 do
    local ok, b = turtle.inspect()
    if ok and (isLeaves(b) or isBranch(b)) then turtle.dig() end
    nav.turn(true)
  end
end

-- Back out of the spot column to where we came in, facing east.
local function leave(level)
  stepTo("y", math.max(level, nav.pos().y), { canDig = clearable })
  nav.face(1)
  move("back")
end

-- Chops the pine in front (east), from its lowest log to its top, and replants.
local function fell(level)
  turtle.dig()
  move("forward")
  while true do
    local ok, b = turtle.inspectDown()
    if not (ok and isLog(b)) then break end
    turtle.digDown()
    move("down")
  end
  local bottom = nav.pos().y
  ring()
  -- Up past the cell we came in through (already dug), then while there's tree.
  while true do
    local ok, b = turtle.inspectUp()
    local below = nav.pos().y < level
    if not (below or (ok and (isLog(b) or isBranch(b)))) then break end
    if ok then turtle.digUp() end
    move("up")
    ring()
  end
  stepTo("y", bottom + 1, { canDig = clearable })
  local planted = plantDown()
  leave(level)
  return "felled, " .. planted
end

-- Plants a sapling in the empty spot in front: digs out snow down to the soil.
local function plant(level)
  local ok, b = turtle.inspect()
  if ok then turtle.dig() end
  move("forward")
  while true do
    ok, b = turtle.inspectDown()
    if not ok then
      move("down")
    elseif clearable(b) or b.name == "minecraft:snow_block" or isLog(b) then
      turtle.digDown() -- snow over the soil, or a stump left by a reboot
    elseif isSoil(b) then
      break
    elseif b.name:find("sapling", 1, true) then
      leave(level)
      return "growing"
    else
      leave(level)
      return "no soil (" .. b.name .. ")"
    end
  end
  move("up")
  local planted = plantDown()
  leave(level)
  return planted
end

-- Visits one spot from the column west of it. Returns what happened.
local function visit(spot)
  local x, z = N(spot.x - 1, spot.z)
  travelTo(x, z)
  descend()
  nav.face(1)
  -- The spot's ground may be a step higher than where we came down.
  local ok, b = turtle.inspect()
  for _ = 1, 3 do
    if not (ok and (b.name == "minecraft:snow_block" or isSoil(b))) then break end
    move("up", TRAVEL)
    ok, b = turtle.inspect()
  end
  local level = nav.pos().y
  if ok and isLog(b) then return fell(level) end
  if ok and b.name:find("sapling", 1, true) then return "growing" end
  if ok and not clearable(b) then return "blocked by " .. b.name end
  return plant(level)
end

---------------------------------------------------------------------------
-- Factory: deliveries and fuel
---------------------------------------------------------------------------

local function count(match)
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and match(item.name) then n = n + item.count end
  end
  return n
end

-- Home is west of the input chest, reached down the column south of it
-- (the generator's lid covers the column above home).
local function deliver()
  local hx, hz = N(-1, 1)
  travelTo(hx, hz)
  stepTo("y", 1)
  stepTo("z", select(2, N(-1, 0)))
  nav.face(1)
  local kept = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      local isSapling = item.name:find("sapling", 1, true)
      if not isSapling or kept >= KEEP_SAPLINGS then
        turtle.select(slot)
        turtle.drop()
      else
        kept = kept + item.count
      end
    end
  end
  turtle.select(1)
  stepTo("z", hz)
end

-- The birth spot doubles as a fuel station: the factory hands charcoal to a
-- turtle parked there.
local function refuel()
  local fx, fz = N(0, -3)
  travelTo(fx, fz)
  stepTo("y", 0)
  stepTo("z", 0)
  -- A minute for a full tank; never leave with less than LOW_FUEL, however
  -- long the factory takes (it may be down).
  local tries = 0
  while true do
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and (item.name == "minecraft:charcoal" or item.name == "minecraft:coal") then
        turtle.select(slot)
        turtle.refuel()
      end
    end
    turtle.select(1)
    tries = tries + 1
    if turtle.getFuelLevel() >= FULL_FUEL or (tries >= 30 and turtle.getFuelLevel() >= LOW_FUEL) then break end
    if tries % 30 == 0 then print(("Waiting for charcoal at the fuel station (fuel %d)"):format(turtle.getFuelLevel())) end
    sleep(2)
  end
  stepTo("z", 2)
end

-- Waits above the first spot, so its chunk stays loaded while trees grow.
local function park()
  local x, z = N(spots[1].x - 1, spots[1].z)
  travelTo(x, z)
end

print(("Pine farm running: %d spots"):format(#spots))
while true do
  -- Never set out on a round short of fuel.
  topUp()
  if turtle.getFuelLevel() < LOW_FUEL then
    refuel()
    print(("Refuelled to %d"):format(turtle.getFuelLevel()))
  end
  local notes = {}
  for i, spot in ipairs(spots) do
    notes[#notes + 1] = ("%d:%s"):format(i, visit(spot))
  end
  print(table.concat(notes, "  "))
  local logs = count(function(n) return n:find("_log", 1, true) ~= nil end)
  if logs >= 8 or turtle.getItemCount(16) > 0 then
    deliver()
    print(("Delivered %d logs"):format(logs))
  end
  if turtle.getFuelLevel() < LOW_FUEL then
    refuel()
    print(("Refuelled to %d"):format(turtle.getFuelLevel()))
  end
  park()
  sleep(WAIT)
end
