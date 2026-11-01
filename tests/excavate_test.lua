-- Offline tests for programs/excavate.lua. Run with: npm test
-- The whole crew on the real routes (slow): node tests/run.js tests/excavate_test.lua full
--
-- The simulator's coordinates are the program's nav frame: each turtle
-- starts at the top of the service shaft facing west, nav +z, with the
-- elevator waiting in front of it. Site coordinates (x east, y up, z south,
-- origin at the lift's bottom) are, with the lift `depth` deep:
-- nav (x, y, z) = (-sz, sy - depth, 1 - sx).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local PROGRAM = "programs/excavate.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function N(depth, sx, sy, sz) return -sz, sy - depth, 1 - sx end

local STONE = { name = "minecraft:stone" }
local ELEVATOR = { name = "computercraft:turtle_normal" }

-- Stone everywhere but the lift shaft, `shaft` deep (default: the lift's
-- depth), with the elevator waiting at its top; extra: site cells -> blocks.
local function setup(opts)
  local depth = opts.depth or 71
  local shaft = opts.shaft or depth
  local extra = {}
  for k, b in pairs(opts.extra or {}) do
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    local x, y, z = N(depth, tonumber(sx), tonumber(sy), tonumber(sz))
    extra[x .. "," .. y .. "," .. z] = b
  end
  local world = sim.newWorld(function(x, y, z)
    local e = extra[x .. "," .. y .. "," .. z]
    if e then return e end
    if x == 0 and z == 1 and y == 0 then return ELEVATOR end
    if x == 0 and z == 1 and y >= -shaft and y <= 2 then return nil end -- the lift's shaft
    if y > 0 then return nil end                                         -- above ground
    return STONE
  end)
  -- The chest behind the turtle (east of it: nav -z).
  world.set(0, 0, -1, { name = "minecraft:chest" })
  world.containers["0,0,-1"] = opts.chest or {}
  local f = { world = world, depth = depth, sleeps = 0 }
  -- A new crew member at the top of the shaft.
  function f.newTurtle(inventory)
    f.t = sim.newTurtle(world, {
      fuel = opts.fuel or 0,
      right = "minecraft:diamond_pickaxe", left = "advancedperipherals:chunk_controller",
      inventory = inventory or opts.inventory or { { "minecraft:coal_block", 16 }, { "minecraft:bucket", 1 } },
    })
    f.computer = sim.newComputer()
    f.computer.files["/blueprints/excavation.lua"] = opts.plan or readfile("programs/blueprints/excavation.lua")
    f.computer.sleep = function(s)
      f.sleeps = f.sleeps + 1
      if opts.onSleep then opts.onSleep(f, s) end
      if f.sleeps > 10000 then error("STUCK_SLEEPING", 0) end
    end
  end
  f.newTurtle()
  function f.at(sx, sy, sz)
    local b = world.get(N(depth, sx, sy, sz))
    return b and b.name
  end
  function f.site()
    return 1 - f.t.z, f.t.y + depth, -f.t.x
  end
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

-- A one-zone plan whose route starts at (1, -1, 0), just below the lift.
local function plan(route, depth)
  return ("return { cells = 0, liftDepth = %d, start = { x = 1, y = -1, z = 0 }, zones = { { route = %q } } }")
    :format(depth or 8, route)
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
local LOW = { x = 1, y = -1, z = 0 }

local function allDug(f, cells)
  local left = 0
  for k in pairs(cells) do
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    if f.at(tonumber(sx), tonumber(sy), tonumber(sz)) then left = left + 1 end
  end
  return left
end

print("Digs a small route, plugging water, drinking lava and keeping ores")
do
  local route = "ssUD2e0U" .. "nnD" .. "4"
  local f = setup({
    depth = 8,
    plan = plan(route),
    fuel = 0,
    extra = {
      ["1,-1,2"] = { name = "minecraft:lava", state = { level = 0 } },   -- a lava source in the way
      ["1,-1,3"] = { name = "minecraft:water", state = { level = 0 } },  -- water beyond the edge
      ["1,0,2"] = { name = "minecraft:iron_ore" },
      ["2,0,2"] = { name = "minecraft:gravel" },                          -- falls when dug from below
      ["2,1,2"] = { name = "minecraft:gravel" },
    },
  })
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Zone 1: at the top of the hall", 1, true) ~= nil, "goes down to the start")
  check(allDug(f, routeCells(route, LOW)) == 0, "every route cell dug")
  check(f.at(1, -1, 3) == "minecraft:cobblestone", "water beyond the edge plugged with stone (" .. tostring(f.at(1, -1, 3)) .. ")")
  check(f.at(2, -1, 3) == "minecraft:stone" and f.at(0, -1, 2) == "minecraft:stone", "rock beside the route kept")
  check(f.at(0, 8, 0) == "computercraft:turtle_normal" and f.at(0, 5, 0) == nil, "lift shaft and elevator untouched")
  check(f.at(1, 3, 0) == nil and f.at(1, 7, 0) == nil, "service shaft dug beside the lift")
  local x, y, z = f.site()
  check(x == 2 and y == -1 and z == 0, ("parked where it finished, out of the shaft (%d,%d,%d)"):format(x, y, z))
  local chest = f.world.containers["0,0,-1"]
  local iron, stone = 0, 0
  for _, it in ipairs(chest) do
    if it.name == "minecraft:raw_iron" then iron = iron + it.count end
    if it.name == "minecraft:cobblestone" then stone = stone + it.count end
  end
  check(iron == 1, "iron delivered to the chest")
  check(stone == 0, "no stone carried up")
  check(f.t.fuel > 1000 and f.t.fuel < 2000, "drank the lava, and only that (fuel " .. f.t.fuel .. ")")
end

print("Refuses to start away from the lift")
do
  local f = setup({ depth = 8, plan = plan("s") })
  f.world.set(0, 0, 1, STONE) -- no elevator in front
  local ok, res = run(f, "1")
  check(not ok and tostring(res):find("top of the lift", 1, true), "explains (" .. tostring(res) .. ")")
end

print("Stops when the lift's shaft isn't beside it all the way down")
do
  local f = setup({ depth = 30, shaft = 12, plan = plan("s", 30) })
  local ok, res = run(f, "1")
  check(not ok and tostring(res):find("right place", 1, true), "explains (" .. tostring(res) .. ")")
end

print("Needs its zone")
do
  local f = setup({ depth = 8, plan = plan("s") })
  local ok, res = run(f)
  check(not ok and tostring(res):find("Usage", 1, true), "asks for it (" .. tostring(res) .. ")")
end

print("Goes up for fuel and waits until there is some")
do
  local route = string.rep("s", 6) .. string.rep("n", 6) .. string.rep("s", 6)
  local f = setup({
    depth = 8, plan = plan(route),
    inventory = { { "minecraft:coal", 2 } }, -- 160 fuel: not enough to go on
    onSleep = function(ff, s)
      if s == 10 and ff.sleeps == 3 then
        table.insert(ff.world.containers["0,0,-1"], { name = "minecraft:coal_block", count = 8 })
      end
    end,
  })
  local ok, res, log = run(f, "1")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Waiting for fuel", 1, true) ~= nil, "waited for fuel at the chest")
  check(allDug(f, routeCells(route, LOW)) == 0, "carried on afterwards")
end

print("Survives reboots on the way")
do
  local route = string.rep("s", 10) .. "E" .. string.rep("n", 3) .. "U"
  local f = setup({ depth = 8, plan = plan(route) })
  for _, at in ipairs({ 5, 14, 19 }) do
    f.t.crashAt = at
    local ok, res = run(f, "1")
    check(res == "SIMULATED_REBOOT", "crashed on purpose at move " .. at .. " (" .. tostring(res) .. ")")
  end
  local ok, res, log = run(f) -- the zone is remembered
  check(ok, "finishes after the reboots (" .. tostring(res) .. ")\n" .. log)
  check(allDug(f, routeCells(route, LOW)) == 0, "every route cell dug")
  check(f.at(1, -1, 11) == "minecraft:stone" and f.at(0, -1, 3) == "minecraft:stone", "nothing extra dug")
end

if arg[1] == "full" then
  print("The whole crew on the real routes, one after another")
  local f = setup({})
  local h = load(readfile("programs/blueprints/excavation.lua"))()
  local want = {}
  for i, z in ipairs(h.zones) do
    if i > 1 then f.newTurtle() end
    local ok, res, log = run(f, tostring(i))
    check(ok, ("zone %d finishes (%s)\n%s"):format(i, tostring(res), ok and "" or log:sub(-600)))
    routeCells(z.route, h.start, want)
    print(("    zone %d: %d moves"):format(i, f.t.moves))
  end
  local n = 0
  for _ in pairs(want) do n = n + 1 end
  check(allDug(f, want) == 0, ("all %d cells of the routes dug"):format(n))
  check(n >= h.cells, ("the routes cover the works (%d of %d)"):format(n, h.cells))
  local extra = 0
  for k, b in pairs(f.world.blocks) do
    if b == false then
      local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      local sx, sy, sz = 1 - z, y + 71, -x
      local shaft = (sx == 1 and sz == 0 and sy >= h.start.y) or (sx == 0 and sz == 0) or sy > 71
      if not shaft and not want[sx .. "," .. sy .. "," .. sz] then extra = extra + 1 end
    end
  end
  check(extra == 0, ("nothing dug outside the routes (%d extra)"):format(extra))
  check(f.at(0, 0, 0) == nil and f.at(0, -1, 0) == nil, "the lift's foot is open")
  check(f.at(-24, -14, -24) == nil and f.at(-25, -14, -24) == "minecraft:stone", "hall corner dug, rock beyond kept")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll excavate tests passed")
