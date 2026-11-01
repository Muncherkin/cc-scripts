-- Offline tests for programs/excavate.lua. Run with: npm test
-- The whole crew on the real routes (slow): node tests/run.js tests/excavate_test.lua full
--
-- The simulator's coordinates are the program's nav frame: each turtle is
-- born on the birth spot, one north of the factory, and nav +z is north,
-- +x east. World (x, y, z) = (F.x + nx, F.y + ny, F.z - 1 - nz).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local PROGRAM = "programs/excavate.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local STONE = { name = "minecraft:stone" }
local MACHINE = { name = "computercraft:turtle_normal" }

-- A world of stone up to the ground (one below the factory), with the
-- factory, its input chest and the birth spot. extra: world cells -> blocks.
local function setup(opts)
  local h = load(opts.plan or readfile("programs/blueprints/excavation.lua"))()
  local F, L = h.factory, h.lift
  local function N(x, y, z) return x - F.x, y - F.y, F.z - 1 - z end
  local extra = {}
  for k, b in pairs(opts.extra or {}) do
    local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
    local nx, ny, nz = N(tonumber(x), tonumber(y), tonumber(z))
    extra[nx .. "," .. ny .. "," .. nz] = b
  end
  local world = sim.newWorld(function(x, y, z)
    local e = extra[x .. "," .. y .. "," .. z]
    if e then return e end
    if y < 0 then return STONE end
  end)
  world.set(N(F.x, F.y, F.z)) world.set(0, 0, -1, MACHINE)           -- the factory
  world.set(0, 1, -1, { name = "minecraft:chest" })                  -- its input chest
  world.containers["0,1,-1"] = {}
  world.set(0, 1, 0, { name = "minecraft:cobblestone" })              -- the cobble generator's floor
  local f = { world = world, plan = h, sleeps = 0, N = N }
  -- A newborn on the birth spot.
  function f.newTurtle(inventory)
    f.t = sim.newTurtle(world, {
      fuel = opts.fuel or 0,
      right = "minecraft:diamond_pickaxe", left = "advancedperipherals:chunk_controller",
      inventory = inventory or opts.inventory or { { "minecraft:coal", 64 }, { "minecraft:bucket", 1 } },
    })
    f.computer = sim.newComputer()
    f.computer.files["/blueprints/excavation.lua"] = opts.plan or readfile("programs/blueprints/excavation.lua")
    f.computer.sleep = function(s)
      f.sleeps = f.sleeps + 1
      if opts.onSleep then opts.onSleep(f, s) end
      if f.sleeps > 20000 then error("STUCK_SLEEPING", 0) end
    end
  end
  f.newTurtle()
  -- What's at a site cell.
  function f.at(sx, sy, sz)
    local b = world.get(N(L.x + sx, L.y + sy, L.z + sz))
    return b and b.name
  end
  function f.w(x, y, z)
    local b = world.get(N(x, y, z))
    return b and b.name
  end
  function f.site()
    return F.x + f.t.x - L.x, F.y + f.t.y - L.y, F.z - 1 - f.t.z - L.z
  end
  function f.chest(item)
    local n = 0
    for _, it in ipairs(world.containers["0,1,-1"]) do if it.name == item then n = n + it.count end end
    return n
  end
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

-- A small site: the factory at world (110, 20, 110), the lift's bottom at
-- (100, 0, 100), so the shaft is at world x 103, z 100. One zone.
local function plan(route)
  return ([[return { cells = 0, liftDepth = 71, lift = { x = 100, y = 0, z = 100 }, shaftTop = 77,
    factory = { x = 110, y = 20, z = 110 }, start = { x = 3, y = 8, z = 0 }, zones = { { route = %q } } }]]):format(route)
end

-- The route's cells, replayed in site coordinates.
local OPS = { n = { 0, 0, -1 }, e = { 1, 0, 0 }, s = { 0, 0, 1 }, w = { -1, 0, 0 }, u = { 0, 1, 0 }, d = { 0, -1, 0 } }
local function routeCells(route, start, cells)
  cells = cells or {}
  local p = { start.x, start.y, start.z }
  for i = 1, #route do
    local ch = route:sub(i, i)
    local o = OPS[ch:lower()]
    if o then
      local n = { p[1] + o[1], p[2] + o[2], p[3] + o[3] }
      cells[n[1] .. "," .. n[2] .. "," .. n[3]] = true
      if OPS[ch] then p = n end
    end
  end
  return cells, p
end
local START = { x = 3, y = 8, z = 0 }

local function allDug(f, cells)
  local left = 0
  for k in pairs(cells) do
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    if f.at(tonumber(sx), tonumber(sy), tonumber(sz)) then left = left + 1 end
  end
  return left
end

print("Flies from the factory, digs its route, plugs water, drinks lava, delivers ores")
do
  local route = "ssUD2e0U" .. "nnD" .. "4"
  local f = setup({
    plan = plan(route),
    extra = {
      ["103,8,102"] = { name = "minecraft:lava", state = { level = 0 } },  -- a lava source in the way
      ["103,8,103"] = { name = "minecraft:water", state = { level = 0 } }, -- water beyond the edge
      ["103,9,102"] = { name = "minecraft:iron_ore" },
      ["104,9,102"] = { name = "minecraft:gravel" },                        -- falls when dug from below
      ["104,10,102"] = { name = "minecraft:gravel" },
      ["106,19,105"] = { name = "minecraft:snow" },                          -- on the way out
      ["103,80,100"] = { name = "regions_unexplored:pine_leaves" },          -- a pine by the shaft
      ["103,81,100"] = { name = "regions_unexplored:pine_leaves" },
    },
  })
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Zone 1: at the top of the hall", 1, true) ~= nil, "gets to the top of the hall")
  check(allDug(f, routeCells(route, START)) == 0, "every route cell dug")
  check(f.at(3, 8, 3) == "minecraft:cobblestone", "water beyond the edge plugged with stone (" .. tostring(f.at(3, 8, 3)) .. ")")
  check(f.at(4, 8, 3) == "minecraft:stone" and f.at(2, 8, 2) == "minecraft:stone", "rock beside the route kept")
  local shaft = true
  for y = 9, 19 do shaft = shaft and f.at(3, y, 0) == nil end
  check(shaft, "shaft dug straight down")
  check(f.at(2, 15, 0) == "minecraft:stone" and f.at(3, 15, 1) == "minecraft:stone", "nothing dug beside the shaft")
  check(f.w(110, 20, 110) == "computercraft:turtle_normal" and f.w(110, 21, 110) == "minecraft:chest", "factory and chest untouched")
  check(f.chest("minecraft:raw_iron") == 1, "iron delivered to the factory's input chest")
  check(f.chest("minecraft:cobblestone") == 0, "no stone carried up")
  local x, y, z = f.site()
  check(x == 4 and y == 8 and z == 0, ("parked where it finished (%d,%d,%d)"):format(x, y, z))
  check(f.t.fuel > 1000, "drank the lava (fuel " .. f.t.fuel .. ")")
end

print("Refuses to start anywhere but the birth spot")
do
  local f = setup({ plan = plan("s") })
  f.world.set(0, 0, -1, nil) -- no factory beside it
  local ok, res = run(f, "1")
  check(not ok and tostring(res):find("birth spot", 1, true), "explains (" .. tostring(res) .. ")")
end

print("Flies over a wall in the way")
do
  local extra = {}
  for y = 20, 24 do for z = 100, 110 do extra["107," .. y .. "," .. z] = { name = "minecraft:oak_log" } end end
  local f = setup({ plan = plan("s"), extra = extra })
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(f.w(107, 20, 105) == "minecraft:oak_log", "didn't dig the wall")
end

print("Steps aside for a turtle coming the other way")
do
  -- The other turtle goes onto the birth spot as soon as it's free.
  local f
  f = setup({ plan = plan("s"), onSleep = function(ff)
    if ff.world.get(0, 0, 1) and not (ff.t.x == 0 and ff.t.y == 0 and ff.t.z == 0) then
      ff.world.set(0, 0, 1, nil)
      ff.world.set(0, 0, 0, { name = "computercraft:turtle_normal" })
    end
  end })
  f.world.set(0, 0, 1, { name = "computercraft:turtle_normal" }) -- waiting to get onto the birth spot
  f.world.set(1, 0, 1, { name = "computercraft:cable" })          -- the factory's network
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(f.w(110, 20, 109) == "computercraft:turtle_normal", "let it onto the birth spot")
  check(f.w(111, 20, 108) == "computercraft:cable", "and the cable beside it")
end

print("Shows itself high over the shaft, then carries on")
do
  local route = string.rep("s", 8) .. string.rep("n", 3)
  local f = setup({ plan = plan(route) })
  f.t.crashAt = 158 -- partway through the route
  local ok, res = run(f, "1")
  check(res == "SIMULATED_REBOOT", "stopped partway (" .. tostring(res) .. ")")
  local highest = -math.huge
  f.computer.sleep = function(s)
    if s >= 60 then highest = math.max(highest, f.t.y + f.plan.factory.y) end
  end
  ok, res, log = run(f, "show", "90")
  check(ok, "shows and finishes (" .. tostring(res) .. ")\n" .. log)
  check(highest == 100, "hovered at y 100 (" .. highest .. ")")
  local x, y, z = f.site()
  check(log:find("hovering at 103,100,100", 1, true) ~= nil, "right over the shaft")
  check(allDug(f, routeCells(route, START)) == 0, "then dug the rest of its route")
end

print("Takes over a zone partway along its route")
do
  local route = string.rep("s", 8) .. "e" .. string.rep("n", 4)
  local f = setup({ plan = plan(route) })
  local ok, res, log = run(f, "1", "10")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(log:find("taking over from step 10 of 13", 1, true) ~= nil, "says where it starts")
  check(f.at(4, 8, 4) == nil and f.at(4, 8, 7) == nil, "dug the rest of the route")
end

print("Takes fuel to a stranded turtle, then carries on")
do
  local route = string.rep("s", 8) .. string.rep("n", 3)
  -- A turtle out of fuel beside the route (site 4,8,4).
  local f = setup({ plan = plan(route), extra = { ["104,8,104"] = { name = "computercraft:turtle_normal" } } })
  local box = {}
  f.world.containers["-6,-12,5"] = box
  f.t.crashAt = 150
  local ok, res = run(f, "1")
  check(res == "SIMULATED_REBOOT", "stopped partway (" .. tostring(res) .. ")")
  ok, res, log = run(f, "give", "104", "8", "104", "5")
  check(ok, "gives and finishes (" .. tostring(res) .. ")\n" .. log)
  local n = 0
  for _, it in ipairs(box) do if it.name == "minecraft:coal" then n = n + it.count end end
  check(n == 5, "five coal in the stranded turtle (" .. n .. ")")
  check(log:find("Gave 5 fuel", 1, true) ~= nil, "says so")
end

print("Never digs Stella Arcanum (it explodes): goes round it and says where it is")
do
  local route = "sssss" .. "e" .. "nnnn"
  local f = setup({ plan = plan(route), extra = { ["103,8,103"] = { name = "forbidden_arcanus:stella_arcanum" } } })
  local blew = false
  for _, side in ipairs({ "", "Up", "Down" }) do
    local dig, inspect = f.t.api["dig" .. side], f.t.api["inspect" .. side]
    f.t.api["dig" .. side] = function()
      local ok, b = inspect()
      if ok and b.name:find("stella", 1, true) then blew = true end
      return dig()
    end
  end
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  check(not blew, "never dug it")
  check(f.at(3, 8, 3) == "forbidden_arcanus:stella_arcanum", "left it standing")
  check(f.at(3, 8, 4) == nil and f.at(3, 8, 5) == nil and f.at(4, 8, 1) == nil, "dug the rest of its route")
  check(log:find("left standing at 103 8 103", 1, true) ~= nil, "said where it is")
end

print("Dries a flooded zone: fills the water with stone, bottom up, then digs it out again")
do
  local route = "sDsDsD"
  local f = setup({ plan = plan(route) })
  -- The zone dug already, its lower row flooded.
  for z = 101, 103 do
    local x, y, zz = f.N(103, 8, z)
    f.world.set(x, y, zz)
    x, y, zz = f.N(103, 7, z)
    f.world.set(x, y, zz, { name = "minecraft:water", state = { level = 0 } })
  end
  f.newTurtle({ { "minecraft:coal", 32 }, { "minecraft:cobblestone", 16 } })
  f.t.x, f.t.y, f.t.z = f.N(103, 8, 101)
  f.computer.files["/.excavate"] = '{ phase = "done", zone = 2, pos = { x = ' .. f.t.x .. ', y = ' .. f.t.y .. ', z = ' .. f.t.z .. ' }, dir = 0 }'
  f.computer.files["/blueprints/wet.lua"] = 'return { [1] = { "3,7,1", "3,7,2", "3,7,3" } }'
  local ok, res, log = run(f, "fill", "1")
  check(ok or res == "SIMULATED_REBOOT", "fills, then reboots to re-dig (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(f.at(3, 7, 1) == "minecraft:cobblestone" and f.at(3, 7, 3) == "minecraft:cobblestone", "the water filled with stone")
  -- Its reboot: the same autorun again, now re-digging the zone.
  ok, res, log = run(f, "fill", "1")
  check(ok, "re-digs (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(f.at(3, 7, 1) == nil and f.at(3, 7, 2) == nil and f.at(3, 7, 3) == nil, "dug out again, dry")
end

print("Restarted up on the fuel station, it goes down the shaft before anything else")
do
  local route = "ssss"
  local f = setup({ plan = plan(route) })
  -- Already on its way: a helper's stretch, but standing on the birth spot.
  f.computer.files["/.excavate"] = '{ phase = "help", zone = 1, from = 3, to = 4, assigned = "1:3:4", pos = { x = 0, y = 0, z = 0 }, dir = 0 }'
  local ok, res, log = run(f, "help", "1", "3", "4")
  check(ok, "finishes (" .. tostring(res) .. ")")
  check(f.at(3, 8, 3) == nil and f.at(3, 8, 4) == nil, "dug its stretch")
end

print("Water never stops it: flowing water is gone through, a source removed")
do
  local route = "ssDss"
  -- The cell below the second step (site 3,7,2) refills with flowing water
  -- whenever it's emptied; a water source sits in the way at site 3,8,4.
  local f = setup({ plan = plan(route), extra = { ["103,8,104"] = { name = "minecraft:water", state = { level = 0 } } } })
  local lx, ly, lz = f.N(103, 7, 102)
  local get = f.world.get
  f.world.get = function(x, y, z)
    local b = get(x, y, z)
    if not b and x == lx and y == ly and z == lz then return { name = "minecraft:water", state = { level = 1 } } end
    return b
  end
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  check(f.at(3, 7, 2) == "minecraft:water", "no stone left where the water flows (" .. tostring(f.at(3, 7, 2)) .. ")")
  check(f.at(3, 8, 4) == nil, "the source in its way removed (" .. tostring(f.at(3, 8, 4)) .. ")")
  check(f.at(3, 8, 3) == nil, "and the route dug to its end")
end

print("Shares a zone: one turtle stops at its stretch's end, a helper digs the rest")
do
  local route = string.rep("s", 8) .. "e" .. string.rep("n", 4)
  -- The zone's own turtle digs steps 1-6 only.
  local f = setup({ plan = plan(route) })
  local ok, res, log = run(f, "1", "1", "6")
  check(ok, "the first part finishes (" .. tostring(res) .. ")")
  check(f.at(3, 8, 6) == nil and f.at(3, 8, 7) == "minecraft:stone", "stopped after step 6 (3,8,7 left)")
  -- A turtle done with its own zone, already in the works, takes steps 7-13.
  f.newTurtle()
  f.t.x, f.t.y, f.t.z = f.N(103, 8, 101)
  f.computer.files["/.excavate"] = '{ phase = "done", zone = 2, pos = { x = ' .. f.t.x .. ', y = ' .. f.t.y .. ', z = ' .. f.t.z .. ' }, dir = 0 }'
  ok, res, log = run(f, "help", "1", "7", "13")
  check(ok, "the helper finishes (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(log:find("helping with steps 7 to 13", 1, true) ~= nil, "says what it's helping with")
  check(f.at(3, 8, 7) == nil and f.at(4, 8, 4) == nil, "dug the rest of the zone")
end

print("Scouts the works with a geo scanner: what's left standing, and the water")
do
  local route = "ssssww"
  -- Water in the rock beside the works (site 2,8,2), and the route's cells
  -- west of its end still standing (the scout stops at 3,8,4).
  local f = setup({ plan = plan(route), extra = { ["102,8,102"] = { name = "minecraft:water", state = { level = 0 } } },
    inventory = { { "minecraft:coal", 64 }, { "advancedperipherals:geo_scanner", 1 } } })
  local F = f.plan.factory
  f.computer.peripheral = {
    call = function(side, method, r)
      local e = f.t[side]
      if method ~= "scanBlocks" or e ~= "advancedperipherals:geo_scanner" then return nil, "no scanner on " .. side end
      local out = {}
      for dx = -r, r do for dy = -r, r do for dz = -r, r do
        local b = f.world.get(f.t.x + dx, f.t.y + dy, f.t.z + dz)
        -- nav +z is north, world -z: the scanner reports world axes.
        if b then out[#out + 1] = { name = b.name, x = dx, y = dy, z = -dz } end
      end end end
      return out
    end,
  }
  local ok, res, log = run(f, "scout")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  local txt = f.computer.files["/scout.txt"] or ""
  check(txt:find("2 8 2 minecraft:water out", 1, true) ~= nil, "noted the water outside the works")
  check(txt:find("2 8 4 minecraft:stone in", 1, true) ~= nil and txt:find("1 8 4 minecraft:stone in", 1, true) ~= nil, "noted the route's cells still standing")
  check(f.t.left == "advancedperipherals:chunk_controller", "chunk controller back on (" .. tostring(f.t.left) .. ")")
end

print("Lights only the zones it's told")
do
  -- Zone 1 runs south of the shaft, zone 2 west; the light route visits both.
  local lightPlan = [[return { cells = 0, liftDepth = 71, lift = { x = 100, y = 0, z = 100 }, shaftTop = 77,
    factory = { x = 110, y = 20, z = 110 }, start = { x = 3, y = 8, z = 0 },
    zones = { { route = "sDsD" }, { route = "wDwD" } }, light = { route = "sTsTnnwTwT" } }]]
  local f = setup({ plan = lightPlan, inventory = { { "minecraft:coal", 64 }, { "minecraft:torch", 16 } } })
  -- Both zones dug: the torch spots are their lower cells, rock below.
  for _, c in ipairs({ { 103, 8, 101 }, { 103, 7, 101 }, { 103, 8, 102 }, { 103, 7, 102 },
    { 102, 8, 100 }, { 102, 7, 100 }, { 101, 8, 100 }, { 101, 7, 100 } }) do
    f.world.set(f.N(c[1], c[2], c[3]))
  end
  local ok, res, log = run(f, "light", "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(f.at(3, 7, 1) == "minecraft:torch" and f.at(3, 7, 2) == "minecraft:torch", "torches in zone 1 (" .. tostring(f.at(3, 7, 1)) .. ", " .. tostring(f.at(3, 7, 2)) .. ")\n" .. log:sub(-300))
  check(f.at(2, 7, 0) ~= "minecraft:torch" and f.at(1, 7, 0) ~= "minecraft:torch", "none in zone 2, still being dug")
end

print("No torch where water flows; a water source there is removed first")
do
  local lightPlan = [[return { cells = 0, liftDepth = 71, lift = { x = 100, y = 0, z = 100 }, shaftTop = 77,
    factory = { x = 110, y = 20, z = 110 }, start = { x = 3, y = 8, z = 0 },
    zones = { { route = "sDsD" } }, light = { route = "sTsT" } }]]
  local f = setup({ plan = lightPlan, inventory = { { "minecraft:coal", 64 }, { "minecraft:torch", 16 }, { "minecraft:cobblestone", 8 } } })
  for _, c in ipairs({ { 103, 8, 101 }, { 103, 8, 102 } }) do f.world.set(f.N(c[1], c[2], c[3])) end
  -- A water source on the first spot; flowing water that keeps coming back on the second.
  f.world.set(f.N(103, 7, 101)) f.world.set(f.N(103, 7, 102))
  local sx, sy, sz = f.N(103, 7, 101)
  f.world.set(sx, sy, sz, { name = "minecraft:water", state = { level = 0 } })
  local wx, wy, wz = f.N(103, 7, 102)
  local get = f.world.get
  f.world.get = function(x, y, z)
    local b = get(x, y, z)
    if not b and x == wx and y == wy and z == wz then return { name = "minecraft:water", state = { level = 2 } } end
    return b
  end
  local ok, res, log = run(f, "light")
  check(ok, "finishes (" .. tostring(res) .. ")")
  check(f.at(3, 7, 1) == "minecraft:torch", "the source removed and a torch set (" .. tostring(f.at(3, 7, 1)) .. ")")
  check(f.at(3, 7, 2) ~= "minecraft:torch", "no torch in flowing water")
  check((f.computer.files["/wet-torches.txt"] or ""):find("3,7,2", 1, true) ~= nil, "the wet spot noted")
end

print("Drains a zone from the scout's map: walls sealed, sources removed, leftovers dug")
do
  local route = "ssDss"
  local f = setup({ plan = plan(route), extra = {
    ["102,8,102"] = { name = "minecraft:water", state = { level = 0 } }, -- in the wall
    ["103,7,102"] = { name = "minecraft:water", state = { level = 0 } }, -- a source in the works
  } })
  -- The zone dug already, but for an old plug left at 3,8,3.
  for _, c in ipairs({ { 103, 8, 101 }, { 103, 8, 102 }, { 103, 8, 104 } }) do f.world.set(f.N(c[1], c[2], c[3])) end
  local px, py, pz = f.N(103, 8, 103)
  f.world.set(px, py, pz, { name = "minecraft:cobblestone" })
  -- A turtle done with its own zone, in the works, with some stone for plugs.
  f.newTurtle({ { "minecraft:coal", 32 }, { "minecraft:cobblestone", 16 } })
  f.t.x, f.t.y, f.t.z = f.N(103, 8, 101)
  f.computer.files["/.excavate"] = '{ phase = "done", zone = 2, pos = { x = ' .. f.t.x .. ', y = ' .. f.t.y .. ', z = ' .. f.t.z .. ' }, dir = 0 }'
  f.computer.files["/blueprints/wet.lua"] = 'return { [1] = { "3,8,2" } }'
  local ok, res, log = run(f, "drain", "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(f.at(2, 8, 2) == "minecraft:cobblestone", "the water in the wall sealed (" .. tostring(f.at(2, 8, 2)) .. ")")
  check(f.at(3, 7, 2) == nil, "the source in the works removed (" .. tostring(f.at(3, 7, 2)) .. ")")
  check(f.at(3, 8, 3) == nil, "the old plug dug out (" .. tostring(f.at(3, 8, 3)) .. ")")
end

print("The porter sets up the chest station and fills it from the factory")
do
  -- A small room north of the shaft's foot; two chests against its back.
  local route = "nUDnUD"
  local f = setup({ plan = plan(route) })
  for _, c in ipairs({ { 103, 8, 99 }, { 103, 9, 99 }, { 103, 7, 99 }, { 103, 8, 98 }, { 103, 9, 98 }, { 103, 7, 98 } }) do
    local x, y, z = f.N(c[1], c[2], c[3])
    f.world.set(x, y, z)
  end
  f.newTurtle({ { "minecraft:coal", 32 } })
  f.t.x, f.t.y, f.t.z = f.N(103, 8, 100)
  f.computer.files["/.excavate"] = '{ phase = "done", zone = 1, pos = { x = ' .. f.t.x .. ', y = ' .. f.t.y .. ', z = ' .. f.t.z .. ' }, dir = 0 }'
  f.computer.files["/blueprints/station.lua"] = [[return { item = "factory_blocks:factory", chests = {
    { x = 3, y = 8, z = -2, n = 100 }, { x = 3, y = 9, z = -2, n = 50 } } }]]
  -- The factory: at the station, chests the first time, then the blocks.
  local loads = 0
  local function give(name, n)
    for slot = 1, 16 do
      if not f.t.inv[slot] then f.t.inv[slot] = { name = name, count = n } return end
    end
  end
  local sleep = f.computer.sleep
  f.computer.sleep = function(s)
    sleep(s)
    if f.t.x == 0 and f.t.y == 0 and f.t.z == 0 then
      local have = 0
      for slot = 1, 16 do local it = f.t.inv[slot] if it and (it.name == "minecraft:chest" or it.name == "factory_blocks:factory") then have = have + 1 end end
      if have == 0 then
        loads = loads + 1
        if loads == 1 then give("minecraft:chest", 2) elseif loads == 2 then give("factory_blocks:factory", 64) give("factory_blocks:factory", 64) give("factory_blocks:factory", 22) end
      end
    end
  end
  local ok, res, log = run(f, "porter")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  local function inChest(x, y, z)
    local cx, cy, cz = f.N(x, y, z)
    local n = 0
    for _, it in ipairs(f.world.containers[cx .. "," .. cy .. "," .. cz] or {}) do n = n + it.count end
    return f.w(x, y, z), n
  end
  local b1, n1 = inChest(103, 8, 98)
  local b2, n2 = inChest(103, 9, 98)
  check(b1 == "minecraft:chest" and b2 == "minecraft:chest", "set up both chests")
  check(n1 == 100 and n2 == 50, "filled each to its count (" .. n1 .. ", " .. n2 .. ")")
  check(log:find("The chest station is stocked", 1, true) ~= nil, "says it's done")
end

print("Gives way in the shaft to a turtle coming down, from a pocket below y 60")
do
  local route = string.rep("s", 8) .. string.rep("n", 3)
  local f = setup({ plan = plan(route) })
  f.t.crashAt = 158 -- partway through the route
  run(f, "1")
  -- Another turtle comes down the shaft (world x 103, z 100) from y 80 as soon
  -- as ours is on its way up, a block a second, waiting when something's below.
  local other, passed, pocketed = nil, false, false
  local sx, sz = 103, 100
  local function cell(y) return f.N(sx, y, sz) end
  local function tw() return 110 + f.t.x, 20 + f.t.y, 109 - f.t.z end
  local function tick()
    local x, y, z = tw()
    if not other and not passed and x == sx and z == sz and y > 9 and y < 30 then
      other = 70
      local a, b, c = cell(other) f.world.set(a, b, c, { name = "computercraft:turtle_normal" })
    end
    if other then
      if x ~= sx or z ~= sz then pocketed = true end
      local below = other - 1
      local ax, ay, az = cell(below)
      local free = not f.world.get(ax, ay, az) and not (x == sx and y == below and z == sz)
      if free and other > 9 then
        local a, b, c = cell(other) f.world.set(a, b, c, nil)
        other = below
        a, b, c = cell(other) f.world.set(a, b, c, { name = "computercraft:turtle_normal" })
      elseif other <= 9 then
        local a, b, c = cell(other) f.world.set(a, b, c, nil)
        other, passed = nil, true
      end
    end
  end
  -- It moves a block whenever ours moves or waits.
  f.computer.sleep = function() tick() end
  for _, name in ipairs({ "up", "down", "forward", "back" }) do
    local mv = f.t.api[name]
    f.t.api[name] = function() local r = mv() tick() return r end
  end
  local ok, res, log = run(f, "show", "5")
  check(ok, "gets up and back (" .. tostring(res) .. ")\n" .. log:sub(-400))
  check(log:find("Giving way in the shaft", 1, true) ~= nil, "gave way")
  check(pocketed and passed, "waited in a pocket while the other went by (" .. tostring(pocketed) .. ", " .. tostring(passed) .. ")")
  check(log:find("hovering at 103,100,100", 1, true) ~= nil, "then went on up")
end

print("Needs its zone")
do
  local f = setup({ plan = plan("s") })
  local ok, res = run(f)
  check(not ok and tostring(res):find("Usage", 1, true), "asks for it (" .. tostring(res) .. ")")
end

print("Short of fuel: fuels up at the station first")
do
  local route = string.rep("s", 6) .. string.rep("n", 6) .. string.rep("s", 6)
  local f = setup({
    plan = plan(route),
    inventory = { { "minecraft:coal", 4 } }, -- 320 fuel: enough to get there, not to be safe
    onSleep = function(ff, s)
      if s == 2 and ff.t.x == 0 and ff.t.y == 0 and ff.t.z == 0 then ff.t.addItem("minecraft:coal", 8) end
    end,
  })
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Waiting at the fuel station", 1, true) ~= nil, "waited at the fuel station before setting out")
  check(allDug(f, routeCells(route, START)) == 0, "then digs its route")

print("Runs low on the way: flies back to the station and carries on")
do
  local route = string.rep("s", 6) .. string.rep("n", 6)
  for _ = 1, 40 do route = route .. string.rep("s", 6) .. string.rep("n", 6) end
  local visits = 0
  local f = setup({
    plan = plan(route),
    inventory = { { "minecraft:coal", 9 } }, -- enough to set out, not to finish
    onSleep = function(ff, s)
      if s == 2 and ff.t.x == 0 and ff.t.y == 0 and ff.t.z == 0 and ff.sleeps > 1 then
        visits = visits + 1
        ff.t.addItem("minecraft:coal", 8)
      end
    end,
  })
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-800))
  check(visits > 0 and log:find("Waiting at the fuel station", 1, true) ~= nil, "came back for fuel (" .. visits .. " waits)")
  check(allDug(f, routeCells(route, START)) == 0, "every route cell dug")
end
end

print("Survives reboots on the way")
do
  local route = string.rep("s", 10) .. "E" .. string.rep("n", 3) .. "U"
  local f = setup({ plan = plan(route) })
  for _, at in ipairs({ 9, 40, 90, 105 }) do
    f.t.crashAt = at
    local ok, res = run(f, "1")
    check(res == "SIMULATED_REBOOT", "crashed on purpose at move " .. at .. " (" .. tostring(res) .. ")")
  end
  local ok, res, log = run(f) -- the zone is remembered
  check(ok, "finishes after the reboots (" .. tostring(res) .. ")\n" .. log)
  check(allDug(f, routeCells(route, START)) == 0, "every route cell dug")
  check(f.at(3, 8, 11) == "minecraft:stone" and f.at(2, 8, 3) == "minecraft:stone", "nothing extra dug")
end

if arg[1] == "full" then
  print("The whole crew on the real routes, one after another")
  local f = setup({})
  local h = f.plan
  local want = {}
  for i, z in ipairs(h.zones) do
    if i > 1 then f.newTurtle() end
    local ok, res, log = run(f, tostring(i))
    check(ok, ("zone %d finishes (%s)\n%s"):format(i, tostring(res), ok and "" or log:sub(-600)))
    routeCells(z.route, h.start, want)
    print(("    zone %d: %d moves, fuel left %d"):format(i, f.t.moves, f.t.fuel))
  end
  local n = 0
  for _ in pairs(want) do n = n + 1 end
  check(allDug(f, want) == 0, ("all %d cells of the routes dug"):format(n))
  check(n >= h.cells, ("the routes cover the works (%d of %d)"):format(n, h.cells))
  local extra = 0
  for k, b in pairs(f.world.blocks) do
    if b == false then
      local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
      local sx = h.factory.x + tonumber(x) - h.lift.x
      local sy = h.factory.y + tonumber(y) - h.lift.y
      local sz = h.factory.z - 1 - tonumber(z) - h.lift.z
      local shaft = sx == h.start.x and sz == h.start.z and sy >= h.start.y
      if not shaft and sy < h.factory.y and not want[sx .. "," .. sy .. "," .. sz] then extra = extra + 1 end
    end
  end
  check(extra == 0, ("nothing dug outside the routes (%d extra)"):format(extra))
  check(f.at(-24, -14, -24) == nil and f.at(-25, -14, -24) == "minecraft:stone", "hall corner dug, rock beyond kept")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll excavate tests passed")
