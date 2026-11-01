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
-- Usage: excavate <zone>   (what autorun runs; resumes after reboots)
--        excavate light
--        excavate status
--        excavate show [seconds]   come up and hover high over the shaft
--                                  (to be seen), then carry on

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.excavate"
local PLAN = "/blueprints/excavation.lua"
local MARGIN = 150        -- fuel kept beyond the way to the factory
local OUT, BACK = 80, 82  -- cruise heights, to the shaft and from it

local FUEL = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
  ["minecraft:lava_bucket"] = true, ["mekanism:block_charcoal"] = true,
}
local BUCKET = "minecraft:bucket"
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
local zone = (state and state.zone) or tonumber(arg1) or (arg1 == "light" and plan.light and "light")
local job = zone == "light" and plan.light or plan.zones[zone]
if not job then fail(("Usage: excavate <zone 1-%d> | light"):format(#plan.zones)) end
local ROUTE = job.route

state = state or { phase = "orient", zone = zone }
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
  return math.abs(p.x - START.x) + math.abs(p.z - START.z) + math.abs(SHAFT_TOP - p.y)
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
local function clearAll(t, patience, canDig, sealLeaks)
  local waited, digs, refills = 0, 0, 0
  while true do
    if not canDig then
      local ok, b = t.inspect()
      if ok and isFluid(b) then
        -- Water or lava that keeps coming back is fed from somewhere: after
        -- a few tries leave it (moving: turtles pass through liquids) or, when
        -- only digging, seal it with stone and leave that.
        refills = refills + 1
        if refills > 3 then
          if sealLeaks then
            local slot = find(isJunk)
            if slot then turtle.select(slot) t.place() turtle.select(1) end
            print("Sealed a leak at " .. key(world()))
          end
          return true
        end
      end
      plug(t)
    end
    local ok, b = t.inspect()
    if not ok or (canDig and isFluid(b)) then return true end
    if isMachine(b) then
      if patience and waited >= patience then return false end
      if waited % 60 == 0 then print("A turtle is in my way; waiting") end
      sleep(5)
      waited = waited + 5
    elseif canDig and not canDig(b) then
      return false, "blocked"
    elseif sealLeaks and refills > 3 then
      return true
    else
      if not t.dig() then fail(("Can't dig %s at %s"):format(b.name, key(world()))) end
      digs = digs + 1
      if digs > 64 then fail("Something keeps falling in front of me at " .. key(world())) end
    end
  end
end

local DIG = { canDig = function(b) return not isMachine(b) end }

local function move(kind)
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

local function fuelStation(need)
  flyTo(F.x, F.z - 4, OUT)
  sink(F.y)
  while world().z < F.z - 1 do stepSoft("s") end
  local waited = 0
  while turtle.getFuelLevel() < need do
    refuel(need)
    if turtle.getFuelLevel() < need then
      if waited % 30 == 0 then print(("Waiting at the fuel station (have %d, need %d)"):format(turtle.getFuelLevel(), need)) end
      waited = waited + 1
      sleep(2)
    end
  end
  while world().z > F.z - 4 do stepSoft("n") end
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

-- To a site cell through the works and the shaft. The shaft is one wide and
-- the crew shares it. A turtle that finds another in its way for a while
-- tries again round it, through the whole works if need be; one in the
-- shaft backs out of it, or steps aside, so the other can pass (the one
-- coming down has right of way).
local function goTo(to)
  local avoid, wide = {}, false
  while true do
    local ops = path(site(), to, avoid, wide)
    if not ops then
      -- Hemmed in for now: forget the blockers, wait, try again.
      avoid, wide = {}, true
      ops = path(site(), to, avoid, wide)
      if not ops then fail(("No way from %s to %s"):format(key(site()), key(to))) end
      sleep(10 + math.random(20))
    end
    local trail, blocked = {}, nil
    for _, op in ipairs(ops) do
      if not stepDig(op, 30 + math.random(30)) then
        local p, o = site(), OPS[op]
        blocked = key({ x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz })
        break
      end
      trail[#trail + 1] = op
    end
    if not blocked then return end
    print("Making way for another turtle")
    if blocked ~= key(to) then avoid[blocked] = true end
    wide = true
    if inShaft(site()) then
      for i = #trail, 1, -1 do
        if not inShaft(site()) then break end
        stepDig(BACKWARD[trail[i]], 20)
      end
      -- Nothing to back into: step aside into the works.
      for _, op in ipairs({ "n", "e", "s", "w" }) do
        if not inShaft(site()) then break end
        local p, o = site(), OPS[op]
        local n = key({ x = p.x + o.dx, y = p.y, z = p.z + o.dz })
        if allCells()[n] and not avoid[n] then stepDig(op, 5) end
      end
    end
    sleep(5 + math.random(20))
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
  state.phase, state.step = "route", 1
  save()
  print(("Zone %s: at the top of the hall, digging"):format(zone))
end

local function routePos()
  -- Where the turtle stands before step state.step.
  return state.at or { x = START.x, y = START.y, z = START.z }
end

local function excavate()
  math.randomseed(os.getComputerID and os.getComputerID() or zone)
  if state.trip then
    -- A reboot on a trip: in the works, go back; on the surface, finish the
    -- delivery and come in first.
    local here = site()
    if not (dugSoFar()[key(here)] or (inShaft(here) and here.y <= SHAFT_TOP)) then
      deliver()
      enter()
    end
    goTo(state.trip)
    state.trip = nil
    save()
  end
  local lastNote = 0
  while state.step <= #ROUTE do
    local op = ROUTE:sub(state.step, state.step)
    upkeep()
    local at = routePos()
    if LOOK[op] then
      plug((aim(LOOK[op])))
    elseif op == "T" then
      -- A torch on the floor below.
      local slot = find(function(n) return n == TORCH end)
      if slot then
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
      if not same(site(), to) then stepDig(op) end
      state.at = to
    else
      clearAll((aim(op:lower())), nil, nil, true)
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
  state.phase = "done"
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

if state.phase == "orient" then orient() end
if state.phase == "travel" then travel() end
if state.phase == "route" then excavate() end
if state.phase == "done" then print(("Done: zone %s is dug out"):format(zone)) end
