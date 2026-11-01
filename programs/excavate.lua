-- Excavator for the Clockworks: one of a crew that clears the whole volume
-- of the works, every block any structure sets, so the builders only have to
-- place. A mining turtle with a chunk controller. The volume is cut into
-- wedges round the lift, one per turtle (zones in /blueprints/excavation.lua,
-- made by design/generate.mjs).
--
-- Start: dig out the block east of the elevator while it waits at the top
-- of the lift, place the turtle in that hole facing the elevator, and put a
-- chest right behind it (east) for what the crew finds. Fuel: about 5,000
-- per zone (6 coal blocks), and an empty bucket. It goes down the service
-- shaft beside the lift to the top of the hall and digs its zone. The next
-- turtle can go in once this one has left the top.

-- Along the way it:
--   drops stone and dirt (they despawn) and keeps ores and anything unknown,
--     taking them up to the chest when it runs out of room
--   drinks lava sources with its bucket for fuel, and plugs other liquids
--     with a block of stone: kept rock is never left leaking into the works
--   burns coal it finds and, when out of fuel, waits at the chest for more
--   never digs another turtle or computer
--
-- Usage: excavate <zone>   (what autorun runs; resumes after reboots)
--        excavate status

local nav = require("lib.nav")

local STATE = "/.excavate"
local PLAN = "/blueprints/excavation.lua"
local MARGIN = 150        -- fuel kept beyond the way home

local FUEL = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
  ["minecraft:lava_bucket"] = true, ["mekanism:block_charcoal"] = true,
}
local BUCKET = "minecraft:bucket"
-- Dropped as junk unless the name also says it's worth keeping.
local JUNK = {
  "stone", "cobble", "deepslate", "tuff", "granite", "diorite", "andesite", "calcite", "dirt",
  "gravel", "sand", "clay", "dripstone", "basalt", "flint", "moss", "mud", "netherrack",
  "blackstone", "grass", "obsidian", "limestone", "scoria", "scorchia", "asurine", "crimsite",
  "ochrum", "veridium", "slate", "marble", "bone_block", "glow_lichen", "pebble",
}
local KEEP = { "ore", "raw_", "coal", "diamond", "emerald", "lapis", "redstone", "quartz", "amethyst", "gem" }

local function has(name, words)
  for _, w in ipairs(words) do if name:find(w, 1, true) then return true end end
  return false
end
local function isJunk(name) return has(name, JUNK) and not has(name, KEEP) end
local function isMachine(b) return b.name:find("computercraft:", 1, true) ~= nil end
local function isFluid(b) return b.state ~= nil and b.state.level ~= nil end

local function fail(msg) error(msg, 0) end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state
do
  local h = fs.open(STATE, "r")
  if h then
    state = textutils.unserialise(h.readAll())
    h.close()
  end
end

local plan
do
  local h = fs.open(PLAN, "r")
  if not h then fail("No route: " .. PLAN .. " is missing") end
  plan = load(h.readAll(), "=" .. PLAN, "t", { table = table })()
  h.close()
end
local arg1 = ...
if arg1 == "status" then
  if not state or not state.step then print("Not started") return end
  local route = plan.zones[state.zone].route
  print(("Excavating zone %d: step %d of %d (%d%%)%s"):format(state.zone, state.step, #route,
    math.floor(100 * (state.step - 1) / #route), state.phase == "done" and ", done" or ""))
  return
end
local zone = (state and state.zone) or tonumber(arg1)
if not (zone and plan.zones[zone]) then fail(("Usage: excavate <zone 1-%d>"):format(#plan.zones)) end
local ROUTE = plan.zones[zone].route

-- The lift's top is liftDepth above its bottom: that's where it starts.
state = state or { phase = "descend", zone = zone, top = plan.liftDepth }
local function save()
  local h = fs.open(STATE, "w")
  h.write(textutils.serialise(state))
  h.close()
end
nav.init(state, save)
nav.recover()
save()

---------------------------------------------------------------------------
-- Site coordinates: x east, y up, z south, origin at the lift's bottom.
-- nav starts facing west at the top of the service shaft, (1, top, 0),
-- right above the start of the route:
-- nav +z is west and nav +x (to the right) is north.
---------------------------------------------------------------------------

local START = plan.start
local function site()
  local p = nav.pos()
  return { x = START.x - p.z, y = (state.top or 0) + p.y, z = START.z - p.x }
end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function key(p) return p.x .. "," .. p.y .. "," .. p.z end

-- Route op -> world direction. nav dir of each: north = 1, east = 2,
-- south = 3, west = 0.
local OPS = {
  n = { dx = 0, dy = 0, dz = -1, dir = 1 }, e = { dx = 1, dy = 0, dz = 0, dir = 2 },
  s = { dx = 0, dy = 0, dz = 1, dir = 3 }, w = { dx = -1, dy = 0, dz = 0, dir = 0 },
  u = { dx = 0, dy = 1, dz = 0, kind = "up" }, d = { dx = 0, dy = -1, dz = 0, kind = "down" },
}
local LOOK = { ["0"] = "n", ["1"] = "e", ["2"] = "s", ["3"] = "w", ["4"] = "u", ["5"] = "d" }

local T = {
  forward = { inspect = turtle.inspect, dig = turtle.dig, place = turtle.place, detect = turtle.detect, drop = turtle.drop },
  up = { inspect = turtle.inspectUp, dig = turtle.digUp, place = turtle.placeUp, detect = turtle.detectUp, drop = turtle.dropUp },
  down = { inspect = turtle.inspectDown, dig = turtle.digDown, place = turtle.placeDown, detect = turtle.detectDown, drop = turtle.dropDown },
}
-- Turns towards a route direction and returns the matching turtle calls.
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

-- Fuel to get home from here, roughly.
local function homeCost()
  local p = site()
  return math.abs(p.x - START.x) + math.abs(p.z - START.z) + math.abs(state.top - p.y) + MARGIN
end

---------------------------------------------------------------------------
-- Liquids
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

-- Digs whatever is in direction t, never a turtle or computer: those are
-- waited out, for ever or for `patience` seconds (then it returns false).
-- Falling gravel and sand keep coming until it's clear.
local function clearAll(t, patience)
  local waited, digs = 0, 0
  while true do
    plug(t)
    local ok, b = t.inspect()
    if not ok then return true end
    if isMachine(b) then
      if patience and waited >= patience then return false end
      if waited % 60 == 0 then print("A turtle is in my way; waiting") end
      sleep(5)
      waited = waited + 5
    else
      if not t.dig() then fail(("Can't dig %s at %s"):format(b.name, key(site()))) end
      digs = digs + 1
      if digs > 64 then fail("Something keeps falling in front of me at " .. key(site())) end
    end
  end
end

local DIG = { canDig = function(b) return not isMachine(b) end }

local function move(kind)
  local ok, why = nav.move(kind, DIG)
  if not ok then fail(("Stuck at %s: %s"):format(key(site()), why)) end
end

---------------------------------------------------------------------------
-- Ways home and back: through what the route has dug so far, and the
-- service shaft.
---------------------------------------------------------------------------

local function dugSoFar()
  local open, p = {}, { x = START.x, y = START.y, z = START.z }
  for y = START.y, state.top do open[START.x .. "," .. y .. "," .. START.z] = true end
  for i = 1, state.step - 1 do
    local o = OPS[ROUTE:sub(i, i)]
    if o then
      p = { x = p.x + o.dx, y = p.y + o.dy, z = p.z + o.dz }
      open[key(p)] = true
    end
  end
  return open
end

local function path(from, to)
  local open = dugSoFar()
  open[key(from)], open[key(to)] = true, true
  local prev, queue, head = { [key(from)] = false }, { from }, 1
  while queue[head] do
    local c = queue[head]
    head = head + 1
    if same(c, to) then break end
    for op, o in pairs(OPS) do
      local n = { x = c.x + o.dx, y = c.y + o.dy, z = c.z + o.dz }
      local k = key(n)
      if open[k] and prev[k] == nil then
        prev[k] = { c, op }
        queue[#queue + 1] = n
      end
    end
    if head % 2000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
  end
  if prev[key(to)] == nil then fail(("No way from %s to %s"):format(key(from), key(to))) end
  local ops, k = {}, key(to)
  while prev[k] do
    table.insert(ops, 1, prev[k][2])
    k = key(prev[k][1])
  end
  return ops
end

local function inShaft(p) return p.x == START.x and p.z == START.z and p.y >= START.y end
local BACK = { u = "d", d = "u", n = "s", s = "n", e = "w", w = "e" }

-- The shaft is one wide and the crew shares it. On the way somewhere, a
-- turtle that finds another in its way for a while backs out of the shaft
-- (the one coming down has right of way) and tries again later.
local function goTo(to)
  while true do
    local trail, stuck = {}, false
    for _, op in ipairs(path(site(), to)) do
      local t, kind = aim(op)
      if not clearAll(t, 30 + math.random(30)) then stuck = true break end
      move(kind)
      trail[#trail + 1] = op
    end
    if not stuck then return end
    print("Making way for another turtle")
    for i = #trail, 1, -1 do
      if not inShaft(site()) then break end
      local t, kind = aim(BACK[trail[i]])
      clearAll(t)
      move(kind)
    end
    sleep(10 + math.random(30))
  end
end

local function home() return { x = START.x, y = state.top, z = START.z } end

-- Up to the chest: hands over what it found, waits for fuel if it needs it,
-- and (unless it's finished) goes back to where it was.
local function trip(needFuel, stay)
  if not stay then
    state.trip = state.trip or site()
    save()
  end
  goTo(home())
  nav.face(2) -- east, the chest
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not FUEL[item.name] and item.name ~= BUCKET and not isJunk(item.name) then
      turtle.select(slot)
      if not turtle.drop() then print("The chest is full") end
    end
  end
  turtle.select(1)
  local waited = 0
  while needFuel and turtle.getFuelLevel() < needFuel do
    -- Take what's in the chest, burn the fuel, put the rest back.
    while freeSlots() > 1 and turtle.suck() do end
    refuel(math.min(turtle.getFuelLimit(), needFuel * 2))
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and not FUEL[item.name] and item.name ~= BUCKET and not isJunk(item.name) then
        turtle.select(slot)
        turtle.drop()
      end
    end
    turtle.select(1)
    if turtle.getFuelLevel() < needFuel then
      if waited % 30 == 0 then print(("Waiting for fuel at the chest (have %d, need %d)"):format(turtle.getFuelLevel(), needFuel)) end
      waited = waited + 1
      sleep(10)
    end
  end
  if stay then return end
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
    if turtle.getFuelLevel() < homeCost() then trip(homeCost() + 5000) end
  end
end

---------------------------------------------------------------------------
-- Down the service shaft
---------------------------------------------------------------------------

-- Level with the elevator at the top (so exactly liftDepth above the lift's
-- bottom), it goes straight down to the top of the hall, checking all the
-- way that the lift's shaft is beside it.
local function descend()
  if not state.started then
    local ok, b = turtle.inspect()
    if not (ok and isMachine(b)) then
      fail("Place me at the top of the lift, east of the elevator while it waits there, facing it")
    end
    if not find(function(n) return n == BUCKET end) then print("No empty bucket: lava will be plugged, not drunk") end
    state.started = true
    save()
    print(("Zone %d: going down the service shaft"):format(zone))
  end
  nav.face(0)
  -- Opening the turtle to give it its coal switches it on: wait for the coal.
  refuel(500)
  while turtle.getFuelLevel() < site().y - START.y + 10 do
    print("Put my coal (and a bucket) in me")
    os.pullEvent("turtle_inventory")
    sleep(2)
    refuel(500)
  end
  while site().y > START.y do
    local ok, b = turtle.inspect()
    if ok and not isMachine(b) and not isFluid(b) then
      fail(("The lift's shaft beside me is blocked %d above its bottom: am I in the right place?"):format(site().y))
    end
    if turtle.getFuelLevel() < 5 then fail("Out of fuel on the way down") end
    clearAll(T.down)
    move("down")
  end
  state.phase, state.step = "route", 1
  save()
  print(("Zone %d: at the top of the hall, digging"):format(zone))
end

---------------------------------------------------------------------------
-- The route
---------------------------------------------------------------------------

local function routePos()
  -- Where the turtle stands before step state.step.
  if state.at then return state.at end
  return { x = START.x, y = START.y, z = START.z }
end

local function excavate()
  if state.trip then goTo(state.trip) state.trip = nil save() end
  math.randomseed(os.getComputerID and os.getComputerID() or zone)
  local lastNote = 0
  while state.step <= #ROUTE do
    local op = ROUTE:sub(state.step, state.step)
    upkeep()
    local at = routePos()
    if LOOK[op] then
      plug((aim(LOOK[op])))
    elseif OPS[op] then
      local o = OPS[op]
      local to = { x = at.x + o.dx, y = at.y + o.dy, z = at.z + o.dz }
      if not same(site(), to) then
        local t, kind = aim(op)
        clearAll(t)
        move(kind)
      end
      state.at = to
    else
      local t = aim(op:lower())
      clearAll(t)
    end
    state.step = state.step + 1
    save()
    local pct = math.floor(100 * (state.step - 1) / #ROUTE)
    if pct >= lastNote + 5 then
      lastNote = pct
      print(("Excavated %d%% (fuel %d)"):format(pct, turtle.getFuelLevel()))
    end
  end
  -- Hands in what it found and parks where it finished, out of the shaft.
  dropJunk()
  trip()
  state.phase = "done"
  save()
  print(("Zone %d is dug out"):format(zone))
end

if state.phase == "descend" then descend() end
if state.phase == "route" then excavate() end
if state.phase == "done" then print(("Done: zone %d is dug out"):format(zone)) end
