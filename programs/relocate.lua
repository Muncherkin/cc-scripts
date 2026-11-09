-- The factory turtle moves herself into the Engine Hall (docs/factory-move.md):
-- once the Mover has built the hall factory and carried her storage down,
-- she flies there on her own. A crafty turtle can't dig, so she keeps to
-- the lanes: north off the birth spot to the Mover's lane, up to y 80, over
-- to the service shaft, down it and in at y 6, over to the column above the
-- hall's birth spot, down it, and south into her place. Then she faces north.
--
-- Stop `factory run` first (it's her autorun): she leaves her storage
-- behind. Afterwards set lib/home's `at` to "hall", sync, and reboot her.
--
-- Usage: relocate          (resumes after a reboot)
--        relocate force    without waiting for the evacuation to be done

local nav = require("lib.nav")
local saved = require("lib.state")
local home = require("lib.home")
local way = require("lib.way")

local STATE = "/.relocate"
local OUT = 80             -- surface flying height, to the shaft
local LANE = 4             -- the Mover's lane: down the column 4 north of her, then south

local function fail(msg) error(msg, 0) end
local function key(w) return ("%d %d %d"):format(w.x, w.y, w.z) end

local state = saved.load(STATE)
local fresh = state == nil
state = state or { phase = "check" }
local function save() saved.save(STATE, state) end
nav.init(state, save)
nav.recover()
state.from = state.from or home.copy(home.surface)
state.to = state.to or home.copy(home.hall)
save()

-- nav counts from where she started, facing north: +z north, +x east.
local O, H = state.from, state.to
local function world()
  local p = nav.pos()
  return { x = O.x + p.x, y = O.y + p.y, z = O.z - p.z }
end

local DIRS = { n = 0, e = 1, s = 2, w = 3 }
local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local function isMachine(b)
  return b.name:find("^computercraft:turtle") ~= nil or b.name:find("^computercraft:computer") ~= nil
end

local function step(op)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIRS[op]) end
  local ok, b = INSPECT[kind]()
  if ok and isMachine(b) then return false, "turtle" end
  local moved, why = nav.move(kind)
  if moved then return true end
  if ok then return false, b.name end
  return false, why
end

local go = { step = step, pos = world, face = function(op) nav.face(DIRS[op]) end }

-- What the trip costs, with room to spare.
local function cost()
  local S = home.shaft
  return (OUT - O.y) + LANE + math.abs(O.x - S.x) + math.abs(O.z - LANE - S.z) + (OUT - home.hallIn)
    + math.abs(S.x - H.x) + math.abs(S.z - H.z) + (home.hallIn - H.y) + 2 + 50
end

if state.phase == "check" then
  if fresh and turtle.getFuelLevel() < cost() then
    for slot = 1, 16 do
      turtle.select(slot)
      turtle.refuel()
    end
    turtle.select(1)
  end
  if turtle.getFuelLevel() < cost() then
    fail(("Not enough fuel to move (%d of %d): put coal in me"):format(turtle.getFuelLevel(), cost()))
  end
  local ev = fs.open("/.factory/evacuate", "r")
  local done = ev and (textutils.unserialise(ev.readAll()) or {}).done
  if ev then ev.close() end
  if not done and ... ~= "force" then
    fail("The evacuation isn't done yet (factory evacuate): wait for it, or relocate force")
  end
  state.phase = "out"
  save()
end

if state.phase == "out" then
  print(("Leaving %s for the hall"):format(key(world())))
  -- North off the birth spot to the lane, then up.
  while world().z > O.z - LANE do
    local ok, why = step("n")
    if not ok then
      if why ~= "turtle" then fail(("Can't get to the lane at %s: %s"):format(key(world()), tostring(why))) end
      sleep(5)
    end
  end
  way.toHall(go, OUT)
  state.phase = "in"
  save()
end

if state.phase == "in" then
  -- Down the column above the hall's birth spot, then south into place.
  way.toStation(go, H)
  while world().z < H.z do
    local ok, why = step("s")
    if not ok then
      if why ~= "turtle" then fail(("Can't get into my place at %s: %s"):format(key(world()), tostring(why))) end
      sleep(5)
    end
  end
  nav.face(DIRS.n)
  state.phase = "done"
  save()
end

print(("In the hall at %s, facing north (fuel %d)"):format(key(world()), turtle.getFuelLevel()))
