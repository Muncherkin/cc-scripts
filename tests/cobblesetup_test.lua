-- Offline tests for programs/cobblesetup.lua. Run with: npm test
package.path = "tests/?.lua;" .. package.path
local sim = require("sim")

local SETUP = "programs/cobblesetup.lua"
local failures = 0

local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- Flat stone ground below y=0, the factory turtle at (0,0,-1) with the input
-- chest on top, and the newborn on the birth spot (0,0,0).
local function setup(opts)
  opts = opts or {}
  local world = sim.newWorld(function(_, y) if y < 0 then return { name = "minecraft:stone" } end end)
  world.set(0, 0, -1, { name = "computercraft:turtle_normal" })
  world.set(0, 1, -1, { name = "minecraft:chest" })
  world.containers["0,1,-1"] = {}
  for pos, name in pairs(opts.blocks or {}) do
    local x, y, z = pos:match("(-?%d+),(-?%d+),(-?%d+)")
    world.set(tonumber(x), tonumber(y), tonumber(z), { name = name })
  end
  local t = sim.newTurtle(world, {
    fuel = 160,
    right = "minecraft:diamond_pickaxe",
    inventory = opts.inventory or {
      { "minecraft:lava_bucket", 1 }, { "minecraft:water_bucket", 1 }, { "minecraft:cobblestone", 32 },
    },
  })
  t.dir = opts.dir or 0
  local computer = sim.newComputer()
  for path, content in pairs(opts.files or {}) do computer.files[path] = content end
  return { world = world, t = t, computer = computer }
end

local function run(f)
  local log = {}
  local ok, res = sim.run(SETUP, f.t, f.computer, log)
  return ok, res, table.concat(log, "\n")
end

local function name(f, x, y, z)
  local b = f.world.get(x, y, z)
  return b and b.name
end

local SOLIDS = {
  { -1, 1, 0 }, { 0, 1, 0 }, { 1, 0, 0 }, { 2, 1, 0 },     -- floors and the hole's bottom
  { 1, 1, 1 }, { 1, 1, -1 },                               -- hole walls
  { -1, 2, 1 }, { 0, 2, 1 }, { 1, 2, 1 }, { 2, 2, 1 },     -- back wall
  { -1, 2, -1 }, { 1, 2, -1 }, { 2, 2, -1 },               -- front wall, either side of the seat
  { -2, 2, 0 }, { 3, 2, 0 },                               -- ends
}
-- The fire lid over the lava and its neighbours.
for x = -2, 0 do
  for z = -1, 1 do SOLIDS[#SOLIDS + 1] = { x, 3, z } end
end

local function checkBuilt(f, ok, res, log, label)
  check(res == "SIMULATED_REBOOT", label .. ": finishes and reboots (" .. tostring(res) .. " " .. log .. ")")
  local missing = {}
  for _, c in ipairs(SOLIDS) do
    local n = name(f, c[1], c[2], c[3])
    if not n or n == "minecraft:water" or n == "minecraft:lava" then missing[#missing + 1] = table.concat(c, ",") end
  end
  check(#missing == 0, label .. ": every wall and floor is solid (" .. table.concat(missing, " ") .. ")")
  check(name(f, -1, 2, 0) == "minecraft:lava", label .. ": lava in L")
  check(name(f, 2, 2, 0) == "minecraft:water", label .. ": water in W")
  check(name(f, 0, 2, 0) == nil and name(f, 1, 2, 0) == nil and name(f, 1, 1, 0) == nil,
    label .. ": C, w and the hole are open")
  check(f.t.x == 0 and f.t.y == 2 and f.t.z == -1 and f.t.dir == 0, label .. ": sits on the input chest facing C")
  check(name(f, 0, 1, -1) == "minecraft:chest" and name(f, 0, 0, -1) == "computercraft:turtle_normal",
    label .. ": factory and input chest untouched")
  local auto = f.computer.files["/.agent/autorun"] or ""
  check(auto:find('"cobble"', 1, true) ~= nil, label .. ": autorun switched to cobble")
  check(f.computer.files["/.cobblesetup"] == nil, label .. ": no interrupted-marker left")
end

print("Builds the generator from the birth spot")
local f = setup()
local ok, res, log = run(f)
checkBuilt(f, ok, res, log, "facing away")
local buckets = 0
for s = 1, 16 do if f.t.inv[s] and f.t.inv[s].name == "minecraft:bucket" then buckets = buckets + 1 end end
check(buckets == 2, "both buckets emptied")

print("Turns around if it was placed facing the factory")
f = setup({ dir = 2 })
ok, res, log = run(f)
checkBuilt(f, ok, res, log, "facing the factory")

print("Keeps blocks that are already there")
f = setup({ blocks = { ["0,2,1"] = "minecraft:oak_planks", ["1,0,0"] = "minecraft:dirt" } })
ok, res, log = run(f)
checkBuilt(f, ok, res, log, "existing walls")
check(name(f, 0, 2, 1) == "minecraft:oak_planks" and name(f, 1, 0, 0) == "minecraft:dirt", "existing blocks kept")

print("Replaces a snow layer in a wall spot")
sim.BLOCKS["minecraft:snow"] = { drop = "minecraft:snowball", replaceable = true }
f = setup({ blocks = { ["-1,2,1"] = "minecraft:snow" } })
ok, res, log = run(f)
checkBuilt(f, ok, res, log, "snow")
check(name(f, -1, 2, 1) == "minecraft:cobblestone", "snow replaced by cobblestone")

print("Stops instead of digging when its path is blocked")
f = setup({ blocks = { ["1,2,0"] = "minecraft:dirt" } })
ok, res, log = run(f)
check(not ok and tostring(res):find("(1,2,0)", 1, true) and tostring(res):find("dirt", 1, true),
  "names the blocked cell and block (" .. tostring(res) .. ")")
check(name(f, 1, 2, 0) == "minecraft:dirt", "the dirt is still there")
check(name(f, -1, 2, 0) ~= "minecraft:lava" and name(f, 2, 2, 0) ~= "minecraft:water", "no fluids poured")

print("Refuses to run again after an interrupted build")
f = setup({ files = { ["/.cobblesetup"] = "building" } })
ok, res = run(f)
check(not ok and tostring(res):find("interrupted", 1, true) ~= nil, "asks for a hand")
check(f.t.x == 0 and f.t.y == 0 and f.t.z == 0, "doesn't move")

print("Needs its buckets")
f = setup({ inventory = { { "minecraft:cobblestone", 32 } } })
ok, res = run(f)
check(not ok and tostring(res):find("bucket", 1, true) ~= nil, "asks for the buckets")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll cobblesetup tests passed")
