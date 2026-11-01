-- Excavator for the Clockworks: one of a crew that clears the whole volume
-- of the works, every block any structure sets, so the builders only have to
-- place. A mining turtle with a chunk controller. The volume is cut into
-- wedges round the service shaft, one per turtle (zones in
-- /blueprints/excavation.lua, made by design/generate.mjs).
--
-- Born on the factory's birth spot (factory birth excavator <zone>), with a
-- bucket and coal. It flies out north of the factory, over to the top of the
-- service shaft at cruise height, goes straight down the shaft to the top
-- of the hall and digs its zone. Nothing above y 60 is dug but the shaft.
--
-- Along the way it:
--   drops stone and dirt (they despawn) and keeps ores and anything unknown,
--     flying them to the factory's input chest when it runs out of room
--   drinks lava sources with its bucket for fuel, and plugs other liquids
--     with a block of stone: kept rock is never left leaking into the works
--   burns coal it finds and, when short of fuel, goes to the fuel station
--   never digs another turtle or computer, and in the one-wide shaft gives
--     way to turtles coming down
-- Out it flies at y 80, back at y 82, so turtles never meet head on.
--
-- With zone "light" it's the lamplighter instead: once the works are dug it
-- walks the lighting route and sets a torch on every floor, every few blocks,
-- so nothing spawns in the dark.
--
-- Usage: excavate <zone> [from [to]]   (what autorun runs; resumes after
--                                  reboots; from/to: only that stretch of the
--                                  route, to take over or share a zone)
--        excavate scout   (factory birth scout) maps the works with a geo
--                         scanner: what's still standing in the volume, and
--                         every water and lava block near it, into /scout.txt
--        excavate drain <zones>   a turtle in the works drains finished
--                         zones (like 3,5,7) using the scout's map
--                         (/blueprints/wet.lua, from design/wet.mjs): water in
--                         the walls sealed, sources in the works removed, and
--                         leftover plugs dug out
--        excavate porter   (the turtle labelled Porter, once it's dug the
--                         station room, zone 9) stocks the chest station
--                         (/blueprints/station.lua): the factory loads it at
--                         the fuel station, chests first, then plain Factory
--                         Blocks, and it sets the chests up and fills them
--        excavate fill <zones>   dries flooded zones for good: fills every
--                         water cell with cobblestone, bottom layer first
--                         (a cell can't turn back into water once it's
--                         solid, unlike removing sources one by one in a
--                         lake, where neighbours refill them), then re-digs
--                         each zone by its route, which seals the walls
--        excavate help <zone> <from> <to>   a turtle already in the works
--                                  (one that finished its own) takes that
--                                  stretch of another zone
--        excavate light [zones]   lamplighter; with zones (like 1,2,5) only
--                                  torches in those, so finished zones can be
--                                  lit while the rest are still being dug
--        excavate status
--        excavate show [seconds]   come up and hover high over the shaft
--                                  (to be seen), then carry on
--        excavate give x y z [n]   take n fuel items (default half of what
--                                  it has) to a stranded turtle at world
--                                  x y z, then carry on

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.excavate"
local PLAN = "/blueprints/excavation.lua"
local MARGIN = 400        -- fuel kept beyond the way to the factory: waits, detours and giving way in the shaft
local OUT, BACK = 80, 82  -- cruise heights, to the shaft and from it

local FUEL = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
  ["minecraft:lava_bucket"] = true, ["mekanism:block_charcoal"] = true,
}
local BUCKET = "minecraft:bucket"
local LAVA = "minecraft:lava_bucket"
local TORCH = "minecraft:torch"
-- Dropped as junk unless the name also says it's worth keeping.
local JUNK = {
  "stone", "cobble", "deepslate", "tuff", "granite", "diorite", "andesite", "calcite", "dirt",
  "gravel", "sand", "clay", "dripstone", "basalt", "flint", "moss", "mud", "netherrack",
  "blackstone", "grass", "obsidian", "limestone", "scoria", "scorchia", "asurine", "crimsite",
  "ochrum", "veridium", "slate", "marble", "bone_block", "glow_lichen", "pebble",
}
local KEEP = { "ore", "raw_", "coal", "diamond", "emerald", "lapis", "redstone", "quartz", "amethyst", "gem" }
-- What may be cleared on the surface: snow, plants, leaves (a pine stands by
-- the shaft). Anything else is flown over.
local SOFT = { "snow", "grass", "fern", "flower", "bush", "sapling", "vine", "mushroom", "dandelion", "poppy", "leaves" }

local function has(name, words)
  for _, w in ipairs(words) do if name:find(w, 1, true) then return true end end
  return false
end
local function isJunk(name) return has(name, JUNK) and not has(name, KEEP) end
-- Turtles and computers are waited for (they move, or someone's using
-- them); other ComputerCraft blocks (cables, disk drives) are just blocks.
local function isMachine(b)
  return b.name:find("^computercraft:turtle") ~= nil or b.name:find("^computercraft:computer") ~= nil
end
local function isFluid(b) return b.state ~= nil and b.state.level ~= nil end
-- Blocks that blow up when dug, taking the turtle with them (Forbidden &
-- Arcanus' Stella Arcanum): never dug, gone round, left for the player.
local HAZARD = { "stella_arcanum" }
local function isHazard(b) return b ~= nil and has(b.name, HAZARD) end
local function isSoft(b) return has(b.name, SOFT) and not b.name:find("block", 1, true) end

local function fail(msg) error(msg, 0) end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state = saved.load(STATE)

local plan
do
  local h = fs.open(PLAN, "r")
  if not h then fail("No route: " .. PLAN .. " is missing") end
  plan = load(h.readAll(), "=" .. PLAN, "t", { table = table })()
  h.close()
end

local arg1 = ...
if arg1 == "status" then
  if not state or not state.zone then print("Not started") return end
  local route = (state.zone == "light" and plan.light or plan.zones[state.zone]).route
  print(("Zone %s: %s, step %d of %d (%d%%)"):format(state.zone, state.phase, state.step or 1, #route,
    math.floor(100 * ((state.step or 1) - 1) / #route)))
  return
end
local showFor = arg1 == "show" and (tonumber((select(2, ...))) or 180)
local giveTo
if arg1 == "give" then
  local _, gx, gy, gz, gn = ...
  giveTo = { x = tonumber(gx), y = tonumber(gy), z = tonumber(gz), n = tonumber(gn) }
  if not (giveTo.x and giveTo.y and giveTo.z) then fail("Usage: excavate give x y z [n]") end
end
-- Helping with another zone: a new stretch, once (the same args again
-- after a reboot carry on where it was).
if arg1 == "help" then
  local _, hz, hf, ht = ...
  local assigned = ("%s:%s:%s"):format(hz, hf, ht)
  if not (state and state.assigned == assigned) then
    state = state or {}
    state.assigned, state.zone, state.phase = assigned, tonumber(hz), "help"
    state.from, state.to, state.step, state.at, state.trip = tonumber(hf), tonumber(ht), nil, nil, nil
  end
end
-- The lamplighter told to light (more) zones: the light route again from
-- the start, placing torches only in those zones.
if arg1 == "light" and state and select(2, ...) and state.only ~= select(2, ...) and state.phase ~= "orient" and state.phase ~= "travel" then
  state.only, state.phase, state.from, state.to, state.step, state.at = select(2, ...), "help", 1, nil, nil, nil
end
-- Draining: once per list of zones, like help.
if arg1 == "drain" then
  local zones = select(2, ...)
  if not (state and state.assigned == "drain:" .. tostring(zones)) then
    state = state or {}
    state.assigned, state.zone, state.phase, state.drainZones = "drain:" .. tostring(zones), "drain", "drain", zones
    state.stop, state.trip = nil, nil
  end
end
if arg1 == "porter" and not (state and state.assigned == "porter") then
  state = state or {}
  state.assigned, state.zone, state.phase, state.trip = "porter", "porter", "porter", nil
end
if arg1 == "fill" then
  local zones = select(2, ...)
  if not (state and state.assigned == "fill:" .. tostring(zones)) then
    state = state or {}
    state.assigned, state.zone, state.phase, state.fillZones = "fill:" .. tostring(zones), "fill", "fill", zones
    state.fillAt, state.trip = nil, nil
  end
end
local zone = (state and state.zone) or tonumber(arg1) or (arg1 == "light" and plan.light and "light")
  or (arg1 == "scout" and "scout")
local job = ((zone == "scout" or zone == "drain" or zone == "porter" or zone == "fill") and { route = "" }) or (zone == "light" and plan.light) or plan.zones[zone]
if not job then fail(("Usage: excavate <zone 1-%d> | light"):format(#plan.zones)) end
local ROUTE = job.route

state = state or { phase = "orient", zone = zone, only = arg1 == "light" and select(2, ...) or nil,
  from = tonumber(arg1) and tonumber((select(2, ...))) or nil, to = tonumber(arg1) and tonumber((select(3, ...))) or nil }
local LAST = math.min(state.to or #ROUTE, #ROUTE) -- the last step of its stretch
local function save() saved.save(STATE, state) end
nav.init(state, save)
nav.recover()
save()

---------------------------------------------------------------------------
-- Coordinates. nav starts on the birth spot, one north of the factory,
-- facing north: nav +z is north, nav +x east. Site coordinates are world
-- coordinates less the lift's bottom: x east, y up, z south.
---------------------------------------------------------------------------

local F, L, START = plan.factory, plan.lift, plan.start
local function world()
  local p = nav.pos()
  return { x = F.x + p.x, y = F.y + p.y, z = F.z - 1 - p.z }
end
local function site()
  local w = world()
  return { x = w.x - L.x, y = w.y - L.y, z = w.z - L.z }
end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
-- The service shaft, in site coordinates, from the hall up to the top of the
-- way back (cruise heights are world y; the lift's bottom is at world L.y).
local SHAFT_TOP = BACK - L.y

-- World directions. nav dir: north = 0, east = 1, south = 2, west = 3.
local OPS = {
  n = { dx = 0, dy = 0, dz = -1, dir = 0 }, e = { dx = 1, dy = 0, dz = 0, dir = 1 },
  s = { dx = 0, dy = 0, dz = 1, dir = 2 }, w = { dx = -1, dy = 0, dz = 0, dir = 3 },
  u = { dx = 0, dy = 1, dz = 0, kind = "up" }, d = { dx = 0, dy = -1, dz = 0, kind = "down" },
}
local LOOK = { ["0"] = "n", ["1"] = "e", ["2"] = "s", ["3"] = "w", ["4"] = "u", ["5"] = "d" }

local T = {
  forward = { inspect = turtle.inspect, dig = turtle.dig, place = turtle.place, detect = turtle.detect, drop = turtle.drop },
  up = { inspect = turtle.inspectUp, dig = turtle.digUp, place = turtle.placeUp, detect = turtle.detectUp, drop = turtle.dropUp },
  down = { inspect = turtle.inspectDown, dig = turtle.digDown, place = turtle.placeDown, detect = turtle.detectDown, drop = turtle.dropDown },
}
-- Turns towards a direction and returns the matching turtle calls.
local function aim(op)
  local o = OPS[op]
  if o.kind then return T[o.kind], o.kind end
  nav.face(o.dir)
  return T.forward, "forward"
end

---------------------------------------------------------------------------
-- Inventory and fuel
---------------------------------------------------------------------------

local function find(match)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and match(item.name) then return slot, item end
  end
end

local function freeSlots()
  local n = 0
  for slot = 1, 16 do if turtle.getItemCount(slot) == 0 then n = n + 1 end end
  return n
end

local function compact()
  for i = 1, 15 do
    local a = turtle.getItemDetail(i)
    if a and turtle.getItemSpace(i) > 0 then
      for j = i + 1, 16 do
        local b = turtle.getItemDetail(j)
        if b and b.name == a.name then
          turtle.select(j)
          turtle.transferTo(i)
          if turtle.getItemSpace(i) == 0 then break end
        end
      end
    end
  end
  turtle.select(1)
end

-- Drops junk into open space, keeping one stack of stone to plug liquids.
local function dropJunk()
  local t = (not turtle.detectUp() and T.up) or (not turtle.detectDown() and T.down) or T.forward
  local filler = false
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and isJunk(item.name) then
      if not filler and item.count >= 8 then
        filler = true
      else
        turtle.select(slot)
        t.drop()
      end
    end
  end
  turtle.select(1)
  compact()
end

local function refuel(target)
  for slot = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    local item = turtle.getItemDetail(slot)
    if item and FUEL[item.name] then
      turtle.select(slot)
      while turtle.getFuelLevel() < target and turtle.getItemCount(slot) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- Fuel to get to the factory from p (default: here), roughly: out of the
-- hall, up the shaft, across and down to the factory.
local function homeCost(p)
  p = p or site()
  -- The way through the works winds round what isn't dug yet: half again
  -- the straight distance.
  return math.ceil(1.5 * (math.abs(p.x - START.x) + math.abs(p.z - START.z))) + math.abs(SHAFT_TOP - p.y)
    + math.abs(L.x + START.x - F.x) + math.abs(L.z + START.z - F.z) + (BACK - F.y) + 20 + MARGIN
end

---------------------------------------------------------------------------
-- Liquids, and digging
---------------------------------------------------------------------------

-- A liquid in direction t: lava sources go in the bucket and on to the fuel,
-- anything else gets a block of stone. Returns true if there was liquid.
local function plug(t)
  local ok, b = t.inspect()
  if not ok or not isFluid(b) then return false end
  if b.name == "minecraft:lava" and b.state.level == 0 then
    local slot = find(function(n) return n == BUCKET end)
    if slot then
      turtle.select(slot)
      if t.place() then
        if turtle.getFuelLevel() <= turtle.getFuelLimit() - 1000 then turtle.refuel() end
        turtle.select(1)
        return true
      end
    end
  end
  local slot = find(isJunk)
  if slot then
    turtle.select(slot)
    t.place()
    turtle.select(1)
  end
  return true
end

-- Clears direction t, never a turtle or computer: those are waited out, for
-- ever or for `patience` seconds (then it returns false). canDig decides what
-- else may be dug (default anything); something it may not dig returns
-- false, "blocked". Falling gravel and sand keep coming until it's clear.
-- A hazard met in direction t: kept in the state (paths go round it) and
-- reported once, for the player to mine by hand.
local function noteHazard(t, b)
  local w = world()
  local c = { x = w.x, y = w.y, z = w.z }
  if t == T.up then c.y = c.y + 1 elseif t == T.down then c.y = c.y - 1
  else
    local d = ({ [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } })[nav.dir()]
    c.x, c.z = c.x + d[1], c.z + d[2]
  end
  local k = (c.x - L.x) .. "," .. (c.y - L.y) .. "," .. (c.z - L.z)
  state.hazards = state.hazards or {}
  if state.hazards[k] then return end
  state.hazards[k] = b.name
  save()
  local text = ("%s left standing at %d %d %d: it explodes when dug, mine it by hand"):format(b.name, c.x, c.y, c.z)
  print(text)
  os.queueEvent("bridge_send", { action = "event", text = (os.getComputerLabel and os.getComputerLabel() or "An excavator") .. ": " .. text })
end

-- Clears the way in direction t: digs blocks (canDig: only what that
-- allows), waits for turtles (up to patience seconds). Liquids are never a
-- wall: turtles move and dig through them. A source in the way is removed
-- for good (lava into the bucket, water by a block placed in it and dug out
-- again); flowing liquid is just gone through. Kept rock round the works has
-- its liquids plugged by the route's look ops, which stops the flow at the
-- walls as the dig gets there.
local function clearAll(t, patience, canDig)
  local waited, digs = 0, 0
  while true do
    local ok, b = t.inspect()
    if not ok then return true end
    if isFluid(b) then
      if not canDig and b.state.level == 0 and plug(t) then
        local ok2, b2 = t.inspect()
        if ok2 and not isFluid(b2) and not isMachine(b2) then t.dig() end
      end
      return true
    end
    if isHazard(b) then
      noteHazard(t, b)
      return false, "hazard"
    end
    if isMachine(b) then
      if patience and waited >= patience then return false end
      if waited % 60 == 0 then print("A turtle is in my way; waiting") end
      sleep(5)
      waited = waited + 5
    elseif canDig and not canDig(b) then
      return false, "blocked"
    elseif b.name:find("torch", 1, true) then
      -- A light set in the works: gone round, never dug.
      return false, "torch"
    else
      if not t.dig() then fail(("Can't dig %s at %s"):format(b.name, key(world()))) end
      digs = digs + 1
      if digs > 64 then fail("Something keeps falling in front of me at " .. key(world())) end
    end
  end
end

local DIG = { canDig = function(b) return not isMachine(b) end }

local function move(kind)
  -- Running dry: burn what it carries, and with nothing to burn wait where
  -- it is (calling for help) until another turtle brings some (excavate give).
  if turtle.getFuelLevel() < 10 then
    refuel(homeCost() + MARGIN)
    local waited = 0
    while turtle.getFuelLevel() == 0 do
      if waited % 300 == 0 then
        local w = world()
        print(("Out of fuel at %s: waiting for fuel"):format(key(w)))
        os.queueEvent("bridge_send", { action = "event", text = ("%s is out of fuel at %d %d %d"):format(os.getComputerLabel() or "An excavator", w.x, w.y, w.z) })
      end
      sleep(5)
      waited = waited + 5
      refuel(homeCost() + MARGIN)
    end
  end
  local ok, why = nav.move(kind, DIG)
  if not ok then fail(("Stuck at %s: %s"):format(key(world()), why)) end
end

-- One step that may dig anything (in the works and the shaft).
local function stepDig(op, patience)
  local t, kind = aim(op)
  if not clearAll(t, patience) then return false end
  move(kind)
  return true
end

---------------------------------------------------------------------------
-- Above ground: only snow and plants are cleared; anything else is flown
-- over. Turtles in the way are waited for.
---------------------------------------------------------------------------

local function stepSoft(op, patience)
  local t, kind = aim(op)
  local ok = clearAll(t, patience, isSoft)
  if not ok then return false end
  move(kind)
  return true
end

local function rise(y)
  while world().y < y do
    if not stepSoft("u") then fail(("Can't rise to %d at %s"):format(y, key(world()))) end
  end
end

-- Across at height y to world column (x, z): over anything in the way.
local function flyTo(x, z, y)
  rise(y)
  for _, axis in ipairs({ "x", "z" }) do
    local target = axis == "x" and x or z
    while world()[axis] ~= target do
      local op = axis == "x" and (world().x < x and "e" or "w") or (world().z < z and "s" or "n")
      if not stepSoft(op) then
        if world().y > y + 30 then fail("Can't get over what's in my way at " .. key(world())) end
        if not stepSoft("u") then fail("Boxed in at " .. key(world())) end
      end
    end
  end
end

-- Straight down to height y through air, snow and plants.
local function sink(y)
  while world().y > y do
    if not stepSoft("d") then fail(("Can't get down to %d at %s"):format(y, key(world()))) end
  end
end

---------------------------------------------------------------------------
-- The factory: deliveries to the input chest (from the west, like the pine
-- farm), fuel at the station on the birth spot.
---------------------------------------------------------------------------

-- One way round: down the column south-west of the chest, north onto the
-- cell west of it, then out west and south and up a column of its own, so a
-- queue coming down never meets a turtle going up. Picks up wherever it is
-- on the way (after a reboot).
local function deliver()
  local w = world()
  local atChest = w.x == F.x - 1 and w.z == F.z and w.y == F.y + 1
  if not atChest then
    if not (w.x == F.x - 1 and w.z == F.z + 1 and w.y > F.y) then flyTo(F.x - 1, F.z + 1, BACK) end
    sink(F.y + 1)
    stepSoft("n")
  end
  nav.face(1) -- east: the input chest
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not FUEL[item.name] and item.name ~= BUCKET and item.name ~= TORCH and not isJunk(item.name) then
      turtle.select(slot)
      if not turtle.drop() then print("The input chest is full") end
    end
  end
  turtle.select(1)
  stepSoft("w")
  stepSoft("s")
end

-- The lane to the fuel station is one block wide and turtles leave by it
-- too: one coming in that meets a turtle backs out and up out of the way,
-- waits a while and tries again, so the one leaving always gets past.
-- Onto the fuel station (the birth spot) by its one-wide lane, giving way
-- to a turtle leaving.
local function intoStation()
  while true do
    flyTo(F.x, F.z - 4, OUT)
    sink(F.y)
    while world().z < F.z - 1 and stepSoft("s", 10) do end
    if world().z == F.z - 1 then return end
    print("A turtle is leaving the fuel station; making way")
    while world().z > F.z - 4 do stepSoft("n") end
    rise(OUT + 3)
    sleep(15 + math.random(30))
  end
end

local function fuelStation(need)
  while true do
    flyTo(F.x, F.z - 4, OUT)
    sink(F.y)
    while world().z < F.z - 1 and stepSoft("s", 10) do end
    if world().z == F.z - 1 then break end
    print("A turtle is leaving the fuel station; making way")
    while world().z > F.z - 4 do stepSoft("n") end
    rise(OUT + 3)
    sleep(15 + math.random(30))
  end
  -- Topping up as the factory hands out charcoal; after a minute, with
  -- enough for a round trip to the works, it leaves the station to others.
  local waited = 0
  while turtle.getFuelLevel() < need do
    refuel(need)
    if turtle.getFuelLevel() < need then
      if waited >= 30 and turtle.getFuelLevel() >= 2 * homeCost(START) then
        print(("Enough to work on (%d); leaving the station to others"):format(turtle.getFuelLevel()))
        break
      end
      if waited % 30 == 0 then print(("Waiting at the fuel station (have %d, need %d)"):format(turtle.getFuelLevel(), need)) end
      waited = waited + 1
      sleep(2)
    end
  end
  while world().z > F.z - 4 do stepSoft("n") end
end

-- In the lane to the fuel station (a reboot there): out north first, since
-- the cobble generator's floor is over it.
local function outOfLane()
  local w = world()
  if w.x == F.x and w.y == F.y and w.z >= F.z - 3 and w.z <= F.z - 1 then
    while world().z > F.z - 4 do stepSoft("n") end
  end
end

---------------------------------------------------------------------------
-- In the works: through what the route has dug so far and the shaft.
---------------------------------------------------------------------------

local function inShaft(p) return p.x == START.x and p.z == START.z and p.y >= START.y end

local function dugSoFar()
  local open, p = {}, { x = START.x, y = START.y, z = START.z }
  for y = START.y, SHAFT_TOP do open[START.x .. "," .. y .. "," .. START.z] = true end
  for i = 1, (state.step or 1) - 1 do
    local o = OPS[ROUTE:sub(i, i)]
    if o then
      p = { x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz }
      open[key(p)] = true
    end
  end
  return open
end

-- Every cell of the works (all zones' routes) and the shaft: what a turtle
-- may go through to get round another. Worked out once.
local everywhere
local function allCells()
  if everywhere then return everywhere end
  local open = {}
  for y = START.y, SHAFT_TOP do open[START.x .. "," .. y .. "," .. START.z] = true end
  local routes = {}
  for _, z in ipairs(plan.zones) do routes[#routes + 1] = z.route end
  for _, r in ipairs(routes) do
    local p = { x = START.x, y = START.y, z = START.z }
    for i = 1, #r do
      local ch = r:sub(i, i)
      local o = OPS[ch] or OPS[ch:lower()]
      if o then
        local n = { x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz }
        open[key(n)] = true
        if OPS[ch] then p = n end
      end
      if i % 4000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
    end
  end
  everywhere = open
  return open
end

-- Ops from one site cell to another through what this turtle has dug and
-- the shaft, or (wide) through the whole works, never through cells in
-- `avoid` (where turtles stood in the way). nil if there's no way.
local function path(from, to, avoid, wide)
  local open = wide and allCells() or dugSoFar()
  avoid = avoid or {}
  local function ok(k) return k == key(to) or (open[k] and not avoid[k]) end
  local prev, queue, head = { [key(from)] = false }, { from }, 1
  while queue[head] do
    local c = queue[head]
    head = head + 1
    if same(c, to) then break end
    for op, o in pairs(OPS) do
      local n = { x = c.x + o.dx, y = c.y + o.dy, z = c.z + o.dz }
      local k = key(n)
      if ok(k) and prev[k] == nil then
        prev[k] = { c, op }
        queue[#queue + 1] = n
      end
    end
    if head % 2000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
  end
  if prev[key(to)] == nil then return nil end
  local ops, k = {}, key(to)
  while prev[k] do
    table.insert(ops, 1, prev[k][2])
    k = key(prev[k][1])
  end
  return ops
end

local BACKWARD = { u = "d", d = "u", n = "s", s = "n", e = "w", w = "e" }

-- Giving way. The shaft is one wide and shared both ways; coming down has
-- right of way. A turtle going up that meets another drops back below
-- world y 60 (where digging is allowed) and, in the rock beside the shaft
-- (above the hall, outside the works), digs itself a pocket and waits in it
-- until the shaft is clear, then carries on. Anywhere else a turtle in the
-- way is stepped round: aside, and a new path planned round it.
local FREE_BELOW = 60 - L.y          -- site y below which it may dig a pocket
local function shaftClear(side)
  -- From the pocket, looking back into the shaft: no turtle for a while.
  local quiet = 0
  while quiet < 3 do
    local ok, b = side.inspect()
    if ok and isMachine(b) then quiet = 0 else quiet = quiet + 1 end
    sleep(2)
  end
end
local function giveWay()
  print("Giving way in the shaft")
  -- Down past where pockets may be dug, waiting for anyone below to do the same.
  while site().y >= FREE_BELOW do
    if not stepDig("d", 60) then sleep(5) end
  end
  for _, op in ipairs({ "e", "w", "n", "s" }) do
    local p, o = site(), OPS[op]
    local cell = { x = p.x + o.dx, y = p.y, z = p.z + o.dz }
    if not allCells()[key(cell)] and site().y > START.y + 1 then
      local t = aim(op)
      local ok, b = t.inspect()
      if not (ok and isMachine(b)) and clearAll(t, 10) then
        move("forward")
        nav.face(OPS[BACKWARD[op]].dir)
        shaftClear(T.forward)
        move("forward")
        return true
      end
    end
  end
  -- No pocket to be had: back down a little and let things sort themselves.
  for _ = 1, 3 do stepDig("d", 30) end
  sleep(5 + math.random(10))
  return false
end

-- To a site cell through the works and the shaft.
local function goTo(to)
  if state.hazards and state.hazards[key(to)] then return false end
  local avoid, wide = {}, false
  for k in pairs(state.hazards or {}) do avoid[k] = true end
  while true do
    local ops = path(site(), to, avoid, wide)
    if not ops then
      -- Hemmed in for now: forget the blockers, wait, try again.
      avoid, wide = {}, true
      ops = path(site(), to, avoid, wide)
      if not ops then fail(("No way from %s to %s"):format(key(site()), key(to))) end
      sleep(5 + math.random(10))
    end
    if state.hazards and state.hazards[key(to)] then return false end
    local blocked, blockedOp = nil, nil
    for _, op in ipairs(ops) do
      if not stepDig(op, 10 + math.random(10)) then
        local p, o = site(), OPS[op]
        blocked, blockedOp = key({ x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz }), op
        break
      end
    end
    if not blocked then return end
    if inShaft(site()) and blockedOp == "u" then
      giveWay()
    else
      print("Stepping round another turtle")
      if blocked ~= key(to) then avoid[blocked] = true end
      wide = true
      -- Aside, into the works, so it can pass.
      for _, op in ipairs({ "n", "e", "s", "w" }) do
        local p, o = site(), OPS[op]
        local n = key({ x = p.x + o.dx, y = p.y, z = p.z + o.dz })
        if op ~= blockedOp and allCells()[n] and not avoid[n] and stepDig(op, 3) then break end
      end
      sleep(2 + math.random(6))
    end
  end
end

-- From the factory side into the works: across at y 80, down the shaft.
local function enter()
  flyTo(L.x + START.x, L.z + START.z, OUT)
  while site().y > START.y do
    if turtle.getFuelLevel() < 5 then fail("Out of fuel in the shaft") end
    stepDig("d")
  end
end

-- Out of the works to y 82 over the shaft.
local function leave()
  goTo({ x = START.x, y = SHAFT_TOP, z = START.z })
end

-- Up to the factory: hands over what it found, fuels up if it needs to, and
-- goes back to where it was.
local function trip(needFuel)
  state.trip = state.trip or site()
  save()
  leave()
  deliver()
  if needFuel then fuelStation(needFuel) end
  enter()
  goTo(state.trip)
  state.trip = nil
  save()
end

local function upkeep()
  if turtle.getItemCount(16) > 0 or freeSlots() < 2 then
    dropJunk()
    if freeSlots() < 3 then trip() end
  end
  if turtle.getFuelLevel() < homeCost() then
    refuel(math.min(turtle.getFuelLimit(), homeCost() + 5000))
    if turtle.getFuelLevel() < homeCost() then trip(homeCost() + 3000) end
  end
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

-- On the birth spot: find the factory beside it and turn away from it (north).
local function orient()
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
  -- The kit comes in just after the birth. The birth spot is the fuel
  -- station too: wait here until there's fuel for the way there and back.
  local need = 2 * homeCost(START)
  local waited = 0
  refuel(need)
  while turtle.getFuelLevel() < need do
    if waited % 30 == 0 then print(("Waiting at the fuel station (have %d, need %d)"):format(turtle.getFuelLevel(), need)) end
    waited = waited + 1
    sleep(2)
    refuel(need)
  end
  if not find(function(n) return n == BUCKET end) then print("No empty bucket: lava will be plugged, not drunk") end
  state.phase = "travel"
  save()
end

-- The cells of the zones the lamplighter was told to light (nil: all).
local only
local function onlyCells()
  if not state.only then return nil end
  if only then return only end
  only = {}
  for zn in state.only:gmatch("%d+") do
    local r = plan.zones[tonumber(zn)] and plan.zones[tonumber(zn)].route or ""
    local p = { x = START.x, y = START.y, z = START.z }
    for i = 1, #r do
      local ch = r:sub(i, i)
      local o = OPS[ch] or OPS[ch:lower()]
      if o then
        local n = { x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz }
        only[key(n)] = true
        if OPS[ch] then p = n end
      end
      if i % 4000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
    end
  end
  return only
end

-- Where the route stands before step n (moves are the lower-case letters).
local function posAt(n)
  local p = { x = START.x, y = START.y, z = START.z }
  for i = 1, n - 1 do
    local o = OPS[ROUTE:sub(i, i)]
    if o then p = { x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz } end
  end
  return p
end

local function travel()
  print(("Zone %s: flying to the shaft"):format(zone))
  -- North off the birth spot (the cobble generator is over it), up over
  -- whatever is in the way, back towards the factory's column, or else aside:
  -- a turtle coming the other way (the pine farm, to the fuel station) is
  -- let past.
  while world().z > F.z - 5 do
    local w = world()
    local toward = w.x < F.x and "e" or "w"
    if not (stepSoft("n", 20) or stepSoft("u", 5) or (w.x ~= F.x and stepSoft(toward, 5))) then
      if not (stepSoft("e", 5) or stepSoft("w", 5)) then sleep(5) end
      sleep(20)
    end
  end
  enter()
  if zone == "scout" then
    state.phase = "scout"
    save()
    return
  end
  if state.from and state.from > 1 then
    -- Taking over partway: to where the route stands before that step,
    -- through what's dug already.
    local n = math.min(state.from, #ROUTE)
    local p = posAt(n)
    print(("Zone %s: taking over from step %d of %d"):format(zone, n, #ROUTE))
    goTo(p)
    state.phase, state.step, state.at = "route", n, p
  else
    state.phase, state.step = "route", 1
  end
  state.from = nil
  save()
  print(("Zone %s: at the top of the hall, digging"):format(zone))
end

local function routePos()
  -- Where the turtle stands before step state.step.
  return state.at or { x = START.x, y = START.y, z = START.z }
end

local function excavate()
  math.randomseed(os.getComputerID and os.getComputerID() or tonumber(zone) or 7)
  if state.trip then
    -- A reboot on a trip: in the works, go back; on the surface, finish the
    -- delivery and come in first.
    local here = site()
    if not (dugSoFar()[key(here)] or (inShaft(here) and here.y <= SHAFT_TOP)) then
      outOfLane()
      deliver()
      enter()
    end
    goTo(state.trip)
    state.trip = nil
    save()
  end
  local lastNote = 0
  while state.step <= LAST do
    local op = ROUTE:sub(state.step, state.step)
    upkeep()
    local at = routePos()
    if LOOK[op] then
      plug((aim(LOOK[op])))
    elseif op == "T" then
      -- A torch on the floor below (only in the zones it was told, if any;
      -- none where one already stands).
      local slot = find(function(n) return n == TORCH end)
      local s = site()
      local here = onlyCells() == nil or onlyCells()[key({ x = s.x, y = s.y - 1, z = s.z })]
      local okb, below = turtle.inspectDown()
      if okb and below.name:find("torch", 1, true) then here = false end
      -- Water would wash a torch away: a source there is removed first; if
      -- water still flows in, no torch here, and the spot is noted for later.
      if here and okb and isFluid(below) then
        if below.state.level == 0 and plug(T.down) then
          local ok2, b2 = turtle.inspectDown()
          if ok2 and not isFluid(b2) then turtle.digDown() end
        end
        local ok3, b3 = turtle.inspectDown()
        if ok3 and isFluid(b3) then
          here = false
          state.wet = (state.wet or 0) + 1
          local h = fs.open("/wet-torches.txt", fs.exists("/wet-torches.txt") and "a" or "w")
          h.writeLine(key({ x = s.x, y = s.y - 1, z = s.z }))
          h.close()
          print(("Water at %s: no torch there yet"):format(key({ x = s.x, y = s.y - 1, z = s.z })))
        end
      end
      if not here then
        -- not this one
      elseif slot then
        turtle.select(slot)
        turtle.placeDown()
        turtle.select(1)
      elseif not state.noTorches then
        print("Out of torches")
        state.noTorches = true
      end
    elseif OPS[op] then
      local o = OPS[op]
      local to = { x = at.x + o.dx, y = at.y + o.dy, z = at.z + o.dz }
      local here = site()
      state.skipping = nil
      if state.hazards and state.hazards[key(to)] then
        state.skipping = true -- the hazard's own cell: left, and what's dug from it
      elseif not same(here, to) then
        local adjacent = math.abs(here.x - to.x) + math.abs(here.y - to.y) + math.abs(here.z - to.z) == 1
        if not (adjacent and stepDig(op)) then
          if state.hazards and state.hazards[key(to)] then state.skipping = true else goTo(to) end
        end
      end
      state.at = to
    elseif not state.skipping then
      clearAll((aim(op:lower())))
    end
    state.step = state.step + 1
    save()
    local pct = math.floor(100 * (state.step - 1) / #ROUTE)
    if pct >= lastNote + 5 then
      lastNote = pct
      print(("Zone %s: %d%% dug (fuel %d)"):format(zone, pct, turtle.getFuelLevel()))
    end
  end
  -- Hands in what it found and parks where it finished, out of the shaft.
  dropJunk()
  trip()
  -- (A filler re-digging zones goes on to the next.)
  state.phase = (state.redig and #state.redig > 0) and "redig" or "done"
  save()
  print(zone == "light" and "The works are lit" or ("Zone %s is dug out"):format(zone))
end

-- Up out of the works to hover high over the shaft, to be found by eye.
local SHOW_Y = 100
if showFor and state.phase == "route" then
  state.trip = state.trip or site()
  save()
  leave()
  rise(SHOW_Y)
  print(("Zone %s: hovering at %s for %d s"):format(zone, key(world()), showFor))
  sleep(showFor)
  enter()
  goTo(state.trip)
  state.trip = nil
  save()
end

-- A rescue: through the works to beside a turtle out of fuel, fuel into
-- it, and back to work.
if giveTo and state.phase == "route" then
  state.trip = state.trip or site()
  save()
  local t = { x = giveTo.x - L.x, y = giveTo.y - L.y, z = giveTo.z - L.z }
  local cells, done = allCells(), false
  for _, op in ipairs({ "u", "d", "n", "e", "s", "w" }) do
    local o = OPS[op]
    -- Stand on the far side of op from it, so op points at it.
    local from = { x = t.x - o.dx, y = t.y - o.dy, z = t.z - o.dz }
    if not done and (cells[key(from)] or inShaft(from)) then
      goTo(from)
      local side = aim(op)
      local ok, b = side.inspect()
      if ok and isMachine(b) then
        local have = 0
        for slot = 1, 16 do
          local item = turtle.getItemDetail(slot)
          if item and FUEL[item.name] and item.name ~= LAVA then have = have + item.count end
        end
        local left = giveTo.n or math.ceil(have / 2)
        for slot = 1, 16 do
          local item = turtle.getItemDetail(slot)
          if left > 0 and item and FUEL[item.name] and item.name ~= LAVA then
            turtle.select(slot)
            local n = math.min(left, item.count)
            if side.drop(n) then left = left - n end
          end
        end
        turtle.select(1)
        print(("Gave %d fuel to the turtle at %s"):format((giveTo.n or math.ceil(have / 2)) - left, key(giveTo)))
        done = true
      end
    end
  end
  if not done then print("No turtle to give to at " .. key(giveTo)) end
  goTo(state.trip)
  state.trip = nil
  save()
end

---------------------------------------------------------------------------
-- The scout: a geo scanner (carried, swapped in for the chunk controller to
-- scan) taken round the works, one stop in every 14-block cube of it. The
-- scanner sees radius 8 for free and reports world axes, which are ours.
---------------------------------------------------------------------------

local SCANNER = "advancedperipherals:geo_scanner"
local SCOUT_FILE = "/scout.txt"
local GRID = 14

local function equippedSide(match)
  local l, r = turtle.getEquippedLeft(), turtle.getEquippedRight()
  if l and match(l.name) then return "left" end
  if r and match(r.name) then return "right" end
end
local function equip(side) return side == "left" and turtle.equipLeft() or turtle.equipRight() end
local function isController(n) return n:find("chunk_controller", 1, true) ~= nil end

-- After a reboot mid-scan the scanner may still be on: the controller back.
local function controllerOn()
  local side = equippedSide(function(n) return n == SCANNER end)
  local slot = find(isController)
  if side and slot then
    turtle.select(slot)
    equip(side)
    turtle.select(1)
  end
end

local lastScan = -math.huge
local function scanHere()
  controllerOn()
  local side = equippedSide(isController)
  local slot = find(function(n) return n == SCANNER end)
  if not (side and slot) then fail("I need a chunk controller on and a geo scanner in my inventory") end
  local wait = 2.1 - (os.clock() - lastScan)
  if wait > 0 then sleep(wait) end
  turtle.select(slot)
  equip(side)
  sleep(0.2)
  local blocks, err
  for _ = 1, 3 do
    blocks, err = peripheral.call(side, "scanBlocks", 8)
    if blocks or not tostring(err):find("cooldown", 1, true) then break end
    sleep(1)
  end
  lastScan = os.clock()
  turtle.select(slot)
  equip(side)
  turtle.select(1)
  if not blocks then print("Scan failed: " .. tostring(err)) end
  return blocks or {}
end

-- One stop per cube of the works: the cell nearest the cube's middle,
-- visited nearest first.
local function scoutStops()
  local cubes = {}
  for k in pairs(allCells()) do
    local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x == START.x and z == START.z) then
      local ck = math.floor(x / GRID) .. "," .. math.floor(y / GRID) .. "," .. math.floor(z / GRID)
      local cx, cy, cz = (math.floor(x / GRID) + 0.5) * GRID, (math.floor(y / GRID) + 0.5) * GRID, (math.floor(z / GRID) + 0.5) * GRID
      local d = math.abs(x - cx) + math.abs(y - cy) + math.abs(z - cz)
      if not cubes[ck] or d < cubes[ck].d then cubes[ck] = { x = x, y = y, z = z, d = d } end
    end
  end
  local left, stops, at = {}, {}, { x = START.x, y = START.y, z = START.z }
  for _, c in pairs(cubes) do left[#left + 1] = c end
  while #left > 0 do
    local bi, bd = 1, math.huge
    for i, c in ipairs(left) do
      local d = math.abs(c.x - at.x) + math.abs(c.y - at.y) + math.abs(c.z - at.z)
      if d < bd then bi, bd = i, d end
    end
    at = table.remove(left, bi)
    stops[#stops + 1] = { x = at.x, y = at.y, z = at.z }
  end
  return stops
end

local function scout()
  local stops = scoutStops()
  state.stop = state.stop or 1
  print(("Scouting the works: %d stops"):format(#stops))
  local cells = allCells()
  while state.stop <= #stops do
    goTo(stops[state.stop])
    local w = world()
    local lines = {}
    for _, b in ipairs(scanHere()) do
      local sx, sy, sz = w.x + b.x - L.x, w.y + b.y - L.y, w.z + b.z - L.z
      local k = sx .. "," .. sy .. "," .. sz
      local wet = b.name:find("water", 1, true) or b.name:find("lava", 1, true)
      if wet or (cells[k] and not (sx == START.x and sz == START.z)) then
        lines[#lines + 1] = ("%d %d %d %s %s"):format(sx, sy, sz, b.name, cells[k] and "in" or "out")
      end
    end
    local h = fs.open(SCOUT_FILE, fs.exists(SCOUT_FILE) and state.stop > 1 and "a" or "w")
    for _, l in ipairs(lines) do h.writeLine(l) end
    h.close()
    print(("Stop %d of %d: %d things noted"):format(state.stop, #stops, #lines))
    state.stop = state.stop + 1
    save()
  end
  state.phase = "done"
  save()
  print("Scouting done: " .. SCOUT_FILE)
end

---------------------------------------------------------------------------
-- The drainer: round the wet and cluttered cells the scout found.
---------------------------------------------------------------------------

local function nearestFirst(list)
  local left, out, at = {}, {}, { x = START.x, y = START.y, z = START.z }
  for _, c in ipairs(list) do left[#left + 1] = c end
  while #left > 0 do
    local bi, bd = 1, math.huge
    for i, c in ipairs(left) do
      local d = math.abs(c.x - at.x) + math.abs(c.y - at.y) + math.abs(c.z - at.z)
      if d < bd then bi, bd = i, d end
    end
    at = table.remove(left, bi)
    out[#out + 1] = at
    if #out % 200 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
  end
  return out
end

local function drain()
  local h = fs.open("/blueprints/wet.lua", "r")
  if not h then fail("No /blueprints/wet.lua: make it with node design/wet.mjs and sync") end
  local wet = load(h.readAll())()
  h.close()
  local cells, list = allCells(), {}
  for zn in tostring(state.drainZones):gmatch("%d+") do
    for _, k in ipairs(wet[tonumber(zn)] or {}) do
      local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
      list[#list + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end
  end
  local stops = nearestFirst(list)
  state.stop = state.stop or 1
  state.drained = state.drained or { sealed = 0, removed = 0, dug = 0 }
  print(("Draining zones %s: %d cells to visit"):format(state.drainZones, #stops))
  while state.stop <= #stops do
    upkeep()
    local c = stops[state.stop]
    goTo(c)
    local d = state.drained
    for _, op in ipairs({ "u", "d", "n", "e", "s", "w" }) do
      local o = OPS[op]
      local n = { x = c.x + o.dx, y = c.y + o.dy, z = c.z + o.dz }
      local inside = cells[key(n)] ~= nil
      local t = aim(op)
      local ok, b = t.inspect()
      if ok and isFluid(b) then
        if not inside then
          -- In the wall: sealed for good.
          if plug(t) then d.sealed = d.sealed + 1 end
        elseif b.state.level == 0 then
          -- A source in the works: a block in, and out again.
          if plug(t) then
            local ok2, b2 = t.inspect()
            if ok2 and not isFluid(b2) and not isMachine(b2) then t.dig() end
            d.removed = d.removed + 1
          end
        end
      elseif ok and isHazard(b) then
        noteHazard(t, b)
      elseif ok and inside and not isMachine(b) then
        -- Something left standing in the works (an old plug): out.
        if t.dig() then d.dug = d.dug + 1 end
      end
    end
    state.stop = state.stop + 1
    save()
    if state.stop % 50 == 0 or state.stop > #stops then
      print(("Draining: %d of %d (%d sealed in the walls, %d sources removed, %d leftovers dug)")
        :format(state.stop - 1, #stops, d.sealed, d.removed, d.dug))
    end
  end
  state.phase = "done"
  save()
  print("Drained zones " .. state.drainZones)
end

---------------------------------------------------------------------------
-- The porter: stocks the chest station.
---------------------------------------------------------------------------

local BLOCK = "factory_blocks:factory"
local function count(name)
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then n = n + item.count end
  end
  return n
end

-- Stands in front of a chest (one south of it), facing it.
local function atChest(c)
  goTo({ x = c.x, y = c.y, z = c.z + 1 })
  nav.face(OPS.n.dir)
end

local function porter()
  local h = fs.open("/blueprints/station.lua", "r")
  if not h then fail("No /blueprints/station.lua: make it with node design/station.mjs and sync") end
  local station = load(h.readAll())()
  h.close()
  state.placed = state.placed or 0
  state.filled = state.filled or {}
  local function left()
    local n = 0
    for i, c in ipairs(station.chests) do n = n + c.n - (state.filled[i] or 0) end
    return n
  end
  while state.placed < #station.chests or left() > 0 do
    -- Fuel only: its load isn't for the factory's input chest.
    if turtle.getFuelLevel() < homeCost() then refuel(homeCost() + 1000) end
    -- Loaded up at the fuel station when it has nothing to put away.
    if count(BLOCK) == 0 and (state.placed >= #station.chests or count("minecraft:chest") == 0) then
      state.trip = state.trip or site()
      save()
      leave()
      intoStation()
      print("At the station, waiting to be loaded")
      local waited = 0
      while count(BLOCK) == 0 and count("minecraft:chest") == 0 and waited < 90 do
        refuel(2 * homeCost(START))
        sleep(3)
        waited = waited + 3
      end
      refuel(2 * homeCost(START))
      while world().z > F.z - 4 do stepSoft("n") end
      enter()
      state.trip = nil
      save()
      if count(BLOCK) == 0 and count("minecraft:chest") == 0 then
        print("Nothing to carry yet (the factory may be out of iron or stone); trying again in a while")
        sleep(120)
      end
    end
    -- The chests first, against the back wall.
    while state.placed < #station.chests and count("minecraft:chest") > 0 do
      local c = station.chests[state.placed + 1]
      atChest(c)
      local slot = find(function(n) return n == "minecraft:chest" end)
      turtle.select(slot)
      local ok, b = turtle.inspect()
      if not (ok and b.name == "minecraft:chest") then
        clearAll(T.forward)
        turtle.place()
      end
      turtle.select(1)
      state.placed = state.placed + 1
      save()
    end
    -- Then each chest filled to its count, in order.
    for i, c in ipairs(station.chests) do
      if i > state.placed or count(BLOCK) == 0 then break end
      local want = c.n - (state.filled[i] or 0)
      if want > 0 then
        atChest(c)
        for slot = 1, 16 do
          local item = turtle.getItemDetail(slot)
          if want > 0 and item and item.name == BLOCK then
            turtle.select(slot)
            local n = math.min(want, item.count)
            if turtle.drop(n) then
              state.filled[i] = (state.filled[i] or 0) + n
              want = want - n
            end
          end
        end
        turtle.select(1)
        save()
      end
    end
    print(("Chest station: %d chests up, %d blocks still to bring"):format(state.placed, left()))
  end
  state.phase = "done"
  save()
  print("The chest station is stocked")
end

---------------------------------------------------------------------------
-- The filler: dries flooded zones (see the usage at the top).
---------------------------------------------------------------------------

local FILL = "minecraft:cobblestone"
local FILL_LOAD = 12 * 64

-- Something to fill with: cobblestone, or any junk it carries.
local function fillSlot()
  return find(function(n) return n == FILL end) or find(isJunk)
end

-- Asks the factory for something by its label while on the fuel station.
local function askFactory(item, n)
  local name = os.getComputerLabel and os.getComputerLabel() or nil
  local base = (name or ""):gsub(" %[need .-%]$", "")
  if os.setComputerLabel then os.setComputerLabel(("%s [need %s %d]"):format(base, item, n)) end
  state.trip = state.trip or site()
  save()
  leave()
  intoStation()
  local waited = 0
  while count(item) < n and waited < 120 do
    refuel(2 * homeCost(START))
    sleep(3)
    waited = waited + 3
  end
  refuel(2 * homeCost(START))
  if os.setComputerLabel and name then os.setComputerLabel(base) end
  while world().z > F.z - 4 do stepSoft("n") end
  enter()
  goTo(state.trip)
  state.trip = nil
  save()
end

local function fill()
  -- The zones' cells, by layer; the wet layers from the scout's map if
  -- there is one, else all of them.
  local zoneCells, layers = {}, {}
  for zn in tostring(state.fillZones):gmatch("%d+") do
    local r = plan.zones[tonumber(zn)] and plan.zones[tonumber(zn)].route or ""
    local p = { x = START.x, y = START.y, z = START.z }
    for i = 1, #r do
      local ch = r:sub(i, i)
      local o = OPS[ch] or OPS[ch:lower()]
      if o then
        local n = { x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz }
        if not (n.x == START.x and n.z == START.z) then zoneCells[key(n)] = n end
        if OPS[ch] then p = n end
      end
      if i % 4000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
    end
  end
  local lo, hi = math.huge, -math.huge
  local h = fs.open("/blueprints/wet.lua", "r")
  if h then
    local wet = load(h.readAll())()
    h.close()
    for zn in tostring(state.fillZones):gmatch("%d+") do
      for _, k in ipairs(wet[tonumber(zn)] or {}) do
        local y = tonumber(k:match(",(-?%d+),"))
        lo, hi = math.min(lo, y), math.max(hi, y)
      end
    end
  end
  for _, c in pairs(zoneCells) do
    if lo == math.huge or (c.y >= lo and c.y <= hi) then
      layers[c.y] = layers[c.y] or {}
      table.insert(layers[c.y], c)
    end
  end
  local ys = {}
  for y in pairs(layers) do ys[#ys + 1] = y end
  table.sort(ys)
  local cells = allCells()
  state.fillAt = state.fillAt or { layer = 1, i = 1 }
  state.filled = state.filled or 0
  print(("Filling the water in zones %s: layers %d to %d"):format(state.fillZones, ys[1] or 0, ys[#ys] or 0))
  while state.fillAt.layer <= #ys do
    local list = layers[ys[state.fillAt.layer]]
    -- Rows back and forth, so most steps are next to the last.
    table.sort(list, function(a, b)
      if a.z ~= b.z then return a.z < b.z end
      if a.z % 2 == 0 then return a.x < b.x end
      return a.x > b.x
    end)
    while state.fillAt.i <= #list do
      local c = list[state.fillAt.i]
      local above = { x = c.x, y = c.y + 1, z = c.z }
      if cells[key(above)] and not (state.hazards and state.hazards[key(above)]) then
        goTo(above)
        local ok, b = turtle.inspectDown()
        if ok and isFluid(b) then
          if b.name == "minecraft:lava" and b.state.level == 0 then
            plug(T.down) -- into the bucket: fuel
          else
            if not fillSlot() then askFactory(FILL, FILL_LOAD) goTo(above) end
            local slot = fillSlot()
            if slot then
              turtle.select(slot)
              if turtle.placeDown() then state.filled = state.filled + 1 end
              turtle.select(1)
            end
          end
        end
      end
      state.fillAt.i = state.fillAt.i + 1
      if state.fillAt.i % 100 == 0 then
        save()
        print(("Filling: layer %d (%d of %d), %d cells filled"):format(ys[state.fillAt.layer], state.fillAt.i, #list, state.filled))
      end
    end
    state.fillAt = { layer = state.fillAt.layer + 1, i = 1 }
    save()
  end
  -- Then each zone dug out again, dry, its route sealing the walls.
  state.redig = state.redig or {}
  for zn in tostring(state.fillZones):gmatch("%d+") do state.redig[#state.redig + 1] = tonumber(zn) end
  state.phase = "redig"
  save()
  print(("Filled %d cells; digging the zones out again"):format(state.filled))
end

-- Helping: through the works to the start of its stretch, then dig it.
if state.phase == "help" then
  print(("Zone %s: helping with steps %d to %d"):format(zone, state.from, LAST))
  local p = posAt(state.from)
  goTo(p)
  state.phase, state.step, state.at, state.from = "route", state.from, p, nil
  save()
end

if state.phase == "orient" then orient() end
if state.phase == "travel" then travel() end
if state.phase == "scout" then scout() end
if state.phase == "drain" then drain() end
if state.phase == "porter" then porter() end
if state.phase == "fill" then fill() end
if state.phase == "redig" then
  -- One zone after another, the whole route each time, as a helper would.
  local nextZone = table.remove(state.redig, 1)
  if nextZone then
    state.zone, state.phase, state.from, state.to = nextZone, "help", 1, nil
    state.step, state.at = nil, nil
    save()
    print(("Re-digging zone %d"):format(nextZone))
    if os.reboot then os.reboot() end
    return
  end
  state.phase = "done"
  save()
end
if state.phase == "route" then excavate() end
if state.phase == "redig" and os.reboot then os.reboot() end
if state.phase == "done" then
  print(({ scout = "Done scouting", drain = "Done draining", porter = "The chest station is stocked" })[zone]
    or ("Done: zone %s is dug out"):format(zone))
end
