-- Offline tests for programs/factory.lua. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")
local recipes = require("lib.recipes")

local FACTORY = "programs/factory.lua"
local failures = 0

local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

sim.ITEM_TAGS["minecraft:birch_log"] = { ["minecraft:logs"] = true }
sim.ITEM_TAGS["minecraft:birch_planks"] = { ["minecraft:planks"] = true }
sim.RECIPES = recipes.list
local SMELTS = { ["minecraft:cobblestone"] = "minecraft:stone", ["minecraft:raw_iron"] = "minecraft:iron_ingot" }

-- A crafty turtle with an input chest above, an output chest below and a
-- network of two storage chests and a furnace.
local function setup(items, opts)
  opts = opts or {}
  local world = sim.newWorld(function() return nil end)
  world.set(0, 1, 0, { name = "minecraft:chest" })
  world.containers["0,1,0"] = {}
  world.set(0, -1, 0, { name = "minecraft:chest" })
  world.containers["0,-1,0"] = {}
  local t = sim.newTurtle(world, { right = "minecraft:crafting_table" })
  local remotes = {
    ["minecraft:chest_0"] = sim.newInventory(27, items),
    ["minecraft:chest_1"] = sim.newInventory(27),
    ["minecraft:furnace_0"] = sim.newInventory(3, {}, { "minecraft:furnace", "inventory" }),
  }
  local computer = sim.newComputer()
  local localName = "turtle_0"
  if opts.modemOff then localName = nil end
  computer.peripheral = sim.newNetwork(t, remotes, localName)
  return { world = world, t = t, remotes = remotes, computer = computer }
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(FACTORY, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

local function stored(f, name)
  local n = 0
  for rname, inv in pairs(f.remotes) do
    if not rname:find("furnace") then
      for _, it in pairs(inv.slots) do if it.name == name then n = n + it.count end end
    end
  end
  return n
end

local function output(f, name)
  local n = 0
  for _, it in ipairs(f.world.containers["0,-1,0"]) do if it.name == name then n = n + it.count end end
  return n
end

local function turtleEmpty(f)
  for s = 1, 16 do if f.t.inv[s] then return false end end
  return true
end

print("Plan and craft two turtles from raw parts")
local f = setup({
  { "minecraft:stone", 20 }, { "minecraft:redstone", 5 }, { "minecraft:glass", 6 },
  { "minecraft:iron_ingot", 14 }, { "minecraft:birch_log", 4 }, { "minecraft:diamond", 3 },
  { "minecraft:cobblestone", 16 }, { "minecraft:coal", 8 },
})
local ok, res, log = run(f, "plan", "turtle", "2")
check(ok and res == true, "plan finds everything (" .. tostring(res) .. ")")
check(log:find("craft computer_normal x2", 1, true) ~= nil, "plan crafts two computers")
check(log:find("craft birch_planks x4", 1, true) ~= nil, "plan turns logs into planks")

ok, res, log = run(f, "craft", "turtle", "2")
check(ok and res == true, "craft succeeds (" .. tostring(res) .. ")")
check(output(f, "computercraft:turtle_normal") == 2, "two turtles in the output chest")
check(stored(f, "minecraft:iron_ingot") == 0, "used all 14 iron")
check(stored(f, "minecraft:stone") == 6, "used 14 stone")
check(stored(f, "minecraft:glass_pane") == 14, "kept the spare glass panes")
check(stored(f, "minecraft:birch_log") == 0, "used the logs for chests")
check(turtleEmpty(f), "turtle inventory is empty afterwards")

print("Missing materials are reported, nothing is touched")
ok, res, log = run(f, "craft", "mining_turtle", "1")
check(ok and res == false, "craft refuses")
check(log:find("7 iron_ingot", 1, true) ~= nil, "reports the missing iron")
check(log:find("#minecraft:planks", 1, true) ~= nil, "reports missing planks")
check(stored(f, "minecraft:diamond") == 3, "diamonds untouched")

print("Input chest, then a mining turtle")
table.insert(f.world.containers["0,1,0"], { name = "minecraft:iron_ingot", count = 7 })
table.insert(f.world.containers["0,1,0"], { name = "minecraft:birch_log", count = 3 })
table.insert(f.world.containers["0,1,0"], { name = "minecraft:stone", count = 1 })
ok, res, log = run(f, "store")
check(ok and log:find("Stored 11 items", 1, true) ~= nil, "stores the input chest (" .. log .. ")")
check(#f.world.containers["0,1,0"] == 0, "input chest is empty")
ok, res, log = run(f, "craft", "mining_turtle", "1")
check(ok and res == true, "mining turtle crafted (" .. tostring(res) .. " " .. log .. ")")
check(output(f, "computercraft:turtle_normal") == 3, "it is in the output chest")
check(stored(f, "minecraft:diamond") == 0, "pickaxe used the diamonds")
check(stored(f, "computercraft:turtle_normal") == 0, "no turtles left in storage")
check(turtleEmpty(f), "turtle inventory is empty afterwards")

print("Furnaces")
ok, res, log = run(f, "smelt")
local furnace = f.remotes["minecraft:furnace_0"]
check(ok, "smelt runs (" .. tostring(res) .. ")")
check(furnace.slots[1] and furnace.slots[1].name == "minecraft:cobblestone", "loads cobblestone")
check(furnace.slots[2] and furnace.slots[2].name == "minecraft:coal", "loads coal as fuel")
check(turtleEmpty(f), "turtle inventory is empty afterwards")
local stoneBefore = stored(f, "minecraft:stone")
sim.smelt(furnace, SMELTS)
ok, res, log = run(f, "smelt")
check(log:find("Smelted 16 stone", 1, true) ~= nil, "collects the stone (" .. log .. ")")
check(stored(f, "minecraft:stone") == stoneBefore + 16, "stone is in storage")

print("Get takes bare vanilla names")
ok, res, log = run(f, "get", "stone", "2")
check(ok and res == true, "get stone 2 (" .. log .. ")")
check(output(f, "minecraft:stone") == 2, "two stone in the output chest")

print("Stock listing")
ok, res, log = run(f, "stock", "stone")
check(log:find("cobblestone", 1, true) == nil and log:find("stone", 1, true) ~= nil, "filters by name")

print("No fuel: furnaces stay empty and hand back what they hold")
f = setup({ { "minecraft:cobblestone", 16 } })
furnace = f.remotes["minecraft:furnace_0"]
furnace.slots[1] = { name = "minecraft:raw_iron", count = 16 }
ok, res = run(f, "smelt")
check(ok, "smelt runs (" .. tostring(res) .. ")")
check(furnace.slots[1] == nil, "furnace without fuel is emptied")
check(stored(f, "minecraft:raw_iron") == 16, "raw iron is back in storage")

print("No fuel but logs: planks get the charcoal going")
f = setup({ { "minecraft:birch_log", 20 } })
furnace = f.remotes["minecraft:furnace_0"]
ok, res, log = run(f, "smelt")
check(ok, "smelt runs (" .. tostring(res) .. ")")
check(furnace.slots[2] and furnace.slots[2].name == "minecraft:birch_planks", "planks as fuel")
check(furnace.slots[1] and furnace.slots[1].name == "minecraft:birch_log"
  and furnace.slots[1].count == 2, "smelts the 2 logs above the spare 16")
check(turtleEmpty(f), "turtle inventory is empty afterwards")
sim.smelt(furnace, { ["minecraft:birch_log"] = "minecraft:charcoal" })
ok, res, log = run(f, "smelt")
check(log:find("Smelted 2 charcoal", 1, true) ~= nil, "collects the charcoal (" .. log .. ")")

print("Charcoal leaves logs for crafting")
f = setup({ { "minecraft:birch_log", 20 }, { "minecraft:coal", 8 } })
furnace = f.remotes["minecraft:furnace_0"]
ok, res = run(f, "smelt")
check(furnace.slots[1] and furnace.slots[1].count == 4, "smelts only logs above the 16 spare")
check(stored(f, "minecraft:birch_log") == 16, "16 logs stay in storage")

print("Wrong recipe gives a clear error and returns the items")
local saved = sim.RECIPES
sim.RECIPES = {}
f = setup({ { "minecraft:stone", 7 }, { "minecraft:redstone", 1 }, { "minecraft:glass_pane", 1 } })
ok, res = run(f, "craft", "computer", "1")
check(not ok and tostring(res):find("JEI", 1, true) ~= nil, "error points at JEI (" .. tostring(res) .. ")")
check(turtleEmpty(f), "ingredients went back to storage")
check(stored(f, "minecraft:stone") == 7, "nothing lost")
sim.RECIPES = saved

print("Modem switched off")
f = setup({}, { modemOff = true })
ok, res = run(f, "stock")
check(not ok and tostring(res):find("Right%-click") ~= nil, "tells the player to right-click the modem")

print("Run loop waits for the network after a reboot and keeps going")
f = setup({ { "minecraft:stone", 5 } }, { modemOff = true })
table.insert(f.world.containers["0,1,0"], { name = "minecraft:iron_ingot", count = 3 })
local sleeps = 0
f.computer.sleep = function()
  sleeps = sleeps + 1
  if sleeps == 2 then f.computer.peripheral.setLocalName("turtle_0") end
  if sleeps == 4 then error("STOP_TEST", 0) end
end
ok, res, log = run(f, "run")
check(res == "STOP_TEST", "loop survives the missing modem (" .. tostring(res) .. ")")
check(log:find("Right-click", 1, true) ~= nil, "reports the modem once")
local _, reports = log:gsub("Right%-click", "")
check(reports == 1, "does not repeat the same error")
check(log:find("Factory running", 1, true) ~= nil, "starts once the modem is on")
check(stored(f, "minecraft:iron_ingot") == 3, "then stores the input chest")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll factory tests passed")
