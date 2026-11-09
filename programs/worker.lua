-- A hand in the hall, run one command at a time through the bridge: go
-- somewhere, look about with a geo scanner, dig. Keeps its world position in
-- /.worker (taken over from movestore's state the first time).
--
-- Usage: worker at                 where it is
--        worker init x y z facing  set its world position (north|east|south|west)
--        worker go x y z [dig]     straight there: up/down first to y, then x,
--                                  then z (dig: dig through what's in the way;
--                                  otherwise turtles are waited for and
--                                  anything else stops it)
--        worker path x y z [cy]    over at height cy (default y + 3): up, x, z, down
--        worker face north|east|south|west
--        worker scan [r]           equips a geo scanner from its inventory on
--                                  the free side, scans (radius r, default 8)
--                                  and writes /scan.txt: "x y z name" per block,
--                                  world coordinates; then swaps back

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.worker"
local DIRS = { north = 0, east = 1, south = 2, west = 3 }
local SCANNER = "advancedperipherals:geo_scanner"

local function fail(msg) error(msg, 0) end

-- nav counts from state.origin with +z north: world = origin + (x, y, -z).
local state = saved.load(STATE)
if not state then
  local ms = saved.load("/.movestore")
  if ms and ms.origin and ms.pos then
    -- movestore's frame starts on the birth spot (origin.z - 1).
    state = { origin = { x = ms.origin.x, y = ms.origin.y, z = ms.origin.z - 1 }, pos = ms.pos, dir = ms.dir }
  end
end
local args = { ... }
local cmd = args[1]
if cmd == "init" then
  local x, y, z, f = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), DIRS[args[5] or ""]
  if not (x and y and z and f) then fail("Usage: worker init x y z north|east|south|west") end
  state = { origin = { x = x, y = y, z = z }, pos = { x = 0, y = 0, z = 0 }, dir = f }
end
if not state then fail("I don't know where I am: worker init x y z facing") end
local function save() saved.save(STATE, state) end
nav.init(state, save)
nav.recover()
save()

local O = state.origin
local function world()
  local p = nav.pos()
  return { x = O.x + p.x, y = O.y + p.y, z = O.z - p.z }
end
local function key(w) return ("%d %d %d"):format(w.x, w.y, w.z) end

local function isMachine(b)
  return b.name:find("^computercraft:turtle") ~= nil or b.name:find("^computercraft:computer") ~= nil
end
local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }

-- One step in a world direction (n e s w u d).
local function step(op, dig)
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(({ n = 0, e = 1, s = 2, w = 3 })[op]) end
  for _ = 1, 60 do
    local ok, b = INSPECT[kind]()
    if not (ok and isMachine(b)) then break end
    sleep(2)
  end
  local ok, b = INSPECT[kind]()
  if ok and isMachine(b) then fail("A turtle stays in my way at " .. key(world())) end
  local opts = dig and { canDig = function(blk) return not isMachine(blk) end } or nil
  local moved, why = nav.move(kind, opts)
  if not moved then fail(("Blocked at %s going %s: %s"):format(key(world()), op, tostring(ok and b.name or why))) end
end

local function goAxis(axis, v, dig)
  while world()[axis] ~= v do
    local w = world()
    local op = axis == "y" and (w.y < v and "u" or "d") or axis == "x" and (w.x < v and "e" or "w") or (w.z < v and "s" or "n")
    step(op, dig)
  end
end

local function goTo(x, y, z, dig)
  goAxis("y", y, dig)
  goAxis("x", x, dig)
  goAxis("z", z, dig)
end

local function scan(r)
  local side
  if not turtle.getEquippedLeft() then side = "left"
  elseif not turtle.getEquippedRight() then side = "right" end
  local slot
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == SCANNER then slot = s break end
  end
  local equipped = (turtle.getEquippedLeft() or {}).name == SCANNER and "left"
    or (turtle.getEquippedRight() or {}).name == SCANNER and "right"
  if not equipped then
    if not side then fail("No free side for the scanner") end
    if not slot then fail("No geo scanner in my inventory") end
    turtle.select(slot)
    if side == "left" then turtle.equipLeft() else turtle.equipRight() end
    turtle.select(1)
    equipped = side
    sleep(0.2)
  end
  local list, err = peripheral.call(equipped, "scanBlocks", r)
  if not list then fail("Scan failed: " .. tostring(err)) end
  local w = world()
  local h = fs.open("/scan.txt", "w")
  local counts = {}
  for _, b in ipairs(list) do
    h.writeLine(("%d %d %d %s"):format(w.x + b.x, w.y + b.y, w.z + b.z, b.name))
    counts[b.name] = (counts[b.name] or 0) + 1
  end
  h.close()
  -- Back into the inventory, so the side stays free.
  if not slot then
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then slot = s break end end
  end
  if slot then
    turtle.select(slot)
    if equipped == "left" then turtle.equipLeft() else turtle.equipRight() end
    turtle.select(1)
  end
  local l = {}
  for name, n in pairs(counts) do l[#l + 1] = n .. " " .. name end
  table.sort(l)
  print(("Scanned %d blocks round %s (r %d) into /scan.txt"):format(#list, key(w), r))
  for _, line in ipairs(l) do print("  " .. line) end
end

if cmd == "at" or cmd == "init" then
  print(("At %s facing %s, fuel %d"):format(key(world()), ({ [0] = "north", "east", "south", "west" })[nav.dir()], turtle.getFuelLevel()))
elseif cmd == "go" then
  goTo(tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), args[5] == "dig")
  print("At " .. key(world()))
elseif cmd == "path" then
  local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  local cy = tonumber(args[5]) or math.max(world().y, y) + 3
  goAxis("y", cy)
  goAxis("x", x)
  goAxis("z", z)
  goAxis("y", y)
  print("At " .. key(world()))
elseif cmd == "face" then
  if not DIRS[args[2] or ""] then fail("face north|east|south|west") end
  nav.face(DIRS[args[2]])
elseif cmd == "scan" then
  scan(tonumber(args[2]) or 8)
else
  print("Usage: worker at | init x y z facing | go x y z [dig] | path x y z [cy] | face dir | scan [r]")
end
