-- Doorman: keeps the gate in the iron-bar fence by Otis's shed and the vault
-- door. A mining turtle with an Environment Detector, born at the factory
-- (factory birth doorman).
--
-- It rests in a hole in the vault's wall (3548 73 4755), looking out east,
-- and only moves when someone needs it:
--   anyone at the gate (a jail door at 3545 72-73 4747): it stands on the
--     solid block above the gate and powers it, which opens the door below
--   the owner at the vault door (3547 72-73 4753): it stands in front of the
--     block east of that door (3548 73 4752) and powers it, which opens it
--   nobody about: home, and now and then it walks the path from the vault
--     door to the gate just above it, digging the snow off
-- It keeps to its home height (y 73) except on the gate. It breaks nothing
-- but the path's snow. Its own scans reach only so far outside the gate, so
-- Warden, posted outside, tells it (through the bridge) when a player is
-- coming to the gate. Routes go round the waystone and the vault (surveyed
-- with programs/survey.lua). Every step it can't take is noted in
-- /.doorman.log.
--
-- Usage: doorman   (what autorun runs; resumes after reboots)

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE, LOG = "/.doorman", "/.doorman.log"
local F = { x = 3559, y = 74, z = 4763 }          -- the factory turtle, facing north
local OWNER = "f725aa4e-d936-3b45-bc95-0962562e7d67" -- the player the vault opens for
local Y = 73                                      -- its home height, kept everywhere but on the gate

local HOME = { x = 3548, y = Y, z = 4755 }        -- a hole in the vault's wall
local GATE = { x = 3545, y = 72, z = 4747 }       -- the jail door (72-73)
local GATE_TOP = { x = 3545, y = 75, z = 4747 }   -- on the solid block above it
local VAULT = { x = 3547, y = 72, z = 4753 }      -- the vault door (72-73)
local VAULT_POST = { x = 3548, y = Y, z = 4752 }  -- in front of the block east of it; faces south

-- Waypoints at its height, joined by straight runs that are all open air
-- (checked against a survey): round the vault's east side and the waystone.
local NODES = {
  home = { 3548, 4755 }, step = { 3549, 4755 }, east = { 3550, 4755 }, ne = { 3550, 4748 },
  gate = { 3545, 4748 }, mid = { 3549, 4752 }, vault = { 3548, 4752 }, west = { 3545, 4752 },
}
local LINKS = {
  { "home", "step" }, { "step", "east" }, { "east", "ne" }, { "ne", "gate" },
  { "step", "mid" }, { "mid", "vault" }, { "gate", "west" }, { "west", "vault" },
}

-- The path from the vault door to the gate: snow lies on it at y 72.
local PATH = {
  { 3548, 4751 }, { 3547, 4751 }, { 3548, 4750 }, { 3547, 4750 }, { 3548, 4749 },
  { 3547, 4749 }, { 3546, 4749 }, { 3547, 4748 }, { 3546, 4748 }, { 3545, 4748 },
}

local CRUISE = 84                                 -- flying in from the factory, above the crew
local NEAR = 3                                    -- a player this close to a door (x and z) wants it
local SWEEP_EVERY = 600                           -- seconds between snow rounds
local LINGER = 4                                  -- seconds a door stays open after they've gone
local HOME_AFTER = 20                             -- seconds idle at a door before going home
local LOW_FUEL, FILL_FUEL = 200, 2000

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
  forward = { inspect = turtle.inspect }, up = { inspect = turtle.inspectUp }, down = { inspect = turtle.inspectDown },
}

-- Notes a step it couldn't take, so its routes can be put right.
local function note(op, what)
  local w = world()
  local h = fs.open(LOG, fs.exists(LOG) and fs.getSize(LOG) < 8000 and "a" or "w")
  h.writeLine(("%d %d %d %s blocked by %s"):format(w.x, w.y, w.z, op, what))
  h.close()
end

-- One step. It breaks nothing: turtles in the way are waited for a little,
-- anything else is noted and the step refused.
local function step(op)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIRS[op]) end
  for _ = 1, 30 do
    local ok, b = T[kind].inspect()
    if not ok or (b.state and b.state.level) then break end
    if b.name:find("^computercraft:turtle") then sleep(2)
    else note(op, b.name) return false end
  end
  return (nav.move(kind, {}))
end

local function rise(y)
  for _ = 1, 64 do
    if world().y >= y then return true end
    if not step("u") then
      if not (step("n") or step("e") or step("s") or step("w")) then return false end
    end
  end
  return false
end
local function sink(y)
  while world().y > y do if not step("d") then return false end end
  return true
end

-- Straight along one axis to (x, z) at its height; round anything in the
-- way by a step to the side if it must.
local function run(x, z)
  for _ = 1, 64 do
    local w = world()
    if w.x == x and w.z == z then return true end
    local op = w.x ~= x and (w.x < x and "e" or "w") or (w.z < z and "s" or "n")
    if not step(op) then
      local side = (op == "e" or op == "w") and { "s", "n" } or { "e", "w" }
      if not (step(side[1]) or step(side[2])) then return false end
    end
  end
  return false
end

-- The nearest waypoint, and the shortest way between waypoints.
local function dist(a, b) return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) end
local function nearest()
  local w, best, bd = world(), nil, math.huge
  for name, n in pairs(NODES) do
    local d = dist(n, { w.x, w.z })
    if d < bd then best, bd = name, d end
  end
  return best
end
local function route(from, to)
  local d, prev, todo = { [from] = 0 }, {}, { from }
  while #todo > 0 do
    table.sort(todo, function(a, b) return d[a] < d[b] end)
    local u = table.remove(todo, 1)
    for _, l in ipairs(LINKS) do
      local v = l[1] == u and l[2] or (l[2] == u and l[1])
      if v then
        local nd = d[u] + dist(NODES[u], NODES[v])
        if d[v] == nil or nd < d[v] then d[v], prev[v] = nd, u todo[#todo + 1] = v end
      end
    end
  end
  local out, v = {}, to
  while v and v ~= from do table.insert(out, 1, v) v = prev[v] end
  return out
end

-- To waypoint `to` by the waypoints, at its height.
local function goNode(to)
  if world().y > Y then
    if at(GATE_TOP) then step("s") end
    sink(Y)
  end
  if world().y < Y then rise(Y) end
  local here = nearest()
  run(NODES[here][1], NODES[here][2])
  for _, n in ipairs(route(here, to)) do run(NODES[n][1], NODES[n][2]) end
end

local function goHome()
  goNode("home")
  nav.face(1) -- looking out east
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
-- Watching the doors
---------------------------------------------------------------------------

local lastScan = -math.huge
local seen = { gate = -math.huge, vault = -math.huge } -- when someone was last at each
local warned = false

local function close(p, door) return math.abs(p.x - door.x) <= NEAR and math.abs(p.z - door.z) <= NEAR and math.abs(p.y - door.y) <= 4 end

-- A scan (radius 8 costs no fuel): who is at which door.
local function look()
  if os.clock() - lastScan < 2.05 then return end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", 8)
  if not ok or type(list) ~= "table" then return end
  lastScan = os.clock()
  local w = world()
  for _, e in ipairs(list) do
    if e.name == "minecraft:player" or e.isPlayer then
      local p = { x = w.x + 0.5 + e.x, y = w.y + e.y, z = w.z + 0.5 + e.z }
      if close(p, GATE) then seen.gate = os.clock() end
      if e.uuid == OWNER and close(p, { x = VAULT.x, y = VAULT.y, z = VAULT.z - 1 }) then seen.vault = os.clock() end
    end
  end
end

-- Waits up to t seconds, taking in Warden's notes about the gate meanwhile.
local function wait(t)
  local timer = os.startTimer(t)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then return end
    if ev == "bridge_push" and a == "gate_player" then seen.gate = os.clock() end
  end
end

local function want(door, linger) return os.clock() - seen[door] <= linger end

-- At a door: its block powered while someone is there.
local open = nil
local function power(on)
  if on == open then return end
  if on then
    if at(GATE_TOP) then redstone.setOutput("bottom", true) end
    if at(VAULT_POST) then nav.face(2) redstone.setOutput("front", true) end
  else
    for _, side in ipairs({ "bottom", "front" }) do redstone.setOutput(side, false) end
  end
  open = on
  print(on and ("Opening the " .. (at(GATE_TOP) and "gate" or "vault door")) or "Shut")
end

local function toGate()
  goNode("gate")
  rise(GATE_TOP.y)
  step("n")
  if not at(GATE_TOP) then print("Couldn't get onto the block above the gate") end
end

local function toVault()
  goNode("vault")
  nav.face(2)
end

-- Along the path just above it, digging the snow off, and home. A player
-- coming to either door breaks it off.
local function sweep()
  print("Clearing the path")
  goNode("vault")
  for _, c in ipairs(PATH) do
    run(c[1], c[2])
    local ok, b = turtle.inspectDown()
    if ok and b.name == "minecraft:snow" then turtle.digDown() end
    look()
    if want("gate", 1) or want("vault", 1) then return end
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
  -- North off the birth spot (the cobble generator is over it), then over
  -- to the east of the vault and down.
  while world().z > F.z - 5 do
    if not (step("n") or step("u")) then sleep(5) end
  end
  flyTo(NODES.east[1], NODES.east[2], CRUISE)
  sink(Y)
  state.phase = "home"
  save()
end

power(false)
if turtle.getFuelLevel() < 300 then burn(1000) end
if not at(HOME) then goHome() end
print("Home")

local where = "home"
local lastSweep = os.clock() - SWEEP_EVERY + 60
while true do
  look()
  -- Where it should be: the owner at the vault door first, then the gate.
  local target = (want("vault", LINGER) and "vault") or (want("gate", LINGER) and "gate") or nil
  if target and target ~= where then
    power(false)
    if target == "vault" then toVault() else toGate() end
    where = target
  end
  if where == "path" and not target then goHome() where = "home" end
  if where ~= "home" then
    power(where == target)
    -- Nobody for a while: home.
    if not target and not want(where, HOME_AFTER) then
      power(false)
      goHome()
      where = "home"
    end
  end
  if where == "home" and os.clock() - lastSweep > SWEEP_EVERY then
    sweep()
    lastSweep = os.clock()
    if not at(HOME) then where = "path" end
  end
  if where == "home" and turtle.getFuelLevel() < LOW_FUEL then
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < LOW_FUEL then
      fuelStation()
      flyTo(NODES.east[1], NODES.east[2], CRUISE)
      sink(Y)
      goHome()
    end
  end
  wait(0.5)
end
