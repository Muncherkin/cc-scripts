-- Offline tests for programs/lib/plan.lua and programs/recipe.lua. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")
local recipes = require("lib.recipes")
local Plan = require("lib.plan")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local planner = Plan.new(recipes)

local function names(steps)
  local out = {}
  for _, s in ipairs(steps) do out[#out + 1] = s.recipe.name:gsub("^.-:", "") .. " x" .. s.crafts end
  return table.concat(out, ", ")
end

print("Crafts from stock, like the factory's plan")
do
  local have = { ["minecraft:birch_log"] = 2 }
  local steps, missing = planner.plan("minecraft:chest", 1, have)
  check(names(steps) == "birch_planks x2, chest x1", "planks from the logs we have, then the chest (" .. names(steps) .. ")")
  check(next(missing) == nil, "nothing missing")
  check(have["minecraft:birch_log"] == 2, "have is left alone")
  local _, miss = planner.plan("computercraft:computer_normal", 1, {})
  check(miss["minecraft:stone"] == 7 and miss["minecraft:redstone"] == 1, "smelted items count as missing")
  check(miss["minecraft:glass"] == 6, "panes come from glass")
end

print("The whole tree of a turtle, from nothing")
do
  local t = planner.tree("turtle", 1, {})
  check(t.item == "computercraft:turtle_normal", "alias resolved")
  check(t.raws["minecraft:raw_iron"] == 7, "7 raw iron (" .. tostring(t.raws["minecraft:raw_iron"]) .. ")")
  check(t.raws["minecraft:cobblestone"] == 7, "7 cobblestone for the stone")
  check(t.raws["minecraft:sand"] == 6, "6 sand for the panes")
  check(t.raws["minecraft:redstone"] == 1, "1 redstone")
  check(t.raws["minecraft:birch_log"] == 2, "planks fall back on the first wood: 2 logs")
  check(t.raws["minecraft:stone"] == nil and t.raws["minecraft:iron_ingot"] == nil, "no smeltable item left raw")
  check(t.smeltCount == 20, "20 smelts (" .. t.smeltCount .. ")")
  check(t.fuel == 3 and t.fuelLogs == 3, "3 charcoal of fuel")
  local last = t.crafts[#t.crafts]
  check(last.name == "computercraft:turtle_normal" and last.crafts == 1, "the turtle is the last craft")
  local order = {}
  for i, c in ipairs(t.crafts) do order[c.name] = i end
  check(order["computercraft:computer_normal"] < order["computercraft:turtle_normal"], "parts before the turtle")
end

print("A tree from stock only asks for the rest")
do
  local t = planner.tree("turtle", 1, { ["minecraft:stone"] = 5, ["minecraft:iron_ingot"] = 7 })
  check(t.raws["minecraft:cobblestone"] == 2, "2 cobble for the 2 stone short")
  check(t.raws["minecraft:raw_iron"] == nil, "iron in stock")
  check(t.smeltCount == 8, "8 smelts (" .. t.smeltCount .. ")")
end

print("Direct recipes (upgraded turtles) and merged crafts")
do
  local t = planner.tree("chunky_mining_turtle", 2, {})
  check(t.raws["minecraft:diamond"] == 6, "6 diamonds for 2 pickaxes")
  check(t.raws["minecraft:ender_pearl"] == 2 and t.raws["minecraft:blaze_powder"] == 2, "ender eyes down to pearls and blaze powder")
  local sticks = 0
  for _, c in ipairs(t.crafts) do if c.name == "minecraft:stick" then sticks = sticks + 1 end end
  check(sticks == 1, "sticks merged into one line")
end

print("Factory Blocks: the station's 10,003")
do
  local t = planner.tree("factory_blocks:factory", 10003, {})
  check(t.crafts[#t.crafts].crafts == 313, "313 crafts")
  check(t.raws["minecraft:raw_iron"] == 1252 and t.raws["minecraft:cobblestone"] == 1252, "1252 iron and 1252 cobble")
  local s4 = Plan.time(t, { furnaces = 4 })
  local s32 = Plan.time(t, { furnaces = 32 })
  check(s4.smelt == 626 * 10, "4 furnaces: 626 rounds of 10 s (" .. Plan.duration(s4.smelt) .. ")")
  check(s32.smelt == 79 * 10, "32 furnaces: 79 rounds (" .. Plan.duration(s32.smelt) .. ")")
  check(s4.craft > 0 and s4.craft < 120, "crafting is minutes at most (" .. Plan.duration(s4.craft) .. ")")
end

print("Gathering time at given rates")
do
  local t = planner.tree("factory_blocks:factory", 320, {})
  local rows = Plan.eta(t, { ["minecraft:cobblestone"] = 60, ["minecraft:raw_iron"] = 4 })
  check(rows[1].item == "minecraft:raw_iron" and rows[1].minutes == 10, "iron is the slow one: 10 min")
  check(rows[2].minutes == 40 / 60, "cobble in under a minute")
  local none = Plan.eta(t, {})
  check(none[1].minutes == math.huge, "no rate: never")
end

print("Ranking raw demand over many orders")
do
  local orders = { { "factory_blocks:factory", 640 }, { "chunky_mining_turtle", 2 }, { "minecraft:torch", 64 } }
  local rows, smelts = planner.rank(orders, { ["minecraft:raw_iron"] = 10 }, { ["minecraft:cobblestone"] = 60 })
  local by = {}
  for i, r in ipairs(rows) do by[r.item] = { i = i, r = r } end
  -- 80 + 2*(7 casing + 4 chunk controller) = 102 iron less 10 in stock.
  check(by["minecraft:raw_iron"].r.n == 92, "iron summed over orders, stock taken off (" .. by["minecraft:raw_iron"].r.n .. ")")
  check(by["minecraft:cobblestone"].r.n == 94, "cobble: 80 + 14")
  check(rows[1].item == "minecraft:cobblestone" and rows[2].item == "minecraft:raw_iron", "biggest first")
  check(by["minecraft:coal"].r.n == 16, "16 coal for the torches")
  check(by["#minecraft:logs"] ~= nil and by["#minecraft:logs"].r.n == math.ceil(smelts / 7), "fuel counted as logs")
  check(by["minecraft:cobblestone"].r.minutes == 94 / 60, "rate gives minutes")
  local plain = planner.rank(orders, {}, nil, { fuel = false })
  for _, r in ipairs(plain) do check(r.item ~= "#minecraft:logs", "fuel left out on request") end
end

print("Durations")
check(Plan.duration(30) == "30s" and Plan.duration(250) == "4m10s" and Plan.duration(3900) == "1h05m", "30s 4m10s 1h05m")
check(Plan.duration(math.huge) == "never", "never")

print("recipe program prints a tree that fits a pocket")
do
  local log = {}
  local ok, res = sim.run("programs/recipe.lua", sim.newTurtle(sim.newWorld(function() return nil end), {}),
    sim.newComputer(), log, "chunky_mining_turtle", "2", "8")
  local text = table.concat(log, "\n")
  check(ok and res == true, "runs (" .. tostring(res) .. ")")
  check(text:find("22 raw_iron", 1, true) ~= nil, "lists the iron")
  check(text:find("Time: ", 1, true) ~= nil and text:find("(8 furnaces)", 1, true) ~= nil, "a time on 8 furnaces")
  local wide = 0
  for _, l in ipairs(log) do if #l > 26 then wide = wide + 1 print("    too wide: " .. l) end end
  check(wide == 0, "every line fits 26 columns")
  local log2 = {}
  local ok2, res2 = sim.run("programs/recipe.lua", sim.newTurtle(sim.newWorld(function() return nil end), {}),
    sim.newComputer(), log2, "dirt")
  check(ok2 and res2 == false and log2[1]:find("No recipe", 1, true), "unknown item: says so")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll plan tests passed")
