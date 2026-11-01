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
-- Modes, set from Keeper's menu (a "doorman_mode" note through the bridge):
--   home     stays home: no doors, no sweeping
--   normal   the gate for anyone, the vault for registered people
--   greeter  both doors for anyone
--   members  both doors for registered people only
--   sweep    no doors: clears the path right away and again every ten
--            minutes, waiting at home in between; a player on the path is
--            waited for, not a reason to stop
--   guard    no doors: it posts itself at the vault door and strikes any
--            creature near it that isn't a registered person (with its
--            sword)
-- A mode holds until another is set, through reboots.
-- A "doorman_register" note adds whoever stands in front of the vault door
-- to the registered people.
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

-- The path, swept at y 72 in this order: two overlapping 2x3 areas, each
-- three out from a door on its left (looking out of it). In front of the
-- vault door x 3546-3547, z 4750-4752; inside the gate x 3545-3546,
-- z 4748-4750. Each cell is next to the one before.
local PATH = {
  { 3547, 4752 }, { 3546, 4752 }, { 3546, 4751 }, { 3547, 4751 }, { 3547, 4750 }, { 3546, 4750 },
  { 3545, 4750 }, { 3545, 4749 }, { 3546, 4749 }, { 3546, 4748 }, { 3545, 4748 },
}

local CRUISE = 84                                 -- flying in from the factory, above the crew
local LINGER = 4                                  -- seconds a door stays open after they've gone
local HOME_AFTER = 20                             -- seconds idle at a door before going home
local GIVE_UP = 6                                 -- seconds nobody's been at a door before a trip is dropped
local SWEEP_EVERY = 600                           -- seconds between rounds in sweep mode
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
-- What lies on the path and may go: snow, and low plants (frozen grass
-- and the like). Walking into it breaks it; what won't give way is cut
-- (only when clearing the path).
local function cover(b)
  return b.name == "minecraft:snow" or b.name:find("frozen_grass", 1, true) ~= nil
    or b.name == "minecraft:short_grass" or b.name == "minecraft:grass" or b.name == "minecraft:fern"
end
local DIG = { forward = turtle.dig, up = turtle.digUp, down = turtle.digDown }

-- One step; onPath: clearing the path, so cover in the way may go.
local function step(op, onPath)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIRS[op]) end
  local onCover = false
  for _ = 1, 30 do
    local ok, b = T[kind].inspect()
    if not ok or (b.state and b.state.level) or b.name == "minecraft:snow" then break end
    if onPath and cover(b) then onCover = true break end
    if b.name:find("^computercraft:turtle") then sleep(2)
    else note(op, b.name) return false end
  end
  if nav.move(kind, {}) then return true end
  if onCover or onPath then
    local ok, b = T[kind].inspect()
    if ok and cover(b) and DIG[kind]() then return (nav.move(kind, {})) end
    -- Nothing there but it won't go: someone standing on the path. Wait
    -- for them to step off (half a minute at most).
    for _ = 1, 15 do
      if T[kind].inspect() then break end
      sleep(2)
      if nav.move(kind, {}) then return true end
    end
  end
  return false
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
  -- The lane in is one block wide and turtles leave by it too: if one is in
  -- the way, back out and up, wait a while and try again.
  while true do
    flyTo(F.x, F.z - 4, CRUISE)
    sink(F.y)
    while world().z < F.z - 1 and step("s") do end
    if world().z == F.z - 1 then break end
    print("A turtle is at the fuel station; making way")
    while world().z > F.z - 4 do step("n") end
    rise(F.y + 5)
    sleep(20 + math.random(20))
  end
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

-- The cells right in front of the doors (feet): a player standing there,
-- or within REACH blocks of one, wants that door opened. The gate: outside,
-- in the gateway, inside.
local REACH = 1
local GATE_FRONT = { { 3545, 4746 }, { 3545, 4747 }, { 3545, 4748 } }
local VAULT_FRONT = { { 3547, 4752 } }
local function standsAt(p, cells)
  local bx, by, bz = math.floor(p.x), math.floor(p.y + 0.5), math.floor(p.z)
  if by < 71 or by > 73 then return false end
  for _, c in ipairs(cells) do
    if math.abs(bx - c[1]) <= REACH and math.abs(bz - c[2]) <= REACH then return true end
  end
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

local MODES = { home = true, normal = true, greeter = true, members = true, guard = true, sweep = true }
local function mode() return state.mode or "normal" end
local function rules() return mode() end
local sweepNow = true -- a round due as soon as it's in sweep mode
local function member(uuid)
  if uuid == OWNER then return true end
  for _, u in ipairs(state.members or {}) do if u == uuid then return true end end
  return false
end
-- Who may have each door opened in each mode.
local function allowed(door, uuid)
  local m = rules()
  if m == "greeter" then return true end
  if m == "normal" then return door == "gate" or member(uuid) end
  if m == "members" then return member(uuid) end
  return false -- home, guard
end
local atVault = nil   -- the uuid of the player standing at the vault door
local intruders = {}  -- in guard mode: creatures near the vault door

local function look()
  -- At home, a Player Detector sees the whole of round the gate for free
  -- (it can't tell who, so only where the gate is for anyone).
  if at(HOME) then
    local pd = playerDetector()
    if pd then
      local ok, any = pcall(peripheral.call, pd, "isPlayersInCoords", GATE_AREA[1], GATE_AREA[2])
      if ok and any and (rules() == "normal" or rules() == "greeter") then seen.gate = os.clock() end
    end
  end
  if os.clock() - lastScan < 2.05 then return end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", 8)
  if not ok or type(list) ~= "table" then return end
  lastScan = os.clock()
  local w = world()
  around, nearer, atVault, intruders = false, nil, nil, {}
  local best = math.huge
  for _, e in ipairs(list) do
    local p = { x = w.x + 0.5 + e.x, y = w.y + e.y, z = w.z + 0.5 + e.z }
    local player = e.name == "minecraft:player" or e.isPlayer
    if player then
      around = true
      if standsAt(p, VAULT_FRONT) then atVault = e.uuid end
      local g, v = allowed("gate", e.uuid), allowed("vault", e.uuid)
      if g and standsAt(p, GATE_FRONT) then seen.gate = os.clock() end
      if v and standsAt(p, VAULT_FRONT) then seen.vault = os.clock() end
      -- Which door is this player nearer, of the ones it may have opened?
      local dg, dv = g and far(p, GATE_FRONT) or math.huge, v and far(p, VAULT_FRONT) or math.huge
      local d = math.min(dg, dv)
      if d < best and d < math.huge then best, nearer = d, dv < dg and "vault" or "gate" end
    end
    -- Guard: anything alive near the vault door that isn't a registered person.
    if e.health and not (player and member(e.uuid)) and math.abs(p.x - 3547.5) <= 3 and math.abs(p.z - 4752.5) <= 3
      and p.y > 70 and p.y < 76 then
      intruders[#intruders + 1] = p
    end
  end
end

-- Waits up to t seconds, taking in notes about the gate meanwhile.
local function wait(t)
  local timer = os.startTimer(t)
  while true do
    local ev, a, b = os.pullEvent()
    if ev == "timer" and a == timer then return end
    if ev == "bridge_push" and a == "gate_player" and (rules() == "normal" or rules() == "greeter") then seen.gate = os.clock() end
    if ev == "bridge_push" and a == "doorman_mode" and type(b) == "table" and MODES[b.mode] then
      if b.mode == "sweep" then sweepNow = true end
      state.mode = b.mode
      save()
      -- Keeper keeps sending until it hears back: notes can be lost while
      -- a turtle moves or scans.
      os.queueEvent("bridge_send", { action = "relay", to = "Keeper", event = "doorman_ack", data = { mode = b.mode } })
      seen.gate, seen.vault = -math.huge, -math.huge -- a new mode: nobody's call stands
      print("Mode: " .. b.mode)
    end
    if ev == "bridge_push" and a == "doorman_register" then
      os.queueEvent("bridge_send", { action = "relay", to = "Keeper", event = "doorman_ack", data = { registered = atVault ~= nil } })
      if atVault and not member(atVault) then
        state.members = state.members or {}
        table.insert(state.members, atVault)
        save()
        print("Registered " .. atVault)
      end
    end
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
local function toDoor(door, posting)
  local function turned()
    if posting then return false end -- guard duty: goes there regardless
    look()
    -- The player went for the other door, or isn't at either any more.
    return (around and nearer ~= nil and nearer ~= door) or not (want("gate", GIVE_UP) or want("vault", GIVE_UP))
  end
  if not goNode(door, turned) then return false end
  nav.face(3) -- at both doors it looks west: the gate's block on its right, the vault's on its left
  return true
end

-- The sword for guarding: on the side that isn't the environment detector,
-- swapped in from the inventory if it's carried rather than held.
local function toolSide()
  return detector == "left" and "right" or "left"
end
local function holding(part)
  local get = toolSide() == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
  local r = get and get()
  return r and r.name:find(part, 1, true) ~= nil
end
local function wield(part)
  if holding(part) then return true end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name:find(part, 1, true) then
      turtle.select(slot)
      local ok = (toolSide() == "left" and turtle.equipLeft or turtle.equipRight)()
      turtle.select(1)
      return ok
    end
  end
  return false
end

-- Strikes whatever is next to it (not a registered person: those never
-- count as intruders). True if it hit something.
local FACE = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
local function strike()
  local w = world()
  for _, p in ipairs(intruders) do
    local dx, dz = p.x - (w.x + 0.5), p.z - (w.z + 0.5)
    if math.abs(dx) + math.abs(dz) < 1.9 and p.y > w.y - 2.5 and p.y < w.y + 1 then
      local best, bd = 3, -math.huge
      for d = 0, 3 do
        local dot = FACE[d][1] * dx + FACE[d][2] * dz
        if dot > bd then best, bd = d, dot end
      end
      nav.face(best)
      local hit = turtle.attack()
      if hit then print("Struck an intruder") return true end
    end
  end
  return false
end

-- Clearing the path: down onto it at the vault end, along it at a player's
-- height walking into the snow (a thin layer breaks; it digs nothing), back up by the gate
-- post and home. Says what it cleared and where it couldn't get to. A
-- player coming to a door breaks it off.
local function sweep()
  print("Clearing the path")
  goNode("vault")
  local cleared, missed = 0, {}
  local function snow(inspect)
    local ok, b = inspect()
    if ok and cover(b) then cleared = cleared + 1 end
  end
  local function called() return mode() ~= "sweep" end
  run(PATH[1][1], PATH[1][2])
  snow(turtle.inspectDown)
  if step("d", true) then
    for _, c in ipairs(PATH) do
      for _ = 1, 4 do
        local w = world()
        if w.x == c[1] and w.z == c[2] then break end
        local op = w.x ~= c[1] and (w.x < c[1] and "e" or "w") or (w.z < c[2] and "s" or "n")
        nav.face(DIRS[op])
        snow(turtle.inspect)
        if not step(op, true) then break end
      end
      local w = world()
      if w.x ~= c[1] or w.z ~= c[2] then missed[#missed + 1] = c[1] .. " " .. c[2] end
      if called() then break end
    end
    -- Up where it's sure of room: the gate post, or wherever it is.
    local w = world()
    if w.x ~= GATE_POST.x or w.z ~= GATE_POST.z then run(GATE_POST.x, GATE_POST.z) end
    rise(Y)
  else
    missed[#missed + 1] = "the whole path (couldn't get down onto it)"
  end
  print(("Cleared %d (snow and plants)%s"):format(cleared, #missed > 0 and ("; couldn't reach " .. table.concat(missed, ", ")) or ""))
  if #missed > 0 then note("sweep", "missed " .. table.concat(missed, ", ")) end
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
local lastSweep = -math.huge
while true do
  -- Fuel before anything else, whatever the mode and wherever it is.
  if turtle.getFuelLevel() < LOW_FUEL then
    burn(FILL_FUEL)
    if turtle.getFuelLevel() < LOW_FUEL then
      power(false)
      trip = nil
      fuelStation()
      flyTo(NODES.step[1], NODES.step[2], CRUISE)
      sink(Y)
      goHome()
      where = "home"
    end
  end
  look()
  local m = mode()
  if m == "sweep" then
    -- Doors shut; a round now and then, home in between.
    power(false)
    trip = nil
    if sweepNow or os.clock() - lastSweep > SWEEP_EVERY then
      sweepNow = false
      sweep()
      lastSweep = os.clock()
      where = "path"
    end
    if where ~= "home" then goHome() where = "home" end
  elseif m == "guard" then
    -- Posted at the vault door, sword in hand, doors shut.
    power(false)
    trip = nil
    if where ~= "vault" then
      if toDoor("vault", true) then where = "vault" else where = "path" end
      wield("sword")
    end
    strike()
  else
    -- Home mode: straight home, whatever it was doing.
    if m == "home" then trip = nil end
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
    -- Called but nobody's at a door any more before it got there: home.
    if trip and where ~= trip and not (want("gate", GIVE_UP) or want("vault", GIVE_UP)) then trip = nil end
    -- Nobody at its door for a while: home.
    if trip and not called and not want(trip, HOME_AFTER) then
      power(false)
      goHome()
      trip, where = nil, "home"
    end
    if not trip and where ~= "home" then power(false) goHome() where = "home" end
  end
  wait(0.5)
end
