-- Offline tests for programs/miner.lua. Run with: npm test
package.path = "tests/?.lua;" .. package.path
local sim = require("sim")

local MINER = "programs/miner.lua"
local failures = 0

local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function countOres(world, region)
  local n = 0
  for x = region.x1, region.x2 do
    for y = region.y1, region.y2 do
      for z = region.z1, region.z2 do
        local b = world.get(x, y, z)
        if b and sim.BLOCKS[b.name].tags and sim.BLOCKS[b.name].tags["c:ores"] then n = n + 1 end
      end
    end
  end
  return n
end

local function stored(world, t, prefix)
  local n = 0
  for _, items in pairs(world.containers) do
    for _, it in ipairs(items) do if it.name:find(prefix) then n = n + it.count end end
  end
  for s = 1, 16 do
    local it = t.inv[s]
    if it and it.name:find(prefix) then n = n + it.count end
  end
  return n
end

-- Runs miner with the given args, "rebooting" (re-running without args)
-- whenever the simulator crashes it. Returns the final result and the log.
local function runMiner(t, computer, ...)
  local log = {}
  local ok, res = sim.run(MINER, t, computer, log, ...)
  local reboots = 0
  while not ok and res == "SIMULATED_REBOOT" and reboots < 5 do
    reboots = reboots + 1
    log[#log + 1] = "-- reboot --"
    ok, res = sim.run(MINER, t, computer, log)
  end
  return ok, res, log, reboots
end

local function dump(log)
  for _, line in ipairs(log) do print("    | " .. line) end
end

-- A stone world between bedrock layers, with a bedrock wall across the main
-- tunnel at z = 22 so the run ends.
local function baseWorld(extra)
  return sim.newWorld(function(x, y, z)
    if y <= -3 or y >= 4 or z >= 22 then return { name = "minecraft:bedrock" } end
    local b = extra and extra(x, y, z)
    if b then return b end
    return { name = "minecraft:stone" }
  end)
end

local function veins(x, y, z)
  -- an iron vein crossing a branch, partly above and below the tunnel
  if x >= 3 and x <= 5 and y >= -1 and y <= 1 and z == 4 then return { name = "minecraft:iron_ore" } end
  -- a diamond between two branches (only visible from the side)
  if x == -4 and y == 0 and z == 7 then return { name = "minecraft:diamond_ore" } end
  -- coal in the main tunnel floor
  if x == 0 and y == -1 and z == 10 then return { name = "minecraft:coal_ore" } end
  -- a gravel column over a branch
  if x == 2 and y >= 1 and y <= 3 and z == 12 then return { name = "minecraft:gravel" } end
  -- a lava source next to a branch
  if x == -2 and y == 0 and z == 16 then return { name = "minecraft:lava", state = { level = 0 } } end
end

local REGION = { x1 = -6, x2 = 6, y1 = -2, y2 = 3, z1 = 0, z2 = 21 }

---------------------------------------------------------------------------
print("Test 1: full run until the main tunnel hits bedrock")
do
  local world = baseWorld(veins)
  local oresBefore = countOres(world, REGION)
  local t = sim.newTurtle(world, {
    fuel = 700, left = "minecraft:diamond_pickaxe", right = "advancedperipherals:chunk_controller",
    inventory = { { "minecraft:chest", 4 }, { "minecraft:bucket", 1 } },
  })
  local computer = sim.newComputer()
  local ok, res, log = runMiner(t, computer, "new", "6", "3")
  if not ok then dump(log) end
  check(ok, "runs without errors (" .. tostring(res) .. ")")
  check(type(res) == "string" and res:find("blocked") ~= nil, "stops because the main tunnel is blocked")
  check(t.x == 0 and t.y == 0 and t.z == 0 and t.dir == 0, ("ends home facing forward (at %d,%d,%d dir %d)"):format(t.x, t.y, t.z, t.dir))
  check(countOres(world, REGION) == 0, ("mines every ore (%d of %d left)"):format(countOres(world, REGION), oresBefore))
  check(stored(world, t, "raw_iron") == 9, "keeps all 9 raw iron (" .. stored(world, t, "raw_iron") .. ")")
  check(stored(world, t, "diamond") == 1, "keeps the diamond")
  check(not world.spilled["minecraft:raw_iron"] and not world.spilled["minecraft:diamond"], "never drops valuables")
  local junkStored = 0
  for _, items in pairs(world.containers) do
    for _, it in ipairs(items) do if it.name:find("cobble") then junkStored = junkStored + it.count end end
  end
  check(junkStored == 0, "never puts cobblestone in chests")
  check(t.fuel > 1000, "scooped the lava for fuel (fuel " .. t.fuel .. ")")
end

---------------------------------------------------------------------------
print("Test 2: same run with server restarts in the middle of moves")
for _, crashAt in ipairs({ 7, 40, 133, 210 }) do
  local world = baseWorld(veins)
  local t = sim.newTurtle(world, {
    fuel = 700, crashAt = crashAt, left = "minecraft:diamond_pickaxe", right = "advancedperipherals:chunk_controller",
    inventory = { { "minecraft:chest", 4 }, { "minecraft:bucket", 1 } },
  })
  local ok, res, log, reboots = runMiner(t, sim.newComputer(), "new", "6", "3")
  if not ok then dump(log) end
  check(ok and reboots == 1 and t.x == 0 and t.y == 0 and t.z == 0 and countOres(world, REGION) == 0,
    ("restart after move %d: resumes, mines everything, ends home (at %d,%d,%d)"):format(crashAt, t.x, t.y, t.z))
end

---------------------------------------------------------------------------
print("Test 3: runs out of chests in an ore-rich area")
do
  -- every block next to the tunnels is a different mod ore
  local world = baseWorld(function(x, y, z)
    if y ~= 0 then return { name = "mod:ore" .. ((x * 7 + z * 3 + y) % 40 + 1) } end
  end)
  local t = sim.newTurtle(world, {
    fuel = 2000, left = "minecraft:diamond_pickaxe", right = "advancedperipherals:chunk_controller",
    inventory = { { "minecraft:chest", 2 } },
  })
  local ok, res, log = runMiner(t, sim.newComputer(), "new", "6", "3")
  if not ok then dump(log) end
  check(ok and res == "out of deposit chests", "stops with 'out of deposit chests' (" .. tostring(res) .. ")")
  check(t.x == 0 and t.y == 0 and t.z == 0, ("goes home (at %d,%d,%d)"):format(t.x, t.y, t.z))
  local chests = 0
  for _ in pairs(world.containers) do chests = chests + 1 end
  check(chests == 2, "filled both chests (" .. chests .. ")")
  local spilled = 0
  for name, n in pairs(world.spilled) do if name:find("raw") then spilled = spilled + n end end
  -- Only the final trip home (full inventory, no chests left) may spill a little.
  check(spilled <= 3, "spills at most a few ores on the way home (" .. spilled .. " spilled)")
end

---------------------------------------------------------------------------
print("Test 4: goes home when fuel runs low")
do
  local world = baseWorld()
  local t = sim.newTurtle(world, {
    fuel = 400, left = "minecraft:diamond_pickaxe", right = "advancedperipherals:chunk_controller",
    inventory = { { "minecraft:chest", 2 } },
  })
  local ok, res, log = runMiner(t, sim.newComputer(), "new", "6", "3")
  if not ok then dump(log) end
  check(ok and res == "low on fuel", "stops with 'low on fuel' (" .. tostring(res) .. ")")
  check(t.fuel < 400 - 150, "actually mined before turning back (fuel " .. t.fuel .. ")")
  check(t.x == 0 and t.y == 0 and t.z == 0, ("makes it home (at %d,%d,%d, fuel %d)"):format(t.x, t.y, t.z, t.fuel))
end

print(failures == 0 and "\nAll tests passed" or ("\n" .. failures .. " check(s) failed"))
if failures > 0 then os.exit(1) end
