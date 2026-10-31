-- Offline tests for programs/cobble.lua. Run with: npm test
package.path = "tests/?.lua;" .. package.path
local sim = require("sim")

local COBBLE = "programs/cobble.lua"
local failures = 0

local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- A turtle facing +z with a chest below. `regen` lists the spots where the
-- generator re-forms cobblestone whenever the turtle waits.
local function setup(opts)
  local world = sim.newWorld(function() return nil end)
  if not opts.noChest then
    world.set(0, -1, 0, { name = "minecraft:chest" })
    world.containers["0,-1,0"] = {}
  end
  for pos, name in pairs(opts.blocks or {}) do
    local x, y, z = pos:match("(-?%d+),(-?%d+),(-?%d+)")
    world.set(tonumber(x), tonumber(y), tonumber(z), { name = name })
  end
  world.capacity = { ["0,-1,0"] = opts.capacity }
  local t = sim.newTurtle(world, { right = "minecraft:diamond_pickaxe" })
  local computer = sim.newComputer()
  computer.peripheral = {
    hasType = function(side, ty) return side == "bottom" and ty == "inventory" and not opts.noChest end,
  }
  local sleeps = 0
  computer.sleep = function()
    sleeps = sleeps + 1
    if sleeps > (opts.cycles or 10) then error("STOP_TEST", 0) end
    for _, pos in ipairs(opts.regen or {}) do
      local x, y, z = pos:match("(-?%d+),(-?%d+),(-?%d+)")
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if not world.get(x, y, z) then world.set(x, y, z, { name = "minecraft:cobblestone" }) end
    end
  end
  return { world = world, t = t, computer = computer }
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(COBBLE, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

local function chest(f)
  local n = 0
  for _, it in ipairs(f.world.containers["0,-1,0"] or {}) do
    if it.name == "minecraft:cobblestone" then n = n + it.count end
  end
  return n
end

print("Mines the generators in front and above (with \"up\")")
local f = setup({ regen = { "0,0,1", "0,1,0" }, cycles = 10 })
local ok, res, log = run(f, "up")
check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")")
check(chest(f) == 20, "two cobblestone per cycle in the chest (" .. chest(f) .. ")")
check(next(f.world.spilled) == nil, "nothing spilled")

print("Without \"up\" it never touches the block above")
f = setup({ regen = { "0,0,1" }, blocks = { ["0,1,0"] = "minecraft:stone" }, cycles = 5 })
ok, res, log = run(f)
check(chest(f) == 5, "one cobblestone per cycle from the front (" .. chest(f) .. ")")
check(f.world.get(0, 1, 0) and f.world.get(0, 1, 0).name == "minecraft:stone", "stone ceiling untouched")

print("Leaves everything else alone")
f = setup({ blocks = { ["0,1,0"] = "minecraft:dirt", ["0,0,1"] = "minecraft:chest" }, regen = {}, cycles = 3 })
ok, res, log = run(f, "up")
check(f.world.get(0, 1, 0) and f.world.get(0, 1, 0).name == "minecraft:dirt", "dirt above is untouched")
check(f.world.get(0, 0, 1) and f.world.get(0, 0, 1).name == "minecraft:chest", "chest in front is untouched")
check(log:find("waiting", 1, true) ~= nil, "says it is waiting for cobblestone")
local _, waits = log:gsub("waiting", "")
check(waits == 1, "says so once")

print("Pauses while the chest is full")
f = setup({ regen = { "0,0,1" }, capacity = 3, cycles = 8 })
ok, res, log = run(f)
check(chest(f) == 3, "chest filled to its 3 stacks")
check(log:find("Chest below is full", 1, true) ~= nil, "reports the full chest")
check(next(f.world.spilled) == nil, "nothing spilled on the ground")
local held = 0
for s = 1, 16 do held = held + (f.t.inv[s] and f.t.inv[s].count or 0) end
check(held <= 1, "stops digging while full (holds " .. held .. ")")

print("No chest below")
f = setup({ noChest = true })
ok, res = run(f)
check(not ok and tostring(res):find("No chest below", 1, true) ~= nil, "clear error")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll cobble tests passed")
