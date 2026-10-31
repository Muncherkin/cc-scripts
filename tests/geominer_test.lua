-- Offline tests for programs/geominer.lua. Run with: npm test
--
-- The simulator turns the other way round from Minecraft (right of +z is +x
-- here, -x there), so the fake geo scanner reports Minecraft axes:
-- Minecraft x = -(sim x), Minecraft z = sim z. That way the miner's compass
-- calibration is tested against real Minecraft geometry.
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local PROGRAM = "programs/geominer.lua"
local SCANNER = "advancedperipherals:geo_scanner"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- Solid stone with bedrock far below, and ores at sim positions.
local ORES = {
  ["3,0,5"] = "minecraft:iron_ore", ["3,1,5"] = "minecraft:iron_ore",
  ["-4,-2,9"] = "minecraft:diamond_ore", ["2,3,-3"] = "minecraft:coal_ore",
  ["-6,0,2"] = "minecraft:redstone_ore", ["5,-1,20"] = "minecraft:deepslate_gold_ore",
  ["1,0,3"] = "minecraft:copper_ore", -- not a target: stays
}

local function setup(opts)
  opts = opts or {}
  local world = sim.newWorld(function(x, y, z)
    local ore = ORES[x .. "," .. y .. "," .. z]
    if ore then return { name = ore } end
    if y < -12 then return { name = "minecraft:bedrock" } end
    return { name = "minecraft:stone" }
  end)
  -- The player dug a little room to place the turtle in.
  world.set(0, 0, 0, nil)
  local t = sim.newTurtle(world, {
    fuel = 100,
    left = "advancedperipherals:chunk_controller",
    right = "minecraft:diamond_pickaxe",
    inventory = opts.inventory or {
      { SCANNER, 1 }, { "minecraft:chest", 1 }, { "minecraft:bucket", 1 }, { "minecraft:charcoal", 16 },
    },
  })
  t.dir = opts.dir or 0
  local computer = sim.newComputer()
  local f = { world = world, t = t, computer = computer, scans = 0, now = 0, refused = 0 }
  -- Time passes when the program sleeps; the scanner has a 2 second cooldown.
  computer.clock = function() return f.now end
  computer.sleep = function(s) f.now = f.now + (s or 0) end
  local lastOk = -math.huge
  computer.peripheral = {
    call = function(side, method, radius)
      assert(method == "scanBlocks", "unexpected method " .. tostring(method))
      if t[side] ~= SCANNER then error("No such method scanBlocks", 0) end
      if f.now - lastOk < 2 then
        f.refused = f.refused + 1
        return nil, "scanBlocks is on cooldown"
      end
      lastOk = f.now
      f.scans = f.scans + 1
      local out = {}
      for x = -radius, radius do
        for y = -radius, radius do
          for z = -radius, radius do
            if x * x + y * y + z * z <= radius * radius then
              local b = world.get(t.x + x, t.y + y, t.z + z)
              if b then out[#out + 1] = { name = b.name, x = -x, y = y, z = z } end -- Minecraft axes
            end
          end
        end
      end
      return out
    end,
  }
  -- Stops after this many moves (never mid-scan, so the pickaxe is on).
  t.crashAt = opts.moves or 400
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

local function chest(f)
  local got = {}
  for _, it in ipairs(f.world.containers["0,1,0"] or {}) do got[it.name] = (got[it.name] or 0) + it.count end
  return got
end

local function has(f, name)
  local n = 0
  for s = 1, 16 do if f.t.inv[s] and f.t.inv[s].name == name then n = n + f.t.inv[s].count end end
  return n + (chest(f)[name] or 0)
end

for _, dir in ipairs({ 0, 1, 2, 3 }) do
  print(("Placed facing direction %d"):format(dir))
  local f = setup({ dir = dir })
  local ok, res, log = run(f)
  check(res == "SIMULATED_REBOOT", "keeps mining (" .. tostring(res) .. ")\n" .. log)
  check(f.world.get(0, 1, 0) and f.world.get(0, 1, 0).name == "minecraft:chest", "linked chest above home")
  check(has(f, "minecraft:raw_iron") == 2, "both iron ores mined (" .. has(f, "minecraft:raw_iron") .. ")")
  -- The sweep goes the way it was placed facing; these two lie ahead of direction 0.
  if dir == 0 then check(has(f, "minecraft:diamond") == 1, "the diamond, one area out") end
  check(log:find("1 coal_ore", 1, true) and has(f, "minecraft:redstone") == 1, "coal and redstone mined")
  if dir == 0 then check(has(f, "minecraft:raw_gold") == 1, "deepslate gold, two areas out") end
  check(f.world.get(1, 0, 3) and f.world.get(1, 0, 3).name == "minecraft:copper_ore", "copper left alone")
  check(has(f, "minecraft:cobblestone") <= 64, "junk dropped as it goes (" .. has(f, "minecraft:cobblestone") .. " left)")
  check(f.t.left == "advancedperipherals:chunk_controller" and f.t.right == "minecraft:diamond_pickaxe",
    "pickaxe back on after scanning")
  check(f.refused == 0, "never scans during the cooldown (" .. f.refused .. " refused)")
end

print("Waits beside the factory to be carried away")
local f = setup()
f.world.set(0, 0, -1, { name = "computercraft:turtle_normal" })
f.computer.sleep = function() error("STOP_TEST", 0) end
local ok, res, log = run(f)
check(res == "STOP_TEST" and log:find("Carry me", 1, true) ~= nil, "says so and waits")
check(f.computer.files["/.geominer"] == nil and f.world.get(0, 1, 0).name ~= "minecraft:chest", "does nothing else")

print("Asks for its kit")
f = setup({ inventory = { { "minecraft:charcoal", 16 } } })
local asked = false
local env_os_pull -- the program waits for turtle_inventory events
f.computer.sleep = function() error("STOP_TEST", 0) end
ok, res, log = run(f)
check(not ok and log:find("geo scanner", 1, true) and log:find("linked chest", 1, true),
  "names the missing scanner and chest (" .. tostring(res) .. ")")

print("Delivers to the linked chest when full")
f = setup({ moves = 300 })
-- Fill the inventory with junk-proof loot so it must go home.
for s = 5, 15 do f.t.inv[s] = { name = "minecraft:raw_iron", count = 64 } end
ok, res, log = run(f)
check((chest(f)["minecraft:raw_iron"] or 0) >= 64 * 11, "raw iron delivered (" .. tostring(chest(f)["minecraft:raw_iron"]) .. ")")
check(log:find("home trips", 1, true) ~= nil, "reports progress")

print("Delivers type by type through an ender drawer")
f = setup({ moves = 300, inventory = {
  { SCANNER, 1 }, { "functionalstorage:ender_drawer", 1 }, { "minecraft:bucket", 1 }, { "minecraft:charcoal", 16 },
} })
for s = 5, 9 do f.t.inv[s] = { name = "minecraft:raw_iron", count = 64 } end
for s = 10, 12 do f.t.inv[s] = { name = "minecraft:diamond", count = 64 } end
for s = 13, 15 do f.t.inv[s] = { name = "minecraft:redstone", count = 64 } end
local delivered = {}
f.computer.sleep = function(seconds)
  f.now = f.now + (seconds or 0)
  if seconds == 10 then
    -- The factory empties the drawer's twin while the miner waits.
    for _, it in ipairs(f.world.containers["0,1,0"] or {}) do
      delivered[it.name] = (delivered[it.name] or 0) + it.count
    end
    f.world.containers["0,1,0"] = {}
  end
end
ok, res, log = run(f)
for _, it in ipairs(f.world.containers["0,1,0"] or {}) do delivered[it.name] = (delivered[it.name] or 0) + it.count end
check(f.world.get(0, 1, 0).name == "functionalstorage:ender_drawer", "drawer placed above home")
check((delivered["minecraft:raw_iron"] or 0) >= 320 and (delivered["minecraft:diamond"] or 0) >= 192
  and (delivered["minecraft:redstone"] or 0) >= 192, "every type delivered, one after another")
check(log:find("waiting for the factory", 1, true) ~= nil, "waited for the drawer to empty")

print("Uses a linked drawer the player placed above it")
f = setup({ moves = 300, inventory = { { SCANNER, 1 }, { "minecraft:bucket", 1 }, { "minecraft:charcoal", 16 } } })
f.world.set(0, 1, 0, { name = "functionalstorage:ender_drawer" })
f.world.containers["0,1,0"] = {}
for s = 5, 9 do f.t.inv[s] = { name = "minecraft:raw_iron", count = 64 } end
f.computer.sleep = function(seconds)
  f.now = f.now + (seconds or 0)
  if seconds == 10 then f.world.containers["0,1,0"] = {} end -- the factory empties the twin
end
ok, res, log = run(f)
check(log:find("Using the functionalstorage:ender_drawer", 1, true) ~= nil, "found the drawer (" .. tostring(res) .. ") " .. log)
check(f.world.get(0, 1, 0).name == "functionalstorage:ender_drawer", "left the drawer where it was")
check(log:find("Geo miner running", 1, true) ~= nil, "started mining without a drawer in its inventory")

print("Starts with an empty tank")
f = setup({ moves = 200 })
f.t.fuel = 0
ok, res, log = run(f)
check(res == "SIMULATED_REBOOT" and has(f, "minecraft:raw_iron") == 2, "refuels from its charcoal first (" .. tostring(res) .. ")")

print("Recalibrates correctly when the compass is cleared mid-dig")
f = setup({ moves = 60 })
ok, res = run(f)
check(res == "SIMULATED_REBOOT", "stopped mid-dig")
-- Forget the compass (as when a bad one is cleared by hand), turned to one side.
f.computer.files["/.geominer"] = f.computer.files["/.geominer"]:gsub('%["forward"%]={[^}]*},?', ""):gsub('%["targets"%]={.-}},?', "")
-- Facing backwards: the worst case for a compass measured "forward".
local turns = (2 - f.t.dir) % 4
f.t.dir = 2
f.computer.files["/.geominer"] = f.computer.files["/.geominer"]:gsub('%["dir"%]=%d', '["dir"]=2')
f.t.crashAt = 700
ok, res, log = run(f)
check(res == "SIMULATED_REBOOT", "runs again (" .. tostring(res) .. ")")
check(has(f, "minecraft:diamond") == 1, "still finds the diamond further out")

print("Digs ore showing in the tunnel walls, even when the scan missed it")
f = setup({ moves = 120 })
-- A blind scanner: only looking round on the way can find anything.
local realCall = f.computer.peripheral.call
f.computer.peripheral.call = function(side, method, r)
  local res = realCall(side, method, r)
  return f.blind and {} or res
end
f.blind = false
-- Ore beside the path to the first area, which the turtle walks along x=0.
f.world.set(1, 0, 6, { name = "minecraft:iron_ore" })
f.world.set(0, 1, 9, { name = "minecraft:redstone_ore" })
ok, res = run(f) -- calibrates with a working scanner
f.blind = true
f.t.crashAt = f.t.moves + 200
ok, res, log = run(f)
local function is(x, y, z, n) local b = f.world.get(x, y, z) return b and b.name == n end
check(not is(1, 0, 6, "minecraft:iron_ore") and not is(0, 1, 9, "minecraft:redstone_ore"),
  "dug the ore beside and above the tunnel")

print("Survives a reboot mid-scan")
f = setup({ moves = 600 })
local scanCall = f.computer.peripheral.call
local calls = 0
f.computer.peripheral.call = function(...)
  calls = calls + 1
  if calls == 4 then error("SIMULATED_REBOOT", 0) end -- power cut with the scanner on
  return scanCall(...)
end
ok, res = run(f)
check(res == "SIMULATED_REBOOT" and f.t.right == SCANNER, "crashed with the scanner on")
ok, res, log = run(f)
check(res == "SIMULATED_REBOOT" and f.t.right == "minecraft:diamond_pickaxe", "carries on, pickaxe back (" .. tostring(res) .. ")\n" .. log)
check(has(f, "minecraft:raw_iron") == 2 and has(f, "minecraft:diamond") == 1, "still mines everything")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll geominer tests passed")
