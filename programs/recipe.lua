-- The whole resource tree of any item the factory knows, from nothing:
-- raw materials, smelts, fuel, crafts and a time. Runs on any computer or
-- pocket (it reads lib/recipes.lua, no network). `factory tree` does the
-- same from what is in storage.
--
-- Usage: recipe <item> [n] [furnaces]
--   recipe turtle 4
--   recipe factory_blocks:factory 10000 32

local recipes = require("lib.recipes")
local Plan = require("lib.plan")

local item, n, furnaces = ...
if not item then
  print("Usage: recipe <item> [n] [furnaces]")
  return false
end
n = tonumber(n) or 1
local tree = Plan.new(recipes).tree(item, n, {})
if #tree.crafts == 0 and #tree.smelts == 0 then
  print("No recipe for " .. item .. " (see: factory recipes)")
  return false
end
for _, l in ipairs(Plan.lines(tree, { furnaces = tonumber(furnaces) or 4 })) do print(l) end
return true
