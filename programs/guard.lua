-- Gate guard: hunts monsters round the gate by Otis's shed. A turtle with a
-- diamond sword and an Environment Detector, born at the factory (factory
-- birth guard).
--
-- It flies over to its post a couple of blocks off the path outside the
-- gate and scans round it. A hostile mob within reach of the gate is chased
-- (never more than RANGE blocks from the gate) and struck until it's gone;
-- then the guard goes back to its post. It never strikes when a player or
-- anything peaceful is in front of it, leaves endermen alone (striking one
-- sets it on you), and keeps out of the gate and Doorman's place above it.
-- Above ground it only clears snow and plants; anything else it goes over.
-- When fuel runs low it flies to the factory's fuel station and back.
--
-- Usage: guard   (what autorun runs; resumes after reboots)

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.guard"
local F = { x = 3559, y = 74, z = 4763 }        -- the factory turtle, facing north
local GATE = { x = 3545, y = 72, z = 4746 }     -- the jail door (72-73)
local POST = { x = 3543, y = 72, z = 4744 }     -- outside the gate, off the path
local RANGE = 10                                -- how far from the gate it will chase
local SCAN = 12
local CRUISE = 86                               -- above the crew (80, 82) and Doorman (84)
local LOW_FUEL, FILL_FUEL = 200, 2000

local HOSTILE = { "zombie", "skeleton", "creeper", "spider", "witch", "husk", "stray", "drowned", "phantom",
  "pillager", "vindicator", "evoker", "ravager", "slime", "silverfish", "endermite", "blaze", "ghast",
  "piglin_brute", "hoglin", "zoglin", "wither", "guardian", "vex", "bogged", "breeze", "creaking" }
local NEVER = { "enderman", "player", "villager", "iron_golem", "snow_golem", "wolf", "cat", "fox" }
local SOFT = { "snow", "grass", "fern", "flower", "bush", "sapling", "vine", "dandelion", "poppy" }

local function has(name, words)
  for _, w in ipairs(words) do if name:find(w, 1, true) then return true end end
  return false
end
local function hostile(e) return has(e.name or "", HOSTILE) and not has(e.name or "", NEVER) end
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
local OPS = {
  n = { dx = 0, dz = -1, dir = 0 }, e = { dx = 1, dz = 0, dir = 1 },
  s = { dx = 0, dz = 1, dir = 2 }, w = { dx = -1, dz = 0, dir = 3 },
}
local T = {
  forward = { inspect = turtle.inspect, dig = turtle.dig, attack = turtle.attack },
  up = { inspect = turtle.inspectUp, dig = turtle.digUp, attack = turtle.attackUp },
  down = { inspect = turtle.inspectDown, dig = turtle.digDown, attack = turtle.attackDown },
}

-- Cells it keeps out of: the gate and Doorman's place above it.
local function forbidden(x, y, z) return x == GATE.x and z == GATE.z and y >= GATE.y and y <= GATE.y + 2 end

-- One step, clearing only snow and plants; turtles are waited for a little.
-- A mob in the way is struck. False if it can't go.
local function step(op)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  local w = world()
  local nx, ny, nz = w.x, w.y, w.z
  if kind == "up" then ny = ny + 1 elseif kind == "down" then ny = ny - 1
  else nav.face(OPS[op].dir) nx, nz = nx + OPS[op].dx, nz + OPS[op].dz end
  if forbidden(nx, ny, nz) then return false end
  local t = T[kind]
  for _ = 1, 10 do
    local ok, b = t.inspect()
    if not ok or (b.state and b.state.level) then break end
    if isMachine(b) then sleep(2)
    elseif isSoft(b) then t.dig()
    else return false end
  end
  return (nav.move(kind, {}))
end

local function rise(y)
  while world().y < y do if not step("u") then return false end end
  return true
end

local function sink(y)
  while world().y > y do if not step("d") then return false end end
  return true
end

-- Across at height y to column (x, z), over anything in the way.
local function flyTo(x, z, y)
  rise(y)
  for _, axis in ipairs({ "x", "z" }) do
    local target = axis == "x" and x or z
    while world()[axis] ~= target do
      local op = axis == "x" and (world().x < x and "e" or "w") or (world().z < z and "s" or "n")
      if not step(op) and not step("u") then fail("Boxed in") end
    end
  end
end

-- Next to (x, y, z) on the ground, a step at a time: along the longer
-- axis first, over anything in the way. Stays within RANGE of the gate.
local function toward(x, y, z)
  local w = world()
  local dx, dz = x - w.x, z - w.z
  local order = math.abs(dx) >= math.abs(dz) and { "x", "z" } or { "z", "x" }
  for _, axis in ipairs(order) do
    local d = axis == "x" and dx or dz
    if d ~= 0 then
      local op = axis == "x" and (d > 0 and "e" or "w") or (d > 0 and "s" or "n")
      local nx, nz = w.x + (OPS[op].dx), w.z + (OPS[op].dz)
      if math.abs(nx - GATE.x) <= RANGE and math.abs(nz - GATE.z) <= RANGE then
        if step(op) then return true end
      end
    end
  end
  if dx == 0 and dz == 0 then
    if w.y < y then return step("u") end
    if w.y > y then return step("d") end
    return true
  end
  -- Blocked across: over the top (it comes down once it's over the mob).
  return step("u")
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

local function toPost()
  flyTo(POST.x, POST.z, CRUISE)
  sink(POST.y)
  nav.face(0)
end

---------------------------------------------------------------------------
-- The watch
---------------------------------------------------------------------------

local lastScan = -math.huge
-- Hostile mobs near the gate, nearest first, in world cells; nil if the
-- detector is cooling down.
local function look()
  if os.clock() - lastScan < 2.05 then return nil end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", SCAN)
  if not ok or type(list) ~= "table" then return nil end
  lastScan = os.clock()
  local w, found = world(), {}
  for _, e in ipairs(list) do
    if hostile(e) then
      local m = { x = math.floor(w.x + e.x + 0.5), y = math.floor(w.y + e.y + 0.5), z = math.floor(w.z + e.z + 0.5), name = e.name }
      if math.abs(m.x - GATE.x) <= RANGE + 1 and math.abs(m.z - GATE.z) <= RANGE + 1 then
        m.d = math.abs(m.x - w.x) + math.abs(m.y - w.y) + math.abs(m.z - w.z)
        found[#found + 1] = m
      end
    end
  end
  table.sort(found, function(a, b) return a.d < b.d end)
  return found
end

-- Strikes a mob next to it (or above or below). True if it struck one.
local function strike(m)
  local w = world()
  local dx, dy, dz = m.x - w.x, m.y - w.y, m.z - w.z
  local t
  if dx == 0 and dz == 0 and dy == 1 then t = T.up
  elseif dx == 0 and dz == 0 and dy == -1 then t = T.down
  elseif math.abs(dx) + math.abs(dz) == 1 and dy >= -1 and dy <= 1 then
    nav.face(dx == 1 and 1 or dx == -1 and 3 or dz == 1 and 2 or 0)
    t = T.forward
  end
  if not t then return false end
  return (t.attack())
end

local function hunt(targets)
  local m = targets[1]
  print(("Hunting a %s at %d %d %d"):format((m.name or "?"):gsub("^.*:", ""), m.x, m.y, m.z))
  for _ = 1, 200 do
    if not strike(m) then
      if not toward(m.x, m.y, m.z) then sleep(0.5) end
    end
    local fresh = look()
    if fresh then
      if #fresh == 0 then return end
      m = fresh[1]
    end
    sleep(0.2)
  end
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

if state.phase == "orient" then
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
  while world().z > F.z - 5 do
    if not (step("n") or step("u")) then sleep(5) end
  end
  toPost()
  state.phase = "watch"
  save()
  print("On watch at the gate")
end

local function atPost() local w = world() return w.x == POST.x and w.y == POST.y and w.z == POST.z end
-- Back to the post on foot after a hunt, or by air if that doesn't work.
local function back()
  for _ = 1, 60 do
    if atPost() then nav.face(0) return end
    if not toward(POST.x, POST.y, POST.z) then break end
  end
  if not atPost() then toPost() end
end

while true do
  local targets = look()
  if targets and #targets > 0 then
    hunt(targets)
    back()
  end
  if turtle.getFuelLevel() < LOW_FUEL then
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < LOW_FUEL then
      fuelStation()
      toPost()
    end
  end
  sleep(0.5)
end
