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
  for i = 1, (opts.furnaces or 1) - 1 do
    remotes["minecraft:furnace_" .. i] = sim.newInventory(3, {}, { "minecraft:furnace", "inventory" })
  end
  local computer = sim.newComputer()
  local localName = "turtle_0"
  if opts.modemOff then localName = nil end
  local f = { world = world, t = t, remotes = remotes, computer = computer, turnedOn = 0 }
  local locals = {}
  if opts.drive then
    -- A floppy drive by the birth spot, and whatever turtle gets placed there.
    remotes["drive_0"] = { types = { "drive" }, api = {
      isDiskPresent = function() return true end,
      getMountPath = function() return "disk" end,
    } }
    locals.front = { types = { "turtle" }, api = { turnOn = function() f.turnedOn = f.turnedOn + 1 end } }
    for path, content in pairs({ ["/birth/startup.lua"] = "-- boot disk", ["/.agent/config"] = "{token=1}",
        ["/cobblesetup.lua"] = "-- setup", ["/cobble.lua"] = "-- cobble" }) do
      computer.files[path] = content
    end
  end
  computer.peripheral = sim.newNetwork(t, remotes, localName, nil, locals)
  return f
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

print("A chest that never empties doesn't hold the turtle forever")
do
  local g = setup({})
  local input = g.world.containers["0,1,0"]
  -- Refill the input chest on every look, like the cobble turtle on top.
  setmetatable(input, { __len = function() return 1 end, __index = function(_, i)
    if i == 1 then
      local it = rawget(input, "_it")
      if not it or it.count == 0 then it = { name = "minecraft:cobblestone", count = 1 } rawset(input, "_it", it) end
      return it
    end
  end })
  local orig = table.remove
  table.remove = function(t, i) if t == input then rawset(input, "_it", nil) return end return orig(t, i) end
  local ok2, res2, log2 = run(g, "store")
  table.remove = orig
  check(ok2 and log2:find("Stored", 1, true) ~= nil, "store returns (" .. tostring(res2) .. ")")
end

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

print("Modded logs make planks and count toward the charcoal reserve")
sim.ITEM_TAGS["mod:pine_log"] = { ["minecraft:logs"] = true }
sim.ITEM_TAGS["mod:pine_planks"] = { ["minecraft:planks"] = true }
local pineRecipes = { recipes.get("mod:pine_planks") }
for _, r in ipairs(recipes.list) do pineRecipes[#pineRecipes + 1] = r end
sim.RECIPES = pineRecipes
f = setup({ { "mod:pine_log", 12 }, { "minecraft:iron_ingot", 7 }, { "minecraft:stone", 7 },
            { "minecraft:redstone", 1 }, { "minecraft:glass_pane", 1 } })
ok, res, log = run(f, "craft", "turtle", "1")
check(ok and res == true, "turtle from pine logs (" .. log .. ")")
check(stored(f, "mod:pine_log") == 10, "used two pine logs for the chest")
f = setup({ { "mod:pine_log", 12 }, { "minecraft:birch_log", 8 }, { "minecraft:coal", 8 } }, { furnaces = 3 })
ok, res = run(f, "smelt")
local logsIn = 0
for i = 0, 2 do
  local input = f.remotes["minecraft:furnace_" .. i].slots[1]
  logsIn = logsIn + (input and input.count or 0)
end
check(logsIn == 4, "all furnaces together smelt only the 4 logs above the reserve (" .. logsIn .. ")")
sim.RECIPES = recipes.list

print("Birth: a cobble turtle is built, placed, given its kit and switched on")
local birthStock = {
  { "minecraft:stone", 7 }, { "minecraft:redstone", 1 }, { "minecraft:glass_pane", 1 },
  { "minecraft:iron_ingot", 7 }, { "minecraft:birch_log", 3 }, { "minecraft:diamond", 3 },
  -- Buckets with item data, like the ones in-game.
  { "minecraft:lava_bucket", 1, "41883520" }, { "minecraft:water_bucket", 1, "41883520" },
  { "minecraft:cobblestone", 32 }, { "minecraft:charcoal", 4 },
}
f = setup(birthStock, { drive = true })
ok, res, log = run(f, "birth", "cobble")
check(ok and res == true, "birth succeeds (" .. tostring(res) .. " " .. log .. ")")
local placed = f.world.get(0, 0, 1)
check(placed and placed.name == "computercraft:turtle_normal", "new turtle placed in front")
local given = {}
for _, it in ipairs(f.world.containers["0,0,1"] or {}) do given[it.name] = (given[it.name] or 0) + it.count end
check(given["minecraft:lava_bucket"] == 1 and given["minecraft:water_bucket"] == 1, "got both buckets")
check(given["minecraft:cobblestone"] == 32 and given["minecraft:charcoal"] == 2, "got cobblestone and fuel")
check(f.turnedOn == 1, "switched on")
local files = f.computer.files
check(files["/disk/startup.lua"] == "-- boot disk" and files["/disk/agent-config"] == "{token=1}", "boot disk written")
check(files["/disk/files/cobblesetup.lua"] and files["/disk/files/cobble.lua"], "job programs on the disk")
check((files["/disk/job"] or ""):find('"cobblesetup"', 1, true) ~= nil, "job is cobblesetup")
check(output(f, "computercraft:turtle_normal") == 0, "nothing went to the output chest")
check(turtleEmpty(f), "factory turtle inventory is empty afterwards")

print("Birth refuses when something is missing or the spot is taken")
f = setup({ { "minecraft:cobblestone", 32 } }, { drive = true })
ok, res, log = run(f, "birth", "cobble")
check(ok and res == false and log:find("lava_bucket", 1, true) ~= nil, "lists what's missing")
check(f.world.get(0, 0, 1) == nil and f.computer.files["/disk/job"] == nil, "touches nothing")
f = setup(birthStock, { drive = true })
f.world.set(0, 0, 1, { name = "minecraft:dirt" })
ok, res = run(f, "birth", "cobble")
check(not ok and tostring(res):find("taken", 1, true) ~= nil, "spot taken")
f = setup(birthStock)
ok, res = run(f, "birth", "cobble")
check(not ok and tostring(res):find("floppy", 1, true) ~= nil, "no drive")

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
check(log:find("Stock: 5 cobble", 1, true) == nil and log:find("Stock: 0 cobble, 5 stone", 1, true) ~= nil,
  "prints a stock line (" .. log .. ")")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll factory tests passed")
