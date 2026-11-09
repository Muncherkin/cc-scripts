-- A hand in the hall, run one command at a time through the bridge: go
-- somewhere, look about with a geo scanner, dig. Keeps its world position in
-- /.worker (taken over from movestore's state the first time).
--
-- Usage: worker at                 where it is
--        worker init x y z facing  set its world position (north|east|south|west)
--        worker go x y z [dig]     straight there: up/down first to y, then x,
--                                  then z (dig: dig through what's in the way;
--                                  otherwise leaves, snow and plants are
--                                  cleared, turtles waited for, and anything
--                                  else stops it)
--        worker path x y z [cy]    over at height cy (default y + 3): up, x, z, down
--        worker face north|east|south|west
--        worker scan [r]           equips a geo scanner from its inventory (on a
--                                  free side, else in place of what isn't the
--                                  pickaxe), scans (radius r, default 8) and
--                                  writes /scan.txt: "x y z name" per block,
--                                  world coordinates; then swaps back
--        worker place x y z item [click]   places item at (x, y, z) from the
--                                  cell above; click: right-clicks it with
--                                  the Automata core (switches a modem on),
--                                  only if it placed it (a click toggles)
--        worker click x y z        right-clicks the block from above

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
local SOFT = { "leaves", "snow", "grass", "fern", "flower", "bush", "sapling", "vine", "mushroom" }
local function isSoft(b)
  if b.name:find("block", 1, true) then return false end
  for _, w in ipairs(SOFT) do if b.name:find(w, 1, true) then return true end end
  return false
end

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
  -- Leaves, snow and plants are always cleared; with dig, anything but a machine.
  local opts = { canDig = function(blk)
    if dig then return not isMachine(blk) end
    return isSoft(blk)
  end }
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

-- Equips the scanner on a side (a free one, else the one that isn't the
-- pickaxe) for fn(side), then puts everything back as it was.
local function withScanner(fn)
  local slot
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == SCANNER then slot = s break end
  end
  if (turtle.getEquippedLeft() or {}).name == SCANNER then return fn("left") end
  if (turtle.getEquippedRight() or {}).name == SCANNER then return fn("right") end
  if not slot then fail("No geo scanner in my inventory") end
  local l, r = turtle.getEquippedLeft(), turtle.getEquippedRight()
  local side = not l and "left" or not r and "right"
    or (not l.name:find("pickaxe", 1, true) and "left") or "right"
  local equip = side == "left" and turtle.equipLeft or turtle.equipRight
  -- Swapping through one slot: the scanner goes on, what was there comes
  -- into the slot; the same again swaps them back.
  turtle.select(slot)
  equip()
  sleep(0.2)
  local res = table.pack(pcall(fn, side))
  turtle.select(slot)
  equip()
  turtle.select(1)
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

local function scan(r)
  local list, err, w = withScanner(function(side)
    local l, e = peripheral.call(side, "scanBlocks", r)
    return l, e, world()
  end)
  if not list then fail("Scan failed: " .. tostring(err)) end
  local h = fs.open("/scan.txt", "w")
  local counts = {}
  for _, b in ipairs(list) do
    h.writeLine(("%d %d %d %s"):format(w.x + b.x, w.y + b.y, w.z + b.z, b.name))
    counts[b.name] = (counts[b.name] or 0) + 1
  end
  h.close()
  local l = {}
  for name, n in pairs(counts) do l[#l + 1] = n .. " " .. name end
  table.sort(l)
  print(("Scanned %d blocks round %s (r %d) into /scan.txt"):format(#list, key(w), r))
  for _, line in ipairs(l) do print("  " .. line) end
end

-- The side with an Automata core (it right-clicks), or nil.
local function coreSide()
  for _, side in ipairs({ "left", "right" }) do
    local d = side == "left" and turtle.getEquippedLeft() or turtle.getEquippedRight()
    if d and d.name:find("automata_core", 1, true) then return side end
  end
end

-- Right-clicks the block below (a wired modem switches on).
local function clickDown()
  local side = coreSide()
  if not side then fail("No Automata core to click with") end
  local ok, res, err = pcall(peripheral.call, side, "useOnBlock", { pitch = 90 })
  if not ok then return false, res end
  return res, err
end

-- Over the cell (x, y + 1, z): up first if lower, across, then down.
local function above(x, y, z)
  if world().y < y + 1 then goAxis("y", y + 1) end
  goAxis("x", x)
  goAxis("z", z)
  goAxis("y", y + 1)
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
elseif cmd == "place" then
  -- worker place x y z item [click]: from the cell above; skips it if it's
  -- already there, stops if something else is.
  local x, y, z, item = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), args[5]
  above(x, y, z)
  local ok, b = turtle.inspectDown()
  if ok and b.name ~= item then fail(("%s is at %d %d %d"):format(b.name, x, y, z)) end
  local fresh = not ok
  if not ok then
    local slot
    for s = 1, 16 do
      local d = turtle.getItemDetail(s)
      if d and d.name == item then slot = s break end
    end
    if not slot then fail("Out of " .. item) end
    turtle.select(slot)
    local placed, why = turtle.placeDown()
    turtle.select(1)
    if not placed then fail(("Can't place at %d %d %d: %s"):format(x, y, z, tostring(why))) end
  end
  -- Only a block it has just placed: a click toggles a modem, so clicking
  -- one that's already on switches it off.
  if args[6] == "click" and fresh then
    local res, err = clickDown()
    print(("Placed %s at %d %d %d, clicked: %s %s"):format(item, x, y, z, tostring(res), tostring(err or "")))
  else
    print(("Placed %s at %d %d %d"):format(item, x, y, z))
  end
elseif cmd == "click" then
  local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  above(x, y, z)
  local res, err = clickDown()
  print(("Clicked %d %d %d: %s %s"):format(x, y, z, tostring(res), tostring(err or "")))
else
  print("Usage: worker at | init x y z facing | go x y z [dig] | path x y z [cy] | face dir | scan [r]"
    .. " | place x y z item [click] | click x y z")
end
