-- Movement harness: tasks say where to go, this works out how.
--
-- Design
--   Position. lib/nav keeps the turtle's place and facing in its birth frame
--   (born on the factory's birth spot facing north) in the program's saved
--   state, with crash-safe pending moves; this turns that into world
--   coordinates (birth spot = move.ORIGIN, nav +z is north = world -z) and
--   into a working frame of the program's choosing (offset: world coordinates
--   of the frame's 0,0,0; the excavators work in site coordinates, offset =
--   the lift's bottom). here() is the working frame, world() is the world.
--
--   Steps. step(op, patience, canDig) is the one way a turtle moves: op is a
--   world direction (n e s w u d). The cell is claimed from the occupancy
--   service, cleared (canDig: true = anything but turtles, computers and
--   protected blocks like torches; a function = only what it allows; nil =
--   nothing), and moved into. Turtles in the way are waited for, up to
--   `patience` seconds (nil: for ever). Liquids never stop a step: a source
--   in a cell it may dig is plugged (the program's plug hook) and dug out.
--
--   Fuel. homeCost(p) is the worst-case fuel from p back to a fuel source,
--   detours and giving way included: the program's own estimate, or by
--   default the nearest registered station (the birth spot is one) by way of
--   its cruise height, half again the straight distance across, plus a
--   margin. goTo checks before it sets out that it can get there and back
--   from there; if not it burns what it carries, then runs the program's
--   onShort hook (a trip to the station), or without one refuses the trip
--   (false, "short of fuel"). Run dry anyway (a long wait, a lost bucket of lava) and a
--   step burns what the turtle carries, then waits where it is calling for
--   help over the bridge until someone brings fuel; it never crashes.
--
--   Paths. goTo plans breadth-first over the program's passable cells
--   (cells(wide): what it knows is clear, or wide, everything it may go
--   through) plus, if `air` is set, open air at or above that world height
--   near the way. It digs only where goTo is told it may (opts.dig).
--
--   A block it may not dig becomes a wall for the rest of that goTo and it
--   plans round it; with no way round it stops with "No way from ... to ...".
--
--   Other turtles. A turtle in the way is waited for briefly, then stepped
--   round (aside, and a new path that avoids that cell), with back-off and
--   jitter so two never dance in step. Lanes are the narrow places:
--     one-way (oneWay = op): paths inside it only go that way;
--     shared with right of way (yield = op): a turtle going `op` that meets
--       one gives way: backs along `back` until ready(p), digs itself a
--       pocket beside the lane (pocket(p) says where it may) and waits in it
--       until the lane is quiet;
--     stations: a fuel source at the end of a one-wide lane used both ways.
--       Coming in gives way to a turtle leaving: back out, up out of the way,
--       wait a while with jitter and try again.
--
--   Occupancy. setOccupancy(svc) plugs in a shared reservation service
--   (world keys "x,y,z"): svc.claim(k) before entering a cell (false: wait as
--   for a turtle; false, "yield": give up at once), svc.release(k, into) on
--   leaving cell k for cell `into` (or giving up entering k: into = nil),
--   svc.taken(k) when planning. The fleet network's lib/fleet occupancy is
--   adapted to this (fleetOccupancy).
--   The default is a local no-op that grants everything.
--
-- Usage
--   local move = require("lib.move")
--   move.init(state, save, { offset = {...}, fuel = {...}, homeCost = fn, ... })
--   move.configure({ cells = fn, lanes = {...}, plug = fn, onShort = fn })
--   move.goTo({ x =, y =, z = }, { dig = true })   -- working-frame cell
--   move.flyTo(x, z, y)  -- world column at height y, over anything in the way
--   move.refuelAt("birth", need, enough)

local nav = require("lib.nav")

local move = {}

-- The factory's birth spot on the surface: nav's 0,0,0 unless the program
-- says otherwise (excavate passes where it was born, see lib/home).
move.ORIGIN = { x = 3559, y = 74, z = 4762 }

-- World directions. nav dir: north = 0, east = 1, south = 2, west = 3.
local OPS = {
  n = { dx = 0, dy = 0, dz = -1, dir = 0 }, e = { dx = 1, dy = 0, dz = 0, dir = 1 },
  s = { dx = 0, dy = 0, dz = 1, dir = 2 }, w = { dx = -1, dy = 0, dz = 0, dir = 3 },
  u = { dx = 0, dy = 1, dz = 0, kind = "up" }, d = { dx = 0, dy = -1, dz = 0, kind = "down" },
}
local BACKWARD = { u = "d", d = "u", n = "s", s = "n", e = "w", w = "e" }
move.OPS, move.BACKWARD = OPS, BACKWARD

local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function add(p, op, n)
  local o = OPS[op]
  n = n or 1
  return { x = p.x + o.dx * n, y = p.y + o.dy * n, z = p.z + o.dz * n }
end
move.key, move.same, move.add = key, same, add

local function fail(msg) error(msg, 0) end

local T = {
  forward = { inspect = turtle.inspect, dig = turtle.dig, place = turtle.place, detect = turtle.detect, drop = turtle.drop },
  up = { inspect = turtle.inspectUp, dig = turtle.digUp, place = turtle.placeUp, detect = turtle.detectUp, drop = turtle.dropUp },
  down = { inspect = turtle.inspectDown, dig = turtle.digDown, place = turtle.placeDown, detect = turtle.detectDown, drop = turtle.dropDown },
}
move.T = T

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

local function has(name, words)
  for _, w in ipairs(words) do if name:find(w, 1, true) then return true end end
  return false
end
-- What may be cleared on the surface: snow, plants, leaves.
local SOFT = { "snow", "grass", "fern", "flower", "bush", "sapling", "vine", "mushroom", "dandelion", "poppy", "leaves" }
function move.isSoft(b) return has(b.name, SOFT) and not b.name:find("block", 1, true) end
-- Turtles and computers are waited for (they move, or someone's using
-- them); other ComputerCraft blocks (cables, disk drives) are just blocks.
function move.isMachine(b)
  return b.name:find("^computercraft:turtle") ~= nil or b.name:find("^computercraft:computer") ~= nil
end
function move.isFluid(b) return b.state ~= nil and b.state.level ~= nil end
-- Never dug, even where it may dig anything: lights set in the works.
local function protected(b) return b.name:find("torch", 1, true) ~= nil end
local isMachine, isFluid = move.isMachine, move.isFluid

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local cfg = {}
local origin, offset = move.ORIGIN, { x = 0, y = 0, z = 0 }
local stations = {}
local NOOP = { claim = function() return true end, release = function() end, taken = function() return false end }
local occ = NOOP

-- state/save: the program's saved table and how to save it (nav keeps pos,
-- dir and pending there). opts (all optional, more can come later through
-- configure):
--   origin     world coordinates of nav's 0,0,0 (default the birth spot)
--   offset     world coordinates of the working frame's 0,0,0
--   fuel       { [item name] = true } burnt by refuel
--   reserve    fuel kept on top of homeCost when burning it dry
--   homeCost   function(p) -> worst-case fuel home from working-frame cell p
--   detour, margin   for the default homeCost (1.5, 100)
--   cells      function(wide) -> { ["x,y,z"] = true } passable working-frame cells
--   air        world y at and above which open air counts as passable
--   lanes      list of lanes (see the top)
--   plug       function(side) -> true if it dealt with a liquid there
--   protect    function(block) -> true for blocks never to dig
--   onProtected function(side, block): told when a step meets one
--   walls      function() -> { ["x,y,z"] = true } working-frame cells goTo
--              never plans through (hazards it already knows of)
--   soft       what flying may clear (default move.isSoft)
--   onShort    function(need): get fuel; goTo calls it when it can't afford a trip
--   name       what to call it when calling for help
function move.init(state, save, opts)
  nav.init(state, save)
  nav.recover()
  save()
  cfg = opts or {}
  origin = cfg.origin or move.ORIGIN
  offset = cfg.offset or { x = 0, y = 0, z = 0 }
  stations = {}
  -- The fuel station on the birth spot, at the end of a lane from the north.
  move.addStation("birth", { x = origin.x, y = origin.y, z = origin.z, lane = "s", length = 3, cruise = 80, retreat = 3 })
  occ.claim(key(move.world()))
end

function move.configure(opts)
  for k, v in pairs(opts) do cfg[k] = v end
end

-- svc: { claim = fn(k) -> bool, release = fn(k), taken = fn(k) -> bool }, or
-- nil for the local no-op. The fleet network's occupancy (lib/fleet:
-- fleet.occupancy(...), with claim(cells) all or none, moved, release, who)
-- is recognised by its moved() and adapted.
function move.setOccupancy(svc)
  if svc and svc.moved then svc = move.fleetOccupancy(svc) end
  occ = svc or NOOP
end

local function cellOf(k)
  local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

-- The fleet's claim holds a set of cells and each claim replaces the last:
-- claiming the next cell holds just that one, and moving into it is moved().
-- In a deadlock the higher computer id gives way: its claim fails at once,
-- so goTo steps round instead of waiting.
function move.fleetOccupancy(f)
  local me = os.getComputerID and os.getComputerID() or 0
  local deadlocked = false
  return {
    claim = function(k)
      if deadlocked then return false, "yield" end
      local ok, info = f.claim({ cellOf(k) })
      if not ok and info and info.deadlock and me > (tonumber(info.by) or math.huge) then
        deadlocked = true
        return false, "yield"
      end
      return ok and true or false
    end,
    release = function(k, moved)
      if moved then f.moved(cellOf(moved)) else f.release() end
      deadlocked = false
    end,
    taken = function(k)
      local who = f.who({ cellOf(k) })
      return who ~= nil and who[1] ~= nil and who[1] ~= false
    end,
  }
end

---------------------------------------------------------------------------
-- Where it is
---------------------------------------------------------------------------

function move.world()
  local p = nav.pos()
  return { x = origin.x + p.x, y = origin.y + p.y, z = origin.z - p.z }
end
function move.toWorld(p) return { x = p.x + offset.x, y = p.y + offset.y, z = p.z + offset.z } end
function move.fromWorld(w) return { x = w.x - offset.x, y = w.y - offset.y, z = w.z - offset.z } end
function move.here() return move.fromWorld(move.world()) end

move.face = nav.face

-- Turns towards a direction and returns the matching turtle calls.
function move.aim(op)
  local o = OPS[op]
  if o.kind then return T[o.kind], o.kind end
  nav.face(o.dir)
  return T.forward, "forward"
end

---------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------

function move.refuel(target)
  local fuel = cfg.fuel or {}
  for slot = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    local item = turtle.getItemDetail(slot)
    if item and fuel[item.name] then
      turtle.select(slot)
      while turtle.getFuelLevel() < target and turtle.getItemCount(slot) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- Default: to the nearest station by way of its cruise height.
local function stationCost(p)
  local w = move.toWorld(p)
  local best
  for _, s in pairs(stations) do
    local cruise = math.max(s.cruise or w.y, w.y)
    local c = math.ceil((cfg.detour or 1.5) * (math.abs(w.x - s.x) + math.abs(w.z - s.z)))
      + (cruise - w.y) + (cruise - s.y) + 2 * (s.length or 0)
    if not best or c < best then best = c end
  end
  return (best or 0) + (cfg.margin or 100)
end

-- Worst-case fuel from working-frame cell p (default: here) to fuel.
function move.homeCost(p)
  if cfg.homeCost then return cfg.homeCost(p) end
  return stationCost(p or move.here())
end

-- Enough to go `dist` moves to `to` and get home from there.
function move.canAfford(to, dist)
  return turtle.getFuelLevel() >= dist + move.homeCost(to)
end

-- Nearly dry: burn what it carries, and with nothing to burn wait where it
-- is, calling for help, until someone brings some.
local function ensureFuel()
  if turtle.getFuelLevel() >= 10 then return end
  local reserve = cfg.reserve or 0
  move.refuel(move.homeCost() + reserve)
  local waited = 0
  while turtle.getFuelLevel() == 0 do
    if waited % 300 == 0 then
      local w = move.world()
      print(("Out of fuel at %s: waiting for fuel"):format(key(w)))
      os.queueEvent("bridge_send", { action = "event", text = ("%s is out of fuel at %d %d %d"):format(os.getComputerLabel() or cfg.name or "A turtle", w.x, w.y, w.z) })
    end
    sleep(5)
    waited = waited + 5
    move.refuel(move.homeCost() + reserve)
  end
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

move.backoff = function(base, spread) sleep(base + math.random(spread)) end

-- Waits for the occupancy service to hand over world cell k.
local function claim(k, patience)
  local waited = 0
  while true do
    local ok, why = occ.claim(k)
    if ok then break end
    if why == "yield" then return false end
    if patience and waited >= patience then return false end
    if waited % 60 == 0 then print(("Waiting for %s to come free"):format(k)) end
    sleep(5)
    waited = waited + 5
  end
  return true
end

-- Clears direction `side` (a move.T entry). See canDig at the top.
-- Falling gravel and sand keep coming until it's clear.
function move.clear(side, patience, canDig)
  local any = canDig == true
  local waited, digs = 0, 0
  while true do
    local ok, b = side.inspect()
    if not ok then return true end
    if isFluid(b) then
      if any and b.state.level == 0 and cfg.plug and cfg.plug(side) then
        local ok2, b2 = side.inspect()
        if ok2 and not isFluid(b2) and not isMachine(b2) then side.dig() end
      end
      return true
    end
    if isMachine(b) then
      if patience and waited >= patience then return false end
      if waited % 60 == 0 then print("A turtle is in my way; waiting") end
      sleep(5)
      waited = waited + 5
    elseif not any and not (canDig and canDig(b)) then
      return false, "blocked"
    elseif (cfg.protect or protected)(b) then
      if cfg.onProtected then cfg.onProtected(side, b) end
      return false, "protected"
    else
      if not side.dig() then fail(("Can't dig %s at %s"):format(b.name, key(move.world()))) end
      digs = digs + 1
      if digs > 64 then fail("Something keeps falling in front of me at " .. key(move.world())) end
    end
  end
end

-- One move the way it faces (forward, up or down), the way already clear.
function move.go(kind)
  ensureFuel()
  local ok, why = nav.move(kind, { canDig = function(b) return not isMachine(b) end })
  if not ok then fail(("Stuck at %s: %s"):format(key(move.world()), why)) end
end

-- One step in world direction op. False (and why) if it couldn't.
function move.step(op, patience, canDig)
  local side, kind = move.aim(op)
  local from = move.world()
  local to = key(add(from, op))
  if not claim(to, patience) then
    occ.release(to)
    return false, "taken"
  end
  local ok, why = move.clear(side, patience, canDig)
  if not ok then
    occ.release(to)
    return false, why
  end
  move.go(kind)
  occ.release(key(from), to)
  return true
end

---------------------------------------------------------------------------
-- In the open: only soft things (snow, plants) are cleared; anything else
-- is flown over. World coordinates.
---------------------------------------------------------------------------

function move.soft(op, patience) return move.step(op, patience, cfg.soft or move.isSoft) end

function move.rise(y)
  while move.world().y < y do
    if not move.soft("u") then fail(("Can't rise to %d at %s"):format(y, key(move.world()))) end
  end
end

-- Across at height y to world column (x, z): over anything in the way.
function move.flyTo(x, z, y)
  move.rise(y)
  for _, axis in ipairs({ "x", "z" }) do
    local target = axis == "x" and x or z
    while move.world()[axis] ~= target do
      local w = move.world()
      local op = axis == "x" and (w.x < x and "e" or "w") or (w.z < z and "s" or "n")
      if not move.soft(op) then
        if move.world().y > y + 30 then fail("Can't get over what's in my way at " .. key(move.world())) end
        if not move.soft("u") then fail("Boxed in at " .. key(move.world())) end
      end
    end
  end
end

-- Straight down to height y through air, snow and plants.
function move.sink(y)
  while move.world().y > y do
    if not move.soft("d") then fail(("Can't get down to %d at %s"):format(y, key(move.world()))) end
  end
end

---------------------------------------------------------------------------
-- Fuel stations: a cell at the end of a one-wide lane, used both ways.
-- s = { x, y, z (world), lane = direction into it, length = lane cells,
--       cruise = height to fly at, retreat = how far above cruise to wait }
---------------------------------------------------------------------------

function move.addStation(name, s) stations[name] = s end
function move.station(name) return stations[name] end

local function entrance(s) return add(s, s.lane, -(s.length or 0)) end

-- Onto the station by its lane, giving way to a turtle leaving.
function move.intoStation(name)
  local s = stations[name]
  local e = entrance(s)
  while true do
    move.flyTo(e.x, e.z, s.cruise)
    move.sink(s.y)
    while not same(move.world(), s) and move.soft(s.lane, 10) do end
    if same(move.world(), s) then return end
    print("A turtle is leaving the fuel station; making way")
    move.leaveStation(name)
    move.rise(s.cruise + (s.retreat or 3))
    move.backoff(15, 30)
  end
end

-- Back out along the lane to its mouth.
function move.leaveStation(name)
  local s = stations[name]
  local e = entrance(s)
  while not same(move.world(), e) do move.soft(BACKWARD[s.lane]) end
end

-- In a station's lane (a reboot there)? Out first.
function move.outOfLane(name)
  local s = stations[name]
  local w = move.world()
  for i = 0, (s.length or 0) - 1 do
    if same(w, add(s, s.lane, -i)) then
      move.leaveStation(name)
      return
    end
  end
end

-- Onto the station, topping up as fuel comes; after a minute with `enough`
-- it leaves the station to others. Then out of the lane.
function move.refuelAt(name, need, enough)
  move.intoStation(name)
  local waited = 0
  while turtle.getFuelLevel() < need do
    move.refuel(need)
    if turtle.getFuelLevel() < need then
      if waited >= 30 and turtle.getFuelLevel() >= (enough or need) then
        print(("Enough to work on (%d); leaving the station to others"):format(turtle.getFuelLevel()))
        break
      end
      if waited % 30 == 0 then print(("Waiting at the fuel station (have %d, need %d)"):format(turtle.getFuelLevel(), need)) end
      waited = waited + 1
      sleep(2)
    end
  end
  move.leaveStation(name)
end

---------------------------------------------------------------------------
-- Paths through known cells (working frame)
---------------------------------------------------------------------------

local function cells(wide) return cfg.cells and cfg.cells(wide) or {} end

local function laneOf(p)
  for _, l in ipairs(cfg.lanes or {}) do
    if l.contains(p) then return l end
  end
end

-- Ops from one cell to another through the passable cells (wide: all of
-- them), never through cells in `avoid` or held by others. nil if none.
function move.path(from, to, avoid, wide)
  local open = cells(wide)
  avoid = avoid or {}
  local tk = key(to)
  local airY, lo, hi
  if cfg.air then
    airY = cfg.air - offset.y
    local pad = 8
    lo = { x = math.min(from.x, to.x) - pad, z = math.min(from.z, to.z) - pad }
    hi = { x = math.max(from.x, to.x) + pad, y = math.max(from.y, to.y, airY) + pad, z = math.max(from.z, to.z) + pad }
  end
  local function inAir(n)
    return airY and n.y >= airY and n.y <= hi.y and n.x >= lo.x and n.x <= hi.x and n.z >= lo.z and n.z <= hi.z
  end
  local lanes = cfg.lanes
  local function edge(c, n, op)
    if not lanes then return true end
    for _, l in ipairs(lanes) do
      if l.oneWay and op ~= l.oneWay and l.contains(c) and l.contains(n) then return false end
    end
    return true
  end
  local function ok(k, n)
    if k == tk then return true end
    if avoid[k] or not (open[k] or inAir(n)) then return false end
    return not occ.taken(key(move.toWorld(n)))
  end
  local prev, queue, head = { [key(from)] = false }, { from }, 1
  while queue[head] do
    local c = queue[head]
    head = head + 1
    if same(c, to) then break end
    for op, o in pairs(OPS) do
      local n = { x = c.x + o.dx, y = c.y + o.dy, z = c.z + o.dz }
      local k = key(n)
      if prev[k] == nil and ok(k, n) and edge(c, n, op) then
        prev[k] = { c, op }
        queue[#queue + 1] = n
      end
    end
    if head % 2000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
  end
  if prev[tk] == nil then return nil end
  local ops, k = {}, tk
  while prev[k] do
    table.insert(ops, 1, prev[k][2])
    k = key(prev[k][1])
  end
  return ops
end

-- Waits beside the lane, looking into it from `side`, until it's quiet.
local function laneClear(side, cell)
  local quiet = 0
  while quiet < 3 do
    local ok, b = side.inspect()
    if (ok and isMachine(b)) or occ.taken(key(move.toWorld(cell))) then quiet = 0 else quiet = quiet + 1 end
    sleep(2)
  end
end

-- Giving way in a lane with right of way: back along it to where pockets
-- may be dug, dig one beside it, wait there until it's quiet, step back.
function move.giveWay(lane)
  print("Giving way in the " .. (lane.name or "lane"))
  while not lane.ready(move.here()) do
    if not move.step(lane.back, 60, true) then sleep(5) end
  end
  for _, op in ipairs(lane.sides or { "e", "w", "n", "s" }) do
    local p = move.here()
    local cell = add(p, op)
    if not cells(true)[key(cell)] and lane.pocket(move.here()) then
      local side = move.aim(op)
      local ok, b = side.inspect()
      if not (ok and isMachine(b)) and move.clear(side, 10, true) then
        move.go("forward")
        nav.face(OPS[BACKWARD[op]].dir)
        laneClear(T.forward, p)
        move.go("forward")
        return true
      end
    end
  end
  -- No pocket to be had: back off a little and let things sort themselves.
  for _ = 1, 3 do move.step(lane.back, 30, true) end
  move.backoff(5, 10)
  return false
end

-- To a working-frame cell through the passable cells. opts.dig: what it
-- may dig on the way (true: anything; a function; nil: nothing).
-- opts.homeward: on the way to fuel, so never refused for lack of it.
-- True when there; false, "short of fuel" if it can't afford the trip and
-- has no onShort hook to fetch fuel with.
local shortRunning = false
function move.goTo(to, opts)
  opts = opts or {}
  local dig = opts.dig
  -- walls: cells it found it may not dig, for good; avoid: those and where
  -- turtles stood in the way, for now.
  local walls, avoid, wide = {}, {}, false
  for k in pairs(cfg.walls and cfg.walls() or {}) do walls[k], avoid[k] = true, true end
  if walls[key(to)] then return false, "protected" end
  local function forget()
    local a = {}
    for k in pairs(walls) do a[k] = true end
    return a
  end
  while true do
    local ops = move.path(move.here(), to, avoid, wide)
    if not ops then
      -- Hemmed in for now: forget the turtles, wait, try again.
      avoid, wide = forget(), true
      ops = move.path(move.here(), to, avoid, wide)
      if not ops then fail(("No way from %s to %s"):format(key(move.here()), key(to))) end
      move.backoff(5, 10)
    end
    local short = not opts.homeward and not shortRunning and not move.canAfford(to, #ops)
    if short then
      -- What it carries first.
      move.refuel(#ops + move.homeCost(to))
      short = not move.canAfford(to, #ops)
    end
    if short and not cfg.onShort then
      -- Nothing to fetch fuel with: refused, for the program to decide.
      return false, "short of fuel"
    elseif short then
      -- Not enough to get there and back: fuel first, then plan again.
      shortRunning = true
      local ok, err = pcall(cfg.onShort, #ops + move.homeCost(to))
      shortRunning = false
      if not ok then error(err, 0) end
    else
      local blocked, blockedOp, why = nil, nil, nil
      for _, op in ipairs(ops) do
        local ok, w = move.step(op, 10 + math.random(10), dig)
        if not ok then
          blocked, blockedOp, why = key(add(move.here(), op)), op, w
          break
        end
      end
      if not blocked then return true end
      local lane = laneOf(move.here())
      if why == "protected" then
        -- Never to be dug (a light, a block that explodes): a wall, and if
        -- it's where it was going, it can't get there.
        walls[blocked], avoid[blocked] = true, true
        if blocked == key(to) then return false, "protected" end
      elseif why == "blocked" then
        -- Something it may not dig: a wall from now on, and another way.
        walls[blocked], avoid[blocked] = true, true
        if blocked == key(to) then fail(("Can't dig into %s"):format(key(to))) end
      elseif lane and lane.yield == blockedOp then
        move.giveWay(lane)
      else
        print("Stepping round another turtle")
        if blocked ~= key(to) then avoid[blocked] = true end
        wide = true
        -- Aside, so it can pass.
        local open = cells(true)
        for _, op in ipairs({ "n", "e", "s", "w" }) do
          local n = key(add(move.here(), op))
          if op ~= blockedOp and open[n] and not avoid[n] and move.step(op, 3, dig) then break end
        end
        move.backoff(2, 6)
      end
    end
  end
end

return move
