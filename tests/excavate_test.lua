-- Offline tests for programs/excavate.lua. Run with: npm test
--
-- The simulator's coordinates are the program's nav frame: the turtle starts
-- at the top of the service shaft facing west, nav +z. Site coordinates
-- (x east, y up, z south, origin at the lift's bottom) are, with the lift
-- `depth` deep: nav (x, y, z) = (-sz, sy - depth, 1 - sx).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local PROGRAM = "programs/excavate.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function N(depth, sx, sy, sz) return -sz, sy - depth, 1 - sx end

local STONE = { name = "minecraft:stone" }

-- Stone everywhere but the lift shaft, `depth` deep; extra: site cells -> blocks.
local function setup(opts)
  local depth = opts.depth or 71
  local extra = {}
  for k, b in pairs(opts.extra or {}) do
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    local x, y, z = N(depth, tonumber(sx), tonumber(sy), tonumber(sz))
    extra[x .. "," .. y .. "," .. z] = b
  end
  local world = sim.newWorld(function(x, y, z)
    local e = extra[x .. "," .. y .. "," .. z]
    if e then return e end
    if x == 0 and z == 1 and y >= -depth and y <= 2 then return nil end -- the lift's shaft
    if y > 0 then return nil end                                          -- above ground
    return STONE
  end)
  -- The chest behind the turtle (east of it: nav -z).
  world.set(0, 0, -1, { name = "minecraft:chest" })
  world.containers["0,0,-1"] = opts.chest or {}
  local t = sim.newTurtle(world, {
    fuel = opts.fuel or 0,
    right = "minecraft:diamond_pickaxe", left = "advancedperipherals:chunk_controller",
    inventory = opts.inventory or { { "minecraft:coal_block", 64 }, { "minecraft:bucket", 1 } },
  })
  local computer = sim.newComputer()
  computer.files["/blueprints/excavation.lua"] = opts.plan or readfile("programs/blueprints/excavation.lua")
  local f = { world = world, t = t, computer = computer, depth = depth, sleeps = 0 }
  computer.sleep = function(s)
    f.sleeps = f.sleeps + 1
    if opts.onSleep then opts.onSleep(f, s) end
    if f.sleeps > 10000 then error("STUCK_SLEEPING", 0) end
  end
  function f.at(sx, sy, sz)
    local b = world.get(N(depth, sx, sy, sz))
    return b and b.name
  end
  function f.site()
    return 1 - t.z, t.y + depth, -t.x
  end
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

local function plan(route, depth)
  return ("return { cells = 0, moves = 0, liftDepth = %d, start = { x = 1, y = -1, z = 0 }, route = %q }")
    :format(depth or 8, route)
end

-- The route's cells, replayed in site coordinates.
local OPS = { n = { 0, 0, -1 }, e = { 1, 0, 0 }, s = { 0, 0, 1 }, w = { -1, 0, 0 }, u = { 0, 1, 0 }, d = { 0, -1, 0 } }
local function routeCells(route)
  local cells, p = {}, { 1, -1, 0 }
  for i = 1, #route do
    local ch = route:sub(i, i)
    local o = OPS[ch:lower()]
    if o then
      local n = { p[1] + o[1], p[2] + o[2], p[3] + o[3] }
      cells[n[1] .. "," .. n[2] .. "," .. n[3]] = true
      if OPS[ch] then p = n end
    end
  end
  return cells
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
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Down 9 blocks", 1, true) ~= nil, "measures the lift")
  local want = routeCells(route)
  local all = true
  for k in pairs(want) do
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    if f.at(tonumber(sx), tonumber(sy), tonumber(sz)) then all = false print("    still there: " .. k) end
  end
  check(all, "every route cell dug")
  check(f.at(1, -1, 3) == "minecraft:cobblestone", "water beyond the edge plugged with stone (" .. tostring(f.at(1, -1, 3)) .. ")")
  check(f.at(2, -1, 3) == "minecraft:stone" and f.at(0, -1, 2) == "minecraft:stone", "rock beside the route kept")
  check(f.at(0, 0, 0) == nil and f.at(0, 5, 0) == nil, "lift shaft untouched")
  check(f.at(1, 3, 0) == nil and f.at(1, 7, 0) == nil, "service shaft dug beside the lift")
  local x, y, z = f.site()
  check(x == 1 and y == 8 and z == 0, ("back at the top (%d,%d,%d)"):format(x, y, z))
  local chest = f.world.containers["0,0,-1"]
  local iron = 0
  for _, it in ipairs(chest) do if it.name == "minecraft:raw_iron" then iron = iron + it.count end end
  check(iron == 1, "iron delivered to the chest")
  check(f.t.fuel > 1000 and f.t.fuel < 2000, "drank the lava, and only that (fuel " .. f.t.fuel .. ")")
  local stone = 0
  for _, it in ipairs(chest) do if it.name == "minecraft:cobblestone" then stone = stone + it.count end end
  check(stone == 0, "no stone carried up")
end

print("Refuses to start away from the lift")
do
  local f = setup({ depth = 8, plan = plan("s") })
  f.world.set(0, 0, 1, STONE) -- no shaft in front
  local ok, res = run(f)
  check(not ok and tostring(res):find("beside the lift", 1, true), "explains (" .. tostring(res) .. ")")
end

print("Refuses a shaft of the wrong depth")
do
  local f = setup({ depth = 30, plan = plan("s", 71) })
  local ok, res = run(f)
  check(not ok and tostring(res):find("level with its top", 1, true), "explains (" .. tostring(res) .. ")")
end

print("Goes up for fuel and waits until there is some")
do
  local route = string.rep("s", 6) .. string.rep("n", 6) .. string.rep("s", 6)
  local f
  f = setup({
    depth = 8, plan = plan(route),
    inventory = { { "minecraft:coal", 2 } }, -- 160 fuel: not enough to go on
    onSleep = function(ff, s)
      if s == 10 and ff.sleeps == 3 then
        table.insert(ff.world.containers["0,0,-1"], { name = "minecraft:coal_block", count = 8 })
      end
    end,
  })
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Waiting for fuel", 1, true) ~= nil, "waited for fuel at the chest")
  check(f.at(1, -1, 18) == nil or f.at(1, -1, 6) == nil, "carried on afterwards")
end

print("Survives reboots on the way")
do
  local route = string.rep("s", 10) .. "E" .. string.rep("n", 3) .. "U"
  local f = setup({ depth = 8, plan = plan(route) })
  for _, at in ipairs({ 5, 14, 19 }) do
    f.t.crashAt = at
    local ok, res = run(f)
    check(res == "SIMULATED_REBOOT", "crashed on purpose at move " .. at .. " (" .. tostring(res) .. ")")
  end
  local ok, res, log = run(f)
  check(ok, "finishes after the reboots (" .. tostring(res) .. ")\n" .. log)
  local want, all = routeCells(route), true
  for k in pairs(want) do
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    if f.at(tonumber(sx), tonumber(sy), tonumber(sz)) then all = false end
  end
  check(all, "every route cell dug")
  check(f.at(1, -1, 11) == "minecraft:stone" and f.at(0, -1, 3) == "minecraft:stone", "nothing extra dug")
end

if arg[1] == "full" then
  print("The real route: the whole works")
  local f = setup({})
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-600))
  local h = load(readfile("programs/blueprints/excavation.lua"))()
  local want, n, missing = routeCells(h.route), 0, 0
  for k in pairs(want) do
    n = n + 1
    local sx, sy, sz = k:match("(-?%d+),(-?%d+),(-?%d+)")
    if f.at(tonumber(sx), tonumber(sy), tonumber(sz)) then missing = missing + 1 end
  end
  check(missing == 0, ("all %d route cells dug (%d missing)"):format(n, missing))
  local extra = 0
  for k, b in pairs(f.world.blocks) do
    if b == false then
      local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      local sx, sy, sz = 1 - z, y + 71, -x
      local shaft = (sx == 1 and sz == 0) or (sx == 0 and sz == 0) or sy > 71
      if not shaft and not want[sx .. "," .. sy .. "," .. sz] then extra = extra + 1 end
    end
  end
  check(extra == 0, ("nothing dug outside the route (%d extra)"):format(extra))
  check(f.at(0, 0, 0) == nil and f.at(0, -1, 0) == nil, "the lift's foot is open")
  check(f.at(-24, -14, -24) == nil and f.at(-25, -14, -24) == "minecraft:stone", "hall corner dug, rock beyond kept")
  print(("    moves (fuel used): %d"):format(f.t.moves))
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll excavate tests passed")
