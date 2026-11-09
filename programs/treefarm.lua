-- Pine farm turtle (phase 3): a mining turtle with a chunk controller,
-- born on the factory's birth spot. It plants saplings on a few spots east of
-- the factory, chops the pines that grow there, replants, and brings the
-- logs to the factory's input chest. When fuel runs low it parks on the birth
-- spot, where the factory hands it charcoal.
--
-- Usage: treefarm [prep] [x,z ...]   farm spots, relative to the factory with
--                            x east and z south (default 4,2 7,2 4,5 7,5)
--   prep: first (once) clear the grove's ground of wild trees, rocks and
--         hills up to cruise height, and give every spot soil
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
--
-- The factory it was born at (state.origin) anchors all of this. When the
-- factory has moved to the Engine Hall (lib/home), deliveries and fuel are
-- fetched down the service shaft (lib/way); the grove stays where it is.

local nav = require("lib.nav")
local saved = require("lib.state")
local home = require("lib.home")
local way = require("lib.way")

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

local spots, wantPrep = {}, false
for _, a in ipairs({ ... }) do
  if a == "prep" then wantPrep = true end
  local x, z = a:match("^(-?%d+),(-?%d+)$")
  if x then spots[#spots + 1] = { x = tonumber(x), z = tonumber(z) } end
end
if #spots == 0 then spots = { { x = 4, z = 2 }, { x = 7, z = 2 }, { x = 4, z = 5 }, { x = 7, z = 5 } } end

-- Logs may be cut only in or next to our own spot columns (what's left of a
-- tree after a reboot mid-chop, or a pine's side logs, which grow out over
-- the lane), never in wild trees on the way.
local function nearSpot()
  local p = nav.pos()
  for _, s in ipairs(spots) do
    local x, z = N(s.x, s.z)
    if math.abs(p.x - x) <= 1 and math.abs(p.z - z) <= 1 then return true end
  end
  return false
end
local TRAVEL = { canDig = function(b) return clearable(b) or (isLog(b) and nearSpot()) end }

---------------------------------------------------------------------------
-- State that survives reboots
---------------------------------------------------------------------------

local state = saved.load(STATE)

local function save() saved.save(STATE, state) end

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
  state = { origin = home.copy(home.factory) }
end
-- Turtles born before the factory could move were born on the surface.
state.origin = state.origin or home.copy(home.surface)
local O = state.origin
nav.init(state, save)
nav.recover()
save()

local function at(x, y, z)
  local p = nav.pos()
  return p.x == x and p.y == y and p.z == z
end

-- Burns coal or charcoal it carries (the factory's fuel station may have
-- handed over more than it burned) whenever the tank runs low.
local function burnCarried()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name == "minecraft:charcoal" or item.name == "minecraft:coal") then
      turtle.select(slot)
      while turtle.getFuelLevel() < FULL_FUEL and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- Burns carried coal when low. Bone dry with nothing to burn, it waits
-- where it is, calling for help, until someone hands it some.
local function topUp()
  if turtle.getFuelLevel() >= LOW_FUEL then return end
  burnCarried()
  local waited = 0
  while turtle.getFuelLevel() == 0 do
    if waited % 300 == 0 then
      local p = nav.pos()
      print(("Out of fuel at world (%d,%d,%d): waiting for coal"):format(p.x, p.y, -1 - p.z))
      os.queueEvent("bridge_send", { action = "event", text = ("Juniper is out of fuel at %d %d %d"):format(O.x + p.x, O.y + p.y, O.z - 1 - p.z) })
    end
    sleep(5)
    waited = waited + 5
    burnCarried()
  end
end

-- Other turtles (the excavator crew comes and goes, and may sit on the
-- fuel station) are waited for, up to half an hour, not taken for a wall.
local function byTurtle(why) return tostring(why):find("computercraft:", 1, true) ~= nil end

local function move(kind, opts)
  topUp()
  local ok, why = nav.move(kind, opts)
  for _ = 1, 360 do
    if ok or not byTurtle(why) then break end
    sleep(5)
    ok, why = nav.move(kind, opts)
  end
  if not ok then
    local p = nav.pos()
    fail(("Stuck at world (%d,%d,%d): %s"):format(p.x, p.y, -1 - p.z, why))
  end
end

local function stepTo(axis, value, opts)
  topUp()
  local ok, why = nav.stepTo(axis, value, opts or TRAVEL)
  for _ = 1, 360 do
    if ok or not byTurtle(why) then break end
    sleep(5)
    ok, why = nav.stepTo(axis, value, opts or TRAVEL)
  end
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

-- How it moves, for lib/way (the way down to the factory in the hall).
local DIRS = { n = 0, e = 1, s = 2, w = 3 }
local go = {
  step = function(op)
    topUp()
    local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
    if kind == "forward" then nav.face(DIRS[op]) end
    local ok, why = nav.move(kind, TRAVEL)
    if ok then return true end
    return false, byTurtle(why) and "turtle" or why
  end,
  pos = function()
    local p = nav.pos()
    return { x = O.x + p.x, y = O.y + p.y, z = O.z - 1 - p.z }
  end,
  face = function(op) nav.face(DIRS[op]) end,
}

-- Into the input chest in front: everything but saplings to replant.
local function dropLogs()
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
end

-- Home is west of the input chest, reached down the column south of it
-- (the generator's lid covers the column above home).
local function deliver()
  if home.inHall then
    way.toHall(go, O.y + CRUISE)
    way.toDrop(go, home.factory)
    dropLogs()
    way.leaveDrop(go)
    way.toSurface(go, O.y + CRUISE)
    return
  end
  local hx, hz = N(-1, 1)
  travelTo(hx, hz)
  stepTo("y", 1)
  stepTo("z", select(2, N(-1, 0)))
  nav.face(1)
  dropLogs()
  stepTo("z", hz)
end

-- Burns the charcoal the factory hands over; a minute for a full tank, and
-- never away with less than LOW_FUEL, however long the factory takes (it
-- may be down).
local function fillUp()
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
end

-- The birth spot doubles as a fuel station: the factory hands charcoal to a
-- turtle parked there.
local function refuel()
  if home.inHall then
    way.toHall(go, O.y + CRUISE)
    way.toStation(go, home.factory)
    fillUp()
    way.leaveStation(go, home.factory)
    way.toSurface(go, O.y + CRUISE)
    return
  end
  local fx, fz = N(0, -3)
  -- The lane is one block wide and turtles leave by it too: if one is in
  -- the way, back out and up, wait a while and try again, so the one
  -- leaving always gets past.
  while true do
    travelTo(fx, fz)
    stepTo("y", 0)
    local ok, why = true, nil
    while ok and nav.pos().z > 0 do ok, why = nav.stepTo("z", 0, TRAVEL) end
    if ok then break end
    if not byTurtle(why) then
      local p = nav.pos()
      fail(("Stuck at world (%d,%d,%d): %s"):format(p.x, p.y, -1 - p.z, why))
    end
    -- Out of the lane and one block up (the lane's turtles walk under it):
    -- a few fuel a try, however long the station stays busy.
    print("A turtle is at the fuel station; waiting beside the lane")
    stepTo("z", fz)
    stepTo("y", 1)
    sleep(20 + math.random(30))
  end
  fillUp()
  stepTo("z", 2)
end

-- Waits above the first spot, so its chunk stays loaded while trees grow.
local function park()
  local x, z = N(spots[1].x - 1, spots[1].z)
  travelTo(x, z)
end

---------------------------------------------------------------------------
-- Preparing the ground (once, with "prep")
---------------------------------------------------------------------------

-- Inside the grove anything may be dug but saplings and turtles.
local PREP = { canDig = function(b)
  return not FACTORY[b.name] and not b.name:find("sapling", 1, true) and not b.name:find("computercraft:", 1, true)
end }
local JUNK = { "cobble", "stone", "gravel", "sand", "andesite", "diorite", "granite", "tuff", "calcite" }

local function digIf(inspect, dig)
  for _ = 1, 16 do
    local ok, b = inspect()
    if not ok or not PREP.canDig(b) then return end
    if not dig() then return end
  end
end

-- Keeps dirt (for soil), logs and saplings; drops stone and the like.
local function dropRubble()
  if turtle.getItemCount(16) == 0 then return end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not item.name:find("ore", 1, true) then
      for _, w in ipairs(JUNK) do
        if item.name:find(w, 1, true) then turtle.select(slot) turtle.dropDown() break end
      end
    end
  end
  turtle.select(1)
end

-- A spot's ground (world y -1) must be soil, or snow over soil: anything
-- else is dug out and replaced with dirt.
local function soilAt()
  stepTo("y", 0, PREP)
  local ok, b = turtle.inspectDown()
  if ok and (isSoil(b) or b.name == "minecraft:snow_block" or b.name:find("sapling", 1, true)) then return end
  if ok then digIf(turtle.inspectDown, turtle.digDown) end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name == "minecraft:dirt" or item.name == "minecraft:grass_block") then
      turtle.select(slot)
      turtle.placeDown()
      turtle.select(1)
      return
    end
  end
  local p = nav.pos()
  print(("No dirt for the spot at world (%d,-1,%d)"):format(p.x, -1 - p.z))
end

local function prep()
  local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
  for _, sp in ipairs(spots) do
    x0, x1 = math.min(x0, sp.x - 1), math.max(x1, sp.x + 1)
    z0, z1 = math.min(z0, sp.z - 1), math.max(z1, sp.z + 1)
  end
  local isSpot = {}
  for _, sp in ipairs(spots) do isSpot[sp.x .. "," .. sp.z] = true end
  print(("Preparing the grove: x %d-%d, z %d-%d"):format(x0, x1, z0, z1))
  travelTo(N(x0, z0))
  -- Two passes, each clearing three layers: y 3-5, then y 0-2.
  for pass, y in ipairs({ 4, 1 }) do
    stepTo("y", y, PREP)
    for row = 0, z1 - z0 do
      local wz = z0 + row
      local xs = {}
      for wx = x0, x1 do xs[#xs + 1] = wx end
      if (row + pass) % 2 == 0 then for i = 1, math.floor(#xs / 2) do xs[i], xs[#xs + 1 - i] = xs[#xs + 1 - i], xs[i] end end
      for _, wx in ipairs(xs) do
        local nx, nz = N(wx, wz)
        stepTo("z", nz, PREP)
        stepTo("x", nx, PREP)
        digIf(turtle.inspectUp, turtle.digUp)
        digIf(turtle.inspectDown, turtle.digDown)
        if pass == 2 and isSpot[wx .. "," .. wz] then
          soilAt()
          stepTo("y", y, PREP)
        end
        dropRubble()
      end
    end
  end
  stepTo("y", CRUISE, PREP)
  state.prepped = true
  save()
  print("The grove is ready")
end

if wantPrep and not state.prepped then
  topUp()
  if turtle.getFuelLevel() < LOW_FUEL then refuel() end
  prep()
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
