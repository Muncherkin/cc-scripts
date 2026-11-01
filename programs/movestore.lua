-- The mover: carries the factory's storage from the surface down to the new
-- storage in the Engine Hall (docs/factory-move.md, lib/home.lua). A mining
-- turtle with a chunk controller, born on the factory's birth spot (factory
-- birth mover) while the factory is evacuating (factory evacuate on).
--
-- It labels itself Mover, and the factory loads it on the birth spot, fuel
-- first, a few stacks a visit. With a load it leaves north by the lane,
-- flies over to the service shaft at y 80, goes down it into the hall, drops
-- the load into the hall factory's barrels from above (the row east of the
-- spine, then the row on top of it) and comes back up the shaft at y 82 to
-- the birth spot for the next. It burns fuel from its loads as it needs to,
-- keeps a stack of it, and digs nothing but snow, plants and leaves. When
-- the factory has had nothing for it for five minutes it parks in the hall.
--
-- Usage: movestore            (what autorun runs; resumes after reboots)
--        movestore status

local nav = require("lib.nav")
local saved = require("lib.state")
local home = require("lib.home")
local way = require("lib.way")

local STATE = "/.movestore"
local OUT, BACK = 80, 82      -- surface heights: to the shaft, from it
local IDLE_DONE = 300         -- seconds with nothing loaded before it's all carried
local SETTLE = 30             -- seconds without a new stack before it sets off
local KEEP_FUEL = 64          -- fuel items it keeps for itself

local FUEL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true }
local SOFT = { "snow", "grass", "fern", "flower", "bush", "sapling", "vine", "mushroom", "dandelion", "poppy", "leaves" }

local function fail(msg) error(msg, 0) end
local function isMachine(b)
  return b.name:find("^computercraft:turtle") ~= nil or b.name:find("^computercraft:computer") ~= nil
end
local function isSoft(b)
  if b.name:find("block", 1, true) then return false end
  for _, w in ipairs(SOFT) do if b.name:find(w, 1, true) then return true end end
  return false
end

local state = saved.load(STATE)
if ... == "status" then
  if not state then print("Not started") return end
  print(("Mover: %s, %d loads carried, next barrel %d of %d"):format(state.phase, state.loads or 0,
    state.cell or 1, #home.dropCells(state.to)))
  return
end
state = state or { phase = "orient" }
local function save() saved.save(STATE, state) end
nav.init(state, save)
nav.recover()
save()

---------------------------------------------------------------------------
-- Coordinates. nav starts on the birth spot of the factory it was born at
-- (state.origin), facing north: nav +z is north, +x east.
---------------------------------------------------------------------------

state.origin = state.origin or home.copy(home.factory)
state.to = state.to or home.copy(home.hall)
local O, H = state.origin, state.to
local function world()
  local p = nav.pos()
  return { x = O.x + p.x, y = O.y + p.y, z = O.z - 1 - p.z }
end
local function key(w) return ("%d %d %d"):format(w.x, w.y, w.z) end

local DIRS = { n = 0, e = 1, s = 2, w = 3 }
local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local SOFTLY = { canDig = isSoft }

---------------------------------------------------------------------------
-- Fuel and cargo
---------------------------------------------------------------------------

local function burn(target)
  for slot = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    local item = turtle.getItemDetail(slot)
    if item and FUEL[item.name] then
      turtle.select(slot)
      while turtle.getFuelLevel() < target and turtle.getItemCount(slot) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- One round trip from the birth spot to the far end of the barrels, with
-- room to spare for waiting about.
local function tripCost()
  local S = home.shaft
  local surface = (BACK - O.y) + math.abs(O.x - S.x) + math.abs(O.z - S.z) + 10
  local hall = (BACK - home.hallIn) + math.abs(S.x - H.x) + math.abs(S.z - H.z) + (home.hallIn - H.y) + 30
  return 2 * (surface + hall) + 100
end

local function items()
  local n = 0
  for slot = 1, 16 do n = n + turtle.getItemCount(slot) end
  return n
end

local function freeSlots()
  local n = 0
  for slot = 1, 16 do if turtle.getItemCount(slot) == 0 then n = n + 1 end end
  return n
end

-- Cargo is everything but one stack of fuel kept for itself.
local function isCargo(slot, keptFuel)
  local item = turtle.getItemDetail(slot)
  if not item then return false, keptFuel end
  if FUEL[item.name] and not keptFuel and item.count <= KEEP_FUEL then return false, true end
  return true, keptFuel
end

local function hasCargo()
  local kept = false
  for slot = 1, 16 do
    local cargo
    cargo, kept = isCargo(slot, kept)
    if cargo then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Moving
---------------------------------------------------------------------------

-- One step in a world direction: turtles in the way are waited for a few
-- seconds, snow and plants are dug, anything else is a wall.
local function step(op)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIRS[op]) end
  if turtle.getFuelLevel() < 20 then burn(500) end
  for _ = 1, 5 do
    local ok, b = INSPECT[kind]()
    if not (ok and isMachine(b)) then break end
    sleep(2)
  end
  local ok, b = INSPECT[kind]()
  if ok and isMachine(b) then return false, "turtle" end
  local moved, why = nav.move(kind, SOFTLY)
  if moved then return true end
  return false, why
end

local go = { step = step, pos = world, face = function(op) nav.face(DIRS[op]) end }

local function inHall() return world().y < home.shaft.foot end

-- On the surface: onto the birth spot by its lane from the north. A turtle
-- in the lane is leaving: back out of its way, wait, try again.
local function toStation()
  while true do
    way.vertical(go, math.max(world().y, BACK))
    way.across(go, O.x, O.z - 4, "xz")
    way.vertical(go, O.y)
    while world().z < O.z - 1 and step("s") do end
    if world().z == O.z - 1 then return end
    print("A turtle is leaving the birth spot; making way")
    while world().z > O.z - 4 do step("n") end
    way.vertical(go, BACK + 3)
    sleep(15 + math.random(30))
  end
end

-- Off the birth spot (or out of its lane) to the north.
local function leaveStation()
  while world().z > O.z - 5 do
    local w = world()
    if not (step("n") or step("u") or (w.x ~= O.x and step(w.x < O.x and "e" or "w"))) then sleep(5) end
  end
end

-- From wherever it is on the surface or in the shaft down into the hall.
local function down()
  if inHall() then return end
  local w, S = world(), home.shaft
  if w.x == O.x and w.y == O.y then leaveStation() end
  if not (world().x == S.x and world().z == S.z) then way.vertical(go, math.max(world().y, OUT)) end
  way.toHall(go, OUT)
end

-- To a cell in the hall: up to the flying-in height if it has to cross, over,
-- and down.
local function moveTo(c)
  local w = world()
  if w.x ~= c.x or w.z ~= c.z then
    local y = math.max(w.y, c.y)
    if math.abs(w.x - c.x) + math.abs(w.z - c.z) > 1 then y = home.hallIn end
    way.vertical(go, y)
    way.across(go, c.x, c.z, "zx")
  end
  local ok, why = way.vertical(go, c.y)
  if not ok then fail(("Can't get to %s: %s"):format(key(c), tostring(why))) end
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

local function orient()
  os.setComputerLabel("Mover")
  local found = false
  for _ = 1, 4 do
    local ok, b = turtle.inspect()
    if ok and isMachine(b) then found = true break end
    turtle.turnRight()
  end
  if not found then fail("I start on the factory's birth spot, next to the factory") end
  turtle.turnRight()
  turtle.turnRight()
  state.dir = 0
  state.phase, state.loads, state.cell = "load", 0, 1
  save()
end

-- On the birth spot until a load has come in and nothing more is coming.
-- Returns false if nothing came for IDLE_DONE seconds.
local function waitLoad()
  if world().x ~= O.x or world().y ~= O.y or world().z ~= O.z - 1 then toStation() end
  print("At the birth spot, waiting to be loaded")
  local last, still, waited = items(), 0, 0
  while true do
    sleep(5)
    waited = waited + 5
    local n = items()
    if n ~= last then last, still = n, 0 else still = still + 5 end
    if hasCargo() and (freeSlots() <= 1 or still >= SETTLE) then return true end
    if not hasCargo() and still >= IDLE_DONE then return false end
  end
end

local function unload()
  local cells = home.dropCells(H)
  while hasCargo() do
    local c = cells[state.cell]
    if not c then fail("The hall's barrels are full: put more on the spine (docs/factory-move.md)") end
    moveTo(c)
    local kept = false
    for slot = 1, 16 do
      local cargo
      cargo, kept = isCargo(slot, kept)
      if cargo then
        turtle.select(slot)
        turtle.dropDown()
      end
    end
    turtle.select(1)
    if hasCargo() then
      state.cell = state.cell + 1
      save()
    end
  end
end

if state.phase == "orient" then orient() end

while state.phase ~= "done" do
  if state.phase == "load" then
    if waitLoad() then
      burn(math.min(turtle.getFuelLimit(), tripCost() + 200))
      if turtle.getFuelLevel() < tripCost() then
        fail(("Not enough fuel for the trip (%d of %d): load me some coal"):format(turtle.getFuelLevel(), tripCost()))
      end
      state.phase = "down"
    else
      print("Nothing more to carry")
      state.phase = "park"
    end
    save()
  elseif state.phase == "down" then
    down()
    state.phase = "unload"
    save()
  elseif state.phase == "unload" then
    unload()
    state.loads = (state.loads or 0) + 1
    print(("Load %d is in the barrels (barrel %d of %d)"):format(state.loads, state.cell, #home.dropCells(H)))
    state.phase = "up"
    save()
  elseif state.phase == "up" then
    if inHall() then way.toSurface(go, BACK) end
    toStation()
    state.phase = "load"
    save()
  elseif state.phase == "park" then
    down()
    -- Out of everyone's way, west of the furnaces.
    moveTo({ x = H.x - 1, y = H.y, z = H.z + 3 })
    state.phase = "done"
    save()
  end
end
print(("All carried: %d loads. Parked in the hall at %s"):format(state.loads or 0, key(world())))
