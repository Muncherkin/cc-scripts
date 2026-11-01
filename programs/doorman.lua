-- Doorman: keeps the gate in the iron-bar fence by Otis's shed. A mining
-- turtle with an Environment Detector, born at the factory (factory birth
-- doorman).
--
-- It flies over and takes the place of the iron bar above the gate (a jail
-- door at 3545 72-73 4746 that opens on a redstone signal), keeping the bar.
-- From there it powers the door below it while a player is within a few
-- blocks of the gate, either side, and shuts it once they've gone. Now and
-- then, with nobody about, it walks the path from the gate to the shed door
-- (3547 72-73 4753) at head height and digs the snow off it, and the first
-- time it also mines the factory block at 3548 72 4753 by the shed door.
-- When fuel runs low it flies to the factory's fuel station and back.
--
-- Usage: doorman   (what autorun runs; resumes after reboots)

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.doorman"
local F = { x = 3559, y = 74, z = 4763 }          -- the factory turtle, facing north
local POST = { x = 3545, y = 74, z = 4746 }       -- the bar above the gate
local PATH = { x0 = 3545, x1 = 3547, z0 = 4747, z1 = 4752, y = 72 } -- snow lies at y 72
local MINE = { x = 3548, y = 72, z = 4753 }       -- the factory block by the shed door
local CRUISE = 84                                 -- above the excavators' 80 and 82
local NEAR = { xz = 3, y = 4 }                    -- a player this close to the gate opens it
local SWEEP_EVERY = 300                           -- seconds between snow rounds
local CLOSE_AFTER = 3                             -- seconds after the last player has gone
local LOW_FUEL, FILL_FUEL = 200, 2000

local SOFT = { "snow", "grass", "fern", "flower", "bush", "sapling", "vine", "leaves", "dandelion", "poppy" }
local function has(name, words)
  for _, w in ipairs(words) do if name:find(w, 1, true) then return true end end
  return false
end
local function isSoft(b) return has(b.name, SOFT) and not b.name:find("block", 1, true) end
local function isMachine(b)
  return b.name:find("^computercraft:turtle") ~= nil or b.name:find("^computercraft:computer") ~= nil
end
local function fail(msg) error(msg, 0) end

local detector
for _, side in ipairs({ "left", "right" }) do
  if peripheral.hasType(side, "environment_detector") or peripheral.hasType(side, "environmentDetector") then detector = side end
end
if not detector then fail("I need an Environment Detector upgrade") end

local state = saved.load(STATE) or { phase = "orient" }
local function save() saved.save(STATE, state) end
nav.init(state, save)
nav.recover()
save()

-- nav starts on the birth spot facing north: nav +z north, +x east.
local function world()
  local p = nav.pos()
  return { x = F.x + p.x, y = F.y + p.y, z = F.z - 1 - p.z }
end
local function at(c) local w = world() return w.x == c.x and w.y == c.y and w.z == c.z end
local DIRS = { n = 0, e = 1, s = 2, w = 3 }

local T = {
  forward = { inspect = turtle.inspect, dig = turtle.dig },
  up = { inspect = turtle.inspectUp, dig = turtle.digUp },
  down = { inspect = turtle.inspectDown, dig = turtle.digDown },
}

-- One step, clearing only snow and plants (and anything canDig allows);
-- turtles in the way are waited for. False if something else is there.
local function step(op, canDig)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIRS[op]) end
  local t = T[kind]
  for _ = 1, 600 do
    local ok, b = t.inspect()
    if not ok or (b.state and b.state.level) then break end
    if isMachine(b) then
      sleep(2)
    elseif isSoft(b) or (canDig and canDig(b)) then
      t.dig()
    else
      return false
    end
  end
  local ok = nav.move(kind, { canDig = function(b) return isSoft(b) or (canDig and canDig(b)) end })
  return ok
end

local function rise(y)
  while world().y < y do
    if not step("u") then fail("Can't rise at " .. textutils.serialise(world()):gsub("%s+", "")) end
  end
end

local function sink(y, canDig)
  while world().y > y do
    if not step("d", canDig) then return false end
  end
  return true
end

-- Across at height y to column (x, z), over anything in the way.
local function flyTo(x, z, y)
  rise(y)
  for _, axis in ipairs({ "x", "z" }) do
    local target = axis == "x" and x or z
    while world()[axis] ~= target do
      local op = axis == "x" and (world().x < x and "e" or "w") or (world().z < z and "s" or "n")
      if not step(op) then
        if not step("u") then fail("Boxed in") end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------

local function burn(target)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name == "minecraft:coal" or item.name == "minecraft:charcoal" or item.name == "minecraft:coal_block") then
      turtle.select(slot)
      while turtle.getFuelLevel() < target and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- To the fuel station on the birth spot, from the north like the crew.
local function fuelStation()
  flyTo(F.x, F.z - 4, CRUISE)
  sink(F.y)
  while world().z < F.z - 1 do step("s") end
  local waited = 0
  while turtle.getFuelLevel() < FILL_FUEL do
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < FILL_FUEL then
      if waited % 30 == 0 then print(("Waiting at the fuel station (fuel %d)"):format(turtle.getFuelLevel())) end
      waited = waited + 1
      sleep(2)
    end
  end
  while world().z > F.z - 4 do step("n") end
end

---------------------------------------------------------------------------
-- The post
---------------------------------------------------------------------------

local isBar = function(b) return b.name:find("bars", 1, true) ~= nil end

-- Over the gate and down into the bar's place (the bar comes along).
local function toPost()
  flyTo(POST.x, POST.z, CRUISE)
  sink(POST.y + 1)
  if not sink(POST.y, isBar) then fail("Something other than iron bars is above the gate") end
  nav.face(0)
end

local open = false
local function setOpen(v)
  if v ~= open then
    redstone.setOutput("bottom", v)
    open = v
    print(v and "Gate open" or "Gate shut")
  end
end

-- Players near the gate, from a scan (offsets are from the turtle, world axes).
local lastScan, near, around = -math.huge, false, false
local function look()
  if os.clock() - lastScan < 2.05 then return end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", 8)
  if not ok or type(list) ~= "table" then return end
  lastScan = os.clock()
  near, around = false, false
  for _, e in ipairs(list) do
    if e.name == "minecraft:player" or e.isPlayer then
      around = true
      -- The gate is one and two below the turtle.
      if math.abs(e.x) <= NEAR.xz and math.abs(e.z) <= NEAR.xz and math.abs(e.y + 1.5) <= NEAR.y then near = true end
    end
  end
end

-- Round the path at head height, digging snow off it.
local function sweep()
  setOpen(false)
  print("Clearing the path")
  step("s")                                  -- out over the yard
  sink(PATH.y + 1)
  for row = 0, PATH.z1 - PATH.z0 do
    local z = PATH.z0 + row
    local xs = row % 2 == 0 and { PATH.x0, PATH.x1, 1 } or { PATH.x1, PATH.x0, -1 }
    for x = xs[1], xs[2], xs[3] do
      while world().z ~= z do if not step(world().z < z and "s" or "n") then break end end
      while world().x ~= x do if not step(world().x < x and "e" or "w") then break end end
      local ok, b = turtle.inspectDown()
      if ok and b.name == "minecraft:snow" then turtle.digDown() end
    end
  end
  -- Once: the factory block by the shed door, from the path north of it.
  if not state.mined then
    while world().x ~= MINE.x do if not step(world().x < MINE.x and "e" or "w") then break end end
    while world().z ~= MINE.z - 1 do if not step(world().z < MINE.z - 1 and "s" or "n") then break end end
    sink(MINE.y)
    nav.face(2)
    local ok, b = turtle.inspect()
    if ok and b.name:find("factory_blocks:", 1, true) then turtle.dig() end
    state.mined = true
    save()
  end
  -- Back along the path's top and up into the post.
  rise(PATH.y + 1)
  while world().x ~= POST.x do if not step(world().x < POST.x and "e" or "w") then break end end
  while world().z ~= POST.z + 1 do if not step(world().z < POST.z + 1 and "s" or "n") then break end end
  rise(POST.y)
  step("n")
  nav.face(0)
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

if state.phase == "orient" then
  -- On the birth spot: turn away from the factory.
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
  burn(500)
  while turtle.getFuelLevel() < 300 do print("Waiting for coal") sleep(5) burn(500) end
  state.phase = "travel"
  save()
end

if state.phase == "travel" then
  -- North off the birth spot (the cobble generator is over it), then over.
  while world().z > F.z - 5 do
    if not (step("n") or step("u")) then sleep(5) end
  end
  toPost()
  state.phase = "post"
  save()
  print("At the gate")
end

if not at(POST) then toPost() end
setOpen(false)
local lastSeen, lastSweep = -math.huge, os.clock() - SWEEP_EVERY + 30
while true do
  look()
  if near then
    lastSeen = os.clock()
    setOpen(true)
  elseif open and os.clock() - lastSeen > CLOSE_AFTER then
    setOpen(false)
  end
  if not open and not around and os.clock() - lastSweep > SWEEP_EVERY then
    sweep()
    lastSweep = os.clock()
  end
  if turtle.getFuelLevel() < LOW_FUEL and not open then
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < LOW_FUEL then
      fuelStation()
      toPost()
    end
  end
  sleep(0.5)
end
