-- Doorman: keeps the gate in the iron-bar fence by Otis's shed. A mining
-- turtle with an Environment Detector, born at the factory (factory birth
-- doorman).
--
-- It lives in a hole in the vault's wall (3548 73 4755), looking out east,
-- and gets there round the vault. It breaks nothing but the snow on the
-- path: anything else in its way it goes over or round.
-- When a player comes near the gate (a
-- jail door at 3545 72-73 4746 that opens on a redstone signal), from either
-- side, it goes up over the yard and stands on the block above the gate,
-- powering it, which opens the door below. Once they've gone it shuts the
-- door and goes home. (Bars don't carry a signal: the block above the gate
-- must be solid, and it says so if it isn't.) Now and then, with nobody
-- about, it walks the path: one wide from the gate to the vault door (3547
-- 72-73 4753), then in front of Keeper, digging the snow off; and every time
-- it comes home it clears the snow below its doorstep. When fuel runs low it
-- flies to the factory's fuel station.
--
-- Usage: doorman   (what autorun runs; resumes after reboots)

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.doorman"
local F = { x = 3559, y = 74, z = 4763 }          -- the factory turtle, facing north
local GATE = { x = 3545, y = 72, z = 4747 }       -- the jail door (72-73)
local BLOCK = { x = 3545, y = 74, z = 4747 }      -- the solid block above it
local POST = { x = 3545, y = 75, z = 4747 }       -- on top of that block
local HOME = { x = 3548, y = 73, z = 4755 }       -- a hole in the vault's west wall
local DOORSTEP = { x = 3549, y = 73, z = 4755 }   -- just outside it, east
local OLD_HOME = { x = 3548, y = 72, z = 4753 }   -- where it lived first, below Keeper
local ROUND = { x = 3549, z = 4751 }              -- round the vault's east side, between home and the path
local HIGH = 73                                   -- it keeps to its home height when moving about
local PATH_HEAD = 73                              -- walking the path, just above it
-- The path from the vault door to the gate, as drawn: snow lies on it at
-- y 72, and it walks just above it. Listed from the vault end.
local PATH = {
  { 3548, 4751 }, { 3547, 4751 }, { 3548, 4750 }, { 3547, 4750 }, { 3548, 4749 },
  { 3547, 4749 }, { 3546, 4749 }, { 3547, 4748 }, { 3546, 4748 }, { 3546, 4747 },
}
local CRUISE = 84                                 -- above the excavators' 80 and 82
local NEAR = { xz = 3, y = 4 }                    -- a player this close to the gate opens it
local SWEEP_EVERY = 300                           -- seconds between snow rounds
local CLOSE_AFTER = 3                             -- seconds after the last player has gone
local HOME_AFTER = 15                             -- seconds after that before going home
local LOW_FUEL, FILL_FUEL = 200, 2000

local SOFT = {} -- it breaks nothing on its way (the path's snow is dug on purpose)
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

-- One step, clearing only what canDig allows (nothing, mostly);
-- turtles in the way are waited for. False if something else is there.
local function step(op, canDig)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIRS[op]) end
  local t = T[kind]
  for _ = 1, 600 do
    local ok, b = t.inspect()
    if not ok or (b.state and b.state.level) then break end
    if b.name:find("^computercraft:turtle") then
      sleep(2) -- turtles move on; computers (Keeper) don't
    elseif isSoft(b) or (canDig and canDig(b)) then
      t.dig()
    else
      return false
    end
  end
  local ok = nav.move(kind, { canDig = function(b) return isSoft(b) or (canDig and canDig(b)) end })
  return ok
end

-- Up to height y; under something it moves out from under it first.
local function rise(y)
  local tries = 0
  while world().y < y do
    if not step("u") then
      tries = tries + 1
      if tries > 8 then fail("Can't rise at " .. textutils.serialise(world()):gsub("%s+", "")) end
      local _ = step("n") or step("e") or step("s") or step("w")
    end
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
local function slotOf(match)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and match(item.name) then return slot end
  end
end

-- Towards column (x, z) at the current height, over anything in the way.
local function walk(x, z, zFirst)
  local level = world().y
  for _ = 1, 64 do
    local w = world()
    -- Back down to its height once it's over whatever made it climb.
    if w.y > level and not turtle.detectDown() then step("d") w = world() end
    if w.x == x and w.z == z then return true end
    local moved = false
    if zFirst and w.z ~= z then moved = step(w.z < z and "s" or "n") end
    if not moved and w.x ~= x then moved = step(w.x < x and "e" or "w") end
    if not moved and w.z ~= z then moved = step(w.z < z and "s" or "n") end
    if not moved then moved = step("u") end
    -- Hemmed in: a step to the side, round whatever is in the way.
    if not moved then
      if w.x ~= x then moved = step("s") or step("n") else moved = step("e") or step("w") end
    end
    if not moved then return false end
  end
  return false
end

-- Out of the wall and up over the yard; and back in, backwards, so it
-- looks out. Until the hole is dug out it waits on the doorstep.
local function leaveHome()
  if at(HOME) then step("e") end
  if at(OLD_HOME) then step("n") end
  rise(HIGH)
  -- Round the vault, not back through it.
  local w = world()
  if w.x >= ROUND.x and w.z > ROUND.z then walk(ROUND.x, ROUND.z, true) end
end
local function goHome()
  if at(OLD_HOME) then step("n") end
  if at(POST) then step("s") end
  sink(HIGH)
  rise(HIGH)
  -- Round the vault's east side to the doorstep.
  if world().z < DOORSTEP.z then walk(ROUND.x, ROUND.z) end
  walk(DOORSTEP.x, DOORSTEP.z, true)
  if not sink(DOORSTEP.y) then print("Something is in the way down to my doorstep") end
  local ok, b = turtle.inspectDown()
  if ok and b.name == "minecraft:snow" then turtle.digDown() end
  nav.face(3)
  local said = false
  while true do
    local full, blk = turtle.inspect()
    if not full or isMachine(blk) then break end
    if not said then print("Waiting for my home to be dug out") said = true end
    sleep(10)
  end
  step("w")
  nav.face(1)
end

-- The block above the gate carries the signal down into the door, so it
-- has to be solid (bars and air carry none). It only looks, once per gate
-- position, and says so if it isn't; it changes nothing.
local function checkBlock()
  if state.checked == BLOCK.z then return end
  leaveHome()
  walk(BLOCK.x, BLOCK.z + 1)
  rise(BLOCK.y)
  nav.face(0)
  local ok, b = turtle.inspect()
  if not ok or isBar(b) then
    print(("The block above the gate (%d %d %d) must be solid for me to open it"):format(BLOCK.x, BLOCK.y, BLOCK.z))
  end
  state.checked = BLOCK.z
  save()
  goHome()
end

-- On top of the block above the gate, from the south over the yard.
local function toPost()
  if at(POST) then return end
  if at(HOME) then leaveHome() end
  walk(POST.x, POST.z + 1)
  rise(POST.y)
  step("n")
end

local open = false
local function setOpen(v)
  if v ~= open then
    redstone.setOutput("bottom", v)
    open = v
    print(v and "Gate open" or "Gate shut")
  end
end

-- Players near the gate, from a scan (offsets are from the turtle, world
-- axes; radius 8 costs no fuel and reaches the gate from home).
local lastScan, near, around = -math.huge, false, false
local function look()
  if os.clock() - lastScan < 2.05 then return end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", 8)
  if not ok or type(list) ~= "table" then return end
  lastScan = os.clock()
  near, around = false, false
  local w = world()
  for _, e in ipairs(list) do
    if e.name == "minecraft:player" or e.isPlayer then
      around = true
      local px, py, pz = w.x + e.x, w.y + e.y, w.z + e.z
      if math.abs(px - GATE.x) <= NEAR.xz and math.abs(pz - GATE.z) <= NEAR.xz and math.abs(py - GATE.y) <= NEAR.y then near = true end
    end
  end
end

-- Along the path just above it, digging the snow off, and back home. It
-- keeps looking out: a player coming to the gate breaks it off (true).
local function sweep()
  print("Clearing the path")
  leaveHome()
  walk(PATH[1][1], PATH[1][2])
  sink(PATH_HEAD)
  for i = 1, #PATH do
    walk(PATH[i][1], PATH[i][2])
    local ok, b = turtle.inspectDown()
    if ok and b.name == "minecraft:snow" then turtle.digDown() end
    look()
    if near then return true end
  end
  for i = #PATH, 1, -1 do
    walk(PATH[i][1], PATH[i][2])
    look()
    if near then return true end
  end
  goHome()
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
  flyTo(HOME.x, HOME.z, CRUISE)
  state.phase = "home"
  save()
end

setOpen(false)
if turtle.getFuelLevel() < 300 then burn(1000) end
if at(OLD_HOME) then step("n") end
if world().y < HIGH and not at(HOME) then rise(HIGH) end
checkBlock()
if not at(HOME) then goHome() end
print("Home in the vault wall")

local lastSeen, lastSweep = -math.huge, os.clock() - SWEEP_EVERY + 30
while true do
  look()
  if near then
    lastSeen = os.clock()
    if not at(POST) then toPost() end
    setOpen(true)
  elseif open and os.clock() - lastSeen > CLOSE_AFTER then
    setOpen(false)
  end
  if not open and not at(HOME) and os.clock() - lastSeen > HOME_AFTER then goHome() end
  if at(HOME) and not around and os.clock() - lastSweep > SWEEP_EVERY then
    sweep()
    lastSweep = os.clock()
  end
  if at(HOME) and turtle.getFuelLevel() < LOW_FUEL then
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < LOW_FUEL then
      leaveHome()
      fuelStation()
      flyTo(DOORSTEP.x, DOORSTEP.z, CRUISE)
      goHome()
    end
  end
  sleep(0.5)
end
