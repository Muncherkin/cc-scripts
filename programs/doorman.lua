-- Doorman: keeps the gate in the iron-bar fence by Otis's shed and the vault
-- door. A mining turtle with an Environment Detector, born at the factory
-- (factory birth doorman).
--
-- It rests in a hole in the vault's wall (3548 73 4755), looking out east,
-- and only moves when someone needs it:
--   anyone at the gate (a jail door at 3545 72-73 4747): it stands inside
--     the yard in front of the block east of the gate (3546 73 4748), facing
--     west, and powers that block from its right side, which opens the gate
--   the owner at the vault door (3547 72-73 4753): the same at the block
--     east of that door, from 3548 73 4752 facing west
--   nobody about: home, and now and then it walks the path from the vault
--     door to the gate just above it, digging the snow off
-- It keeps to its home height (y 73) and breaks nothing but the path's
-- snow. At home its own scan (radius 8: wider ones cost hundreds of fuel)
-- reaches only into the gateway, so it also asks a Player Detector placed
-- against its home, if there is one, whether anyone is round the gate. Turtles
-- can also tell it through the bridge (a relay "gate_player" event). Routes go
-- round the waystone and the vault (surveyed with programs/survey.lua). Every
-- step it can't take is noted in /.doorman.log.
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
local GATE_POST = { x = 3546, y = Y, z = 4748 }   -- in front of the block east of it; faces west, the block on its right
-- Round the gate, inside and out: a player in here wants it (Player Detector).
local GATE_AREA = { { x = 3545, y = 71, z = 4746 }, { x = 3545, y = 74, z = 4748 } }
local VAULT = { x = 3547, y = 72, z = 4753 }      -- the vault door (72-73)
local VAULT_POST = { x = 3548, y = Y, z = 4752 }  -- in front of the block east of it; faces west, the block on its left

-- Waypoints at its height, joined by straight runs that are all open air
-- (checked against a survey): out of home, round the vault's east side to
-- the vault door, then north along the path's east edge (x 3548, the near
-- side of the waystone) to the gate.
local NODES = {
  home = { 3548, 4755 }, step = { 3549, 4755 }, mid = { 3549, 4752 }, vault = { 3548, 4752 },
  nw = { 3548, 4748 }, gate = { 3546, 4748 },
}
local LINKS = {
  { "home", "step" }, { "step", "mid" }, { "mid", "vault" }, { "vault", "nw" }, { "nw", "gate" },
}

-- The path from the vault door to the gate: snow lies on it at y 72.
local PATH = {
  { 3548, 4751 }, { 3547, 4751 }, { 3548, 4750 }, { 3547, 4750 }, { 3548, 4749 },
  { 3547, 4749 }, { 3546, 4749 }, { 3547, 4748 }, { 3546, 4748 }, { 3545, 4748 },
}

local CRUISE = 84                                 -- flying in from the factory, above the crew
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
local function run(x, z, abort)
  for _ = 1, 64 do
    local w = world()
    if w.x == x and w.z == z then return true end
    if abort and abort() then return false end
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

-- To waypoint `to` by the waypoints, at its height. With abort, checked
-- at every step, it stops short when that says so (false).
local function goNode(to, abort)
  if world().y > Y then
    sink(Y)
  end
  if world().y < Y then rise(Y) end
  local here = nearest()
  if not run(NODES[here][1], NODES[here][2], abort) then return false end
  for _, n in ipairs(route(here, to)) do
    if not run(NODES[n][1], NODES[n][2], abort) then return false end
  end
  return true
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

-- The cells right in front of the doors (feet): a player standing there
-- wants that door opened. The gate: outside, in the gateway, inside.
local GATE_FRONT = { { 3545, 4746 }, { 3545, 4747 }, { 3545, 4748 } }
local VAULT_FRONT = { { 3547, 4752 } }
local function standsAt(p, cells)
  local bx, by, bz = math.floor(p.x), math.floor(p.y + 0.5), math.floor(p.z)
  if by < 71 or by > 73 then return false end
  for _, c in ipairs(cells) do if bx == c[1] and bz == c[2] then return true end end
  return false
end
local function far(p, cells)
  local c = cells[math.ceil(#cells / 2)]
  return math.abs(p.x - (c[1] + 0.5)) + math.abs(p.z - (c[2] + 0.5))
end
local nearer = nil      -- the door the player who called it is nearer to now
local around = false    -- anyone in sight

-- A scan (radius 8 costs no fuel): who is at which door.
-- A Player Detector against its home, if it's there.
local function playerDetector()
  for _, side in ipairs({ "back", "bottom", "top", "front" }) do
    if peripheral.hasType(side, "player_detector") or peripheral.hasType(side, "playerDetector") then return side end
  end
end

local function look()
  -- At home, a Player Detector sees the whole of round the gate for free.
  if at(HOME) then
    local pd = playerDetector()
    if pd then
      local ok, any = pcall(peripheral.call, pd, "isPlayersInCoords", GATE_AREA[1], GATE_AREA[2])
      if ok and any then seen.gate = os.clock() end
    end
  end
  if os.clock() - lastScan < 2.05 then return end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", 8)
  if not ok or type(list) ~= "table" then return end
  lastScan = os.clock()
  local w = world()
  around, nearer = false, nil
  local best = math.huge
  for _, e in ipairs(list) do
    if e.name == "minecraft:player" or e.isPlayer then
      around = true
      local p = { x = w.x + 0.5 + e.x, y = w.y + e.y, z = w.z + 0.5 + e.z }
      if standsAt(p, GATE_FRONT) then seen.gate = os.clock() end
      local owner = e.uuid == OWNER
      if owner and standsAt(p, VAULT_FRONT) then seen.vault = os.clock() end
      -- Which door is this player nearer? (Only its owner counts for the vault.)
      local dg, dv = far(p, GATE_FRONT), owner and far(p, VAULT_FRONT) or math.huge
      local d, door = math.min(dg, dv), dv < dg and "vault" or "gate"
      if d < best then best, nearer = d, door end
    end
  end
end

-- Waits up to t seconds, taking in notes about the gate meanwhile.
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
    if at(GATE_POST) then nav.face(3) redstone.setOutput("right", true) end
    if at(VAULT_POST) then nav.face(3) redstone.setOutput("left", true) end
  else
    for _, side in ipairs({ "bottom", "left", "right" }) do redstone.setOutput(side, false) end -- bottom: the old gate post
  end
  open = on
  print(on and ("Opening the " .. (at(GATE_POST) and "gate" or "vault door")) or "Shut")
end

-- To a door's post. It looks out at every step: if the player turns
-- towards the other door, it stops (false) so it can go there instead.
local function toDoor(door)
  local function turned() look() return around and nearer ~= nil and nearer ~= door end
  if not goNode(door, turned) then return false end
  nav.face(3) -- at both doors it looks west: the gate's block on its right, the vault's on its left
  return true
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
  -- the doorstep east of the vault and down.
  while world().z > F.z - 5 do
    if not (step("n") or step("u")) then sleep(5) end
  end
  flyTo(NODES.step[1], NODES.step[2], CRUISE)
  sink(Y)
  state.phase = "home"
  save()
end

power(false)
if turtle.getFuelLevel() < 300 then burn(1000) end
if not at(HOME) then goHome() end
print("Home")

local where = "home"   -- home, gate, vault, or path (between)
local trip = nil       -- the door it's been called to
local lastSweep = os.clock() - SWEEP_EVERY + 60
while true do
  look()
  local called = (want("vault", LINGER) and "vault") or (want("gate", LINGER) and "gate") or nil
  -- Someone at a door calls it; on the way, it follows whichever door the
  -- player is nearer to.
  if called and not trip then trip = called end
  if trip and around and nearer then trip = nearer end
  if trip and where ~= trip then
    power(false)
    where = "path"
    if toDoor(trip) then where = trip end
  end
  if trip and where == trip then power(want(trip, LINGER)) end
  -- Nobody at a door for a while and nobody about: home.
  if trip and not called and not around and not want(trip, HOME_AFTER) then
    power(false)
    goHome()
    trip, where = nil, "home"
  end
  if not trip and where ~= "home" then goHome() where = "home" end
  if where == "home" and os.clock() - lastSweep > SWEEP_EVERY then
    sweep()
    lastSweep = os.clock()
    if not at(HOME) then where = "path" end
  end
  if where == "home" and turtle.getFuelLevel() < LOW_FUEL then
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < LOW_FUEL then
      fuelStation()
      flyTo(NODES.step[1], NODES.step[2], CRUISE)
      sink(Y)
      goHome()
    end
  end
  wait(0.5)
end
