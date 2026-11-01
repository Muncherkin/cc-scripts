-- Offline tests for programs/treefarm.lua. Run with: npm test
--
-- The simulator's coordinates are the program's nav frame: the turtle starts
-- on the birth spot at (0,0,0) facing north (+z). World (x, y, z) relative to
-- the factory, x east and z south, is nav (x, y, -1 - z).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local PROGRAM = "programs/treefarm.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local LOG = "regions_unexplored:pine_log"
local LEAVES = "regions_unexplored:pine_leaves"
local SAPLING = "regions_unexplored:pine_sapling"

local function W(x, y, z) return x, y, -1 - z end -- world -> nav

-- Snow over dirt, the factory with its chests, the cobble turtle and the
-- generator's lid, all where they are in-game.
-- step: the ground from x=4 eastwards is one block higher, like in-game.
-- carve(world x, y, z): true where there's air below ground (a shaft, a hall).
local function newWorld(step, carve)
  local world = sim.newWorld(function(x, y, z)
    if carve and carve(x, y, -1 - z) then return nil end
    local top = (step and x >= 4) and 0 or -1
    if y == top then return { name = "minecraft:snow_block" } end
    if y < top then return { name = "minecraft:dirt" } end
  end)
  local function set(x, y, z, name) world.set(W(x, y, z)) world.set(select(1, W(x, y, z)), y, -1 - z, { name = name }) end
  set(0, 0, 0, "computercraft:turtle_normal")              -- factory
  set(0, -1, 0, "minecraft:chest")                         -- output chest
  set(0, 1, 0, "minecraft:chest")                          -- input chest
  world.containers[("%d,%d,%d"):format(W(0, 1, 0))] = {}
  set(0, 2, 0, "computercraft:turtle_normal")              -- cobble turtle
  set(0, 1, -1, "minecraft:cobblestone")                   -- generator floor above the birth spot
  set(1, 1, 0, "minecraft:cobblestone")                    -- generator wall east of the input chest
  for x = -2, 0 do
    for z = -2, 0 do set(x, 3, z, "minecraft:cobblestone") end -- fire lid
  end
  for x = -2, 3 do set(x, 2, -2, "minecraft:cobblestone") end   -- back wall
  return world
end

-- Grows every sapling into a 6-log pine with a ring of leaves near the top
-- (never into the turtle's own block, like real trees).
local function grow(world, t)
  for key, b in pairs(world.blocks) do
    if b and b.name == SAPLING then
      local x, y, z = key:match("(-?%d+),(-?%d+),(-?%d+)")
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      for i = 0, 5 do world.set(x, y + i, z, { name = LOG }) end
      for i = 3, 6 do
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local lx, ly, lz = x + d[1], y + i, z + d[2]
          if not world.get(lx, ly, lz) and not (t.x == lx and t.y == ly and t.z == lz) then
            world.set(lx, ly, lz, { name = LEAVES })
          end
        end
      end
    end
  end
end

local function setup(opts)
  opts = opts or {}
  local world = newWorld(opts.step, opts.carve)
  local t = sim.newTurtle(world, {
    fuel = opts.fuel or 1000,
    right = "minecraft:diamond_pickaxe",
    inventory = (opts.charcoal or 8) > 0 and { { SAPLING, 4 }, { "minecraft:charcoal", opts.charcoal or 8 } } or { { SAPLING, 4 } },
  })
  local computer = sim.newComputer()
  if opts.home then computer.modules = { ["lib.home"] = opts.home } end
  local f = { world = world, t = t, computer = computer, rounds = 0, stationVisits = 0 }
  computer.sleep = function(seconds)
    if seconds == 120 then
      f.rounds = f.rounds + 1
      if f.rounds >= (opts.rounds or 2) then error("STOP_TEST", 0) end
      grow(world, t)
    elseif seconds == 2 and t.x == (opts.station or {})[1] and t.y == opts.station[2] and t.z == opts.station[3] then
      f.stationVisits = f.stationVisits + 1
      t.addItem("minecraft:charcoal", 8)
    elseif seconds == 2 and t.x == 0 and t.y == 0 and t.z == 0 then
      -- The factory's fuel station hands over charcoal.
      f.stationVisits = f.stationVisits + 1
      -- With stationDown, the factory hands nothing over for that many visits.
      if f.stationVisits > (opts.stationDown or 0) then t.addItem("minecraft:charcoal", 8) end
    end
  end
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

local function name(f, x, y, z)
  local b = f.world.get(W(x, y, z))
  return b and b.name
end

local function inputChest(f, item)
  local n = 0
  for _, it in ipairs(f.world.containers[("%d,%d,%d"):format(W(0, 1, 0))]) do
    if it.name == item then n = n + it.count end
  end
  return n
end

-- The column of a spot: the sapling sits in the dug-out snow layer at y=-1.
local function spotHas(f, x, z, what)
  for y = -1, 1 do if name(f, x, y, z) == what then return true end end
  return false
end

local SPOTS = { { 4, 2 }, { 7, 2 }, { 4, 5 }, { 7, 5 } }

print("Plants the spots, chops grown pines, replants and delivers")
local f = setup({ rounds = 2 })
local ok, res, log = run(f)
check(res == "STOP_TEST", "runs two rounds (" .. tostring(res) .. ")\n" .. log)
for _, s in ipairs(SPOTS) do
  check(spotHas(f, s[1], s[2], SAPLING), ("spot %d,%d replanted"):format(s[1], s[2]))
  local leftover = false
  for y = 0, 8 do if name(f, s[1], y, s[2]) == LOG then leftover = true end end
  check(not leftover, ("spot %d,%d fully chopped"):format(s[1], s[2]))
end
check(inputChest(f, LOG) == 24, "all 24 logs delivered to the input chest (" .. inputChest(f, LOG) .. ")")
check(log:find("felled, planted", 1, true) ~= nil, "reports felling")

print("Steps up onto ground that is a block higher")
local stepped = setup({ rounds = 2, step = true })
ok, res, log = run(stepped)
check(res == "STOP_TEST" and not log:find("blocked", 1, true), "no spot blocked (" .. tostring(res) .. ") " .. log)
check(inputChest(stepped, LOG) == 24, "all 24 logs delivered (" .. inputChest(stepped, LOG) .. ")")
for _, sp in ipairs(SPOTS) do
  local planted = false
  for y = -1, 2 do if name(stepped, sp[1], y, sp[2]) == SAPLING then planted = true end end
  check(planted, ("spot %d,%d replanted on the higher ground"):format(sp[1], sp[2]))
end

print("Leaves the factory and generator alone")
check(name(f, 0, 0, 0) == "computercraft:turtle_normal" and name(f, 0, 2, 0) == "computercraft:turtle_normal",
  "factory and cobble turtle")
check(name(f, 0, 1, -1) == "minecraft:cobblestone" and name(f, 1, 1, 0) == "minecraft:cobblestone", "generator")
local lid = true
for x = -2, 0 do for z = -2, 0 do lid = lid and name(f, x, 3, z) == "minecraft:cobblestone" end end
check(lid, "fire lid intact")

print("Parks above the first spot between rounds")
check(f.t.y == 4 and f.t.x == 3 and f.t.z == -3, ("parked at nav %d,%d,%d"):format(f.t.x, f.t.y, f.t.z))

print("Low on fuel and nothing to burn: visits the fuel station on the birth spot")
f = setup({ rounds = 2, fuel = 450, charcoal = 0 })
ok, res, log = run(f)
check(res == "STOP_TEST", "runs (" .. tostring(res) .. ")")
check(f.stationVisits > 0 and log:find("Refuelled", 1, true) ~= nil, "refuelled at the station")
check(f.t.fuel >= 1500 - 200, "fuel back up (" .. f.t.fuel .. ")")

print("Waits at the fuel station while the factory is down")
f = setup({ rounds = 2, fuel = 420, charcoal = 0, stationDown = 40 })
ok, res, log = run(f)
check(res == "STOP_TEST", "runs (" .. tostring(res) .. ")")
check(f.stationVisits > 40 and log:find("Waiting for charcoal", 1, true) ~= nil, "waits for the factory (" .. f.stationVisits .. " visits)\n" .. log)
check(f.t.fuel >= 400, "never runs dry (" .. f.t.fuel .. ")")

print("Burns the coal it carries instead of running dry")
f = setup({ rounds = 2, fuel = 60, charcoal = 8, stationDown = 1000 })
ok, res, log = run(f)
check(res == "STOP_TEST", "runs two rounds on 60 fuel and 8 charcoal (" .. tostring(res) .. ")\n" .. log)
check(f.stationVisits == 0, "no trip to the fuel station (" .. f.stationVisits .. " visits)")

print("Waits for a turtle in its way instead of stopping")
f = setup({ rounds = 2 })
local blocker = { W(2, 4, -3) } -- on the way out at cruise height
f.world.set(blocker[1], blocker[2], blocker[3], { name = "computercraft:turtle_normal" })
local waits = 0
local sleep0 = f.computer.sleep
f.computer.sleep = function(s)
  if s == 5 then
    waits = waits + 1
    if waits == 3 then f.world.set(blocker[1], blocker[2], blocker[3], nil) end
    return
  end
  return sleep0(s)
end
ok, res, log = run(f)
check(res == "STOP_TEST", "carries on once it's gone (" .. tostring(res) .. ")\n" .. log)
check(waits >= 3, "waited for it (" .. waits .. " waits)")

print("Farms a grove of 12")
local GROVE = {}
for _, z in ipairs({ 2, 5, 8 }) do for _, x in ipairs({ 4, 7, 10, 13 }) do GROVE[#GROVE + 1] = x .. "," .. z end end
f = setup({ rounds = 2 })
f.t.addItem("regions_unexplored:pine_sapling", 12)
ok, res, log = run(f, table.unpack(GROVE))
check(res == "STOP_TEST", "runs two rounds (" .. tostring(res) .. ")")
check(inputChest(f, LOG) == 72, "all 72 logs delivered (" .. inputChest(f, LOG) .. ")")
local all = true
for _, sp in ipairs(GROVE) do
  local x, z = sp:match("(%d+),(%d+)")
  all = all and spotHas(f, tonumber(x), tonumber(z), SAPLING)
end
check(all, "every spot replanted")

print("Prepares rough ground for the grove first")
f = setup({ rounds = 2 })
f.t.addItem("regions_unexplored:pine_sapling", 12)
for y = 0, 6 do f.world.set(9, y, -1 - 3, { name = LOG }) end -- a wild pine
for _, c in ipairs({ { 11, 0, 6 }, { 11, 1, 6 }, { 12, 0, 6 }, { 12, 4, 7 } }) do                       -- rocks and a hill
  f.world.set(c[1], c[2], -1 - c[3], { name = "minecraft:stone" })
end
f.world.set(10, -1, -1 - 8, { name = "minecraft:stone" })                                             -- no soil under a spot
local args = { "prep" }
for _, g in ipairs(GROVE) do args[#args + 1] = g end
ok, res, log = run(f, table.unpack(args))
check(res == "STOP_TEST", "prepares and runs two rounds (" .. tostring(res) .. ")\n" .. log:sub(-600))
check(log:find("The grove is ready", 1, true) ~= nil, "says the grove is ready")
all = true
for _, sp in ipairs(GROVE) do
  local x, z = sp:match("(%d+),(%d+)")
  all = all and spotHas(f, tonumber(x), tonumber(z), SAPLING)
end
check(all, "every spot replanted, the stony one too")
check(name(f, 9, 2, 3) == nil and name(f, 11, 1, 6) == nil and name(f, 12, 4, 7) == nil, "wild tree, rocks and hill gone")
check(inputChest(f, LOG) >= 72, "logs delivered (" .. inputChest(f, LOG) .. ")")
check(name(f, 0, 0, 0) == "computercraft:turtle_normal" and name(f, 1, 1, 0) == "minecraft:cobblestone", "factory and generator untouched")

print("Survives a reboot halfway through")
f = setup({ rounds = 2 })
f.t.crashAt = 40
ok, res = run(f)
check(res == "SIMULATED_REBOOT", "crashed on purpose")
ok, res, log = run(f) -- the agent starts it again after the reboot
check(res == "STOP_TEST", "carries on after the reboot (" .. tostring(res) .. ")\n" .. log)
check(name(f, 0, 0, 0) == "computercraft:turtle_normal", "factory still intact")

print("With the factory in the Engine Hall: logs and fuel down the service shaft")
do
  -- Born at the surface factory, world (0, 0, 0) here. The shaft comes down
  -- north-west of it into a hall below, where the factory now stands.
  local SH = { x = -6, z = -8, top = 0, foot = -40 }
  local FH = { x = 10, y = -58, z = 2 }
  local h = sim.home({ at = "hall", surface = { x = 0, y = 0, z = 0 }, hall = FH, shaft = SH })
  h.hallIn, h.hallOut = -42, -41
  local function carve(x, y, z)
    if x == SH.x and z == SH.z and y >= SH.foot and y < 0 then return true end
    return x >= -10 and x <= 20 and z >= -15 and z <= 10 and y >= -60 and y < SH.foot
  end
  local f = setup({ rounds = 2, fuel = 1000, charcoal = 0, home = h, carve = carve, station = { W(FH.x, FH.y, FH.z - 1) } })
  local function set(x, y, z, b) local a, bb, c = W(x, y, z) f.world.set(a, bb, c, b) end
  set(FH.x, FH.y, FH.z, { name = "computercraft:turtle_normal" })
  set(FH.x, FH.y + 1, FH.z, { name = "minecraft:chest" })
  f.world.containers[("%d,%d,%d"):format(W(FH.x, FH.y + 1, FH.z))] = {}
  -- Low on fuel after the first round: it goes down for some.
  local sleep = f.computer.sleep
  f.computer.sleep = function(s)
    if s == 120 and f.rounds == 0 then f.t.fuel = 300 end
    return sleep(s)
  end
  -- Juniper as it is: born on the surface before the factory moved.
  f.computer.files["/.treefarm"] = "{ origin = { x = 0, y = 0, z = 0 } }"
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "runs two rounds (" .. tostring(res) .. ") " .. log:sub(-300))
  local n = 0
  for _, it in ipairs(f.world.containers[("%d,%d,%d"):format(W(FH.x, FH.y + 1, FH.z))]) do
    if it.name == LOG then n = n + it.count end
  end
  check(n == 24, "the logs went down to the hall's input chest (" .. n .. ")")
  check(inputChest(f, LOG) == 0, "none into the old one")
  check(f.stationVisits > 0, "fuelled up at the hall's birth spot")
  check(f.computer.files["/.treefarm"]:find("origin", 1, true) ~= nil, "keeps where it was born")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll treefarm tests passed")
