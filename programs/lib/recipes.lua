-- Crafting and smelting recipes for the factory, written from memory of
-- CC: Tweaked 1.21 and vanilla. Modpacks can change recipes: when a craft
-- fails, compare the recipe here with JEI and fix it.
--
-- A recipe is a shaped pattern (rows of key letters, space = empty) plus a
-- key. An ingredient is an item name, or { tag = "...", make = { ... } }
-- which accepts any stored item with that tag and, when short, crafts the
-- first `make` item it can. `count` is how many one craft yields. `direct`
-- recipes make items we can't tell apart in storage (upgraded turtles,
-- floppies), so their result goes straight to the output chest.

-- fromLogs: also try planks made from any log in storage, modded ones too.
local PLANKS = {
  tag = "minecraft:planks",
  fromLogs = true,
  make = { "minecraft:birch_planks", "minecraft:oak_planks", "minecraft:spruce_planks",
           "minecraft:jungle_planks", "minecraft:acacia_planks", "minecraft:dark_oak_planks" },
}
local STONE = "minecraft:stone"
local REDSTONE = "minecraft:redstone"
local PANE = "minecraft:glass_pane"
local GOLD = "minecraft:gold_ingot"

local r = {}

local function add(name, pattern, key, count, extra)
  local recipe = { name = name, pattern = pattern, key = key, count = count or 1 }
  for k, v in pairs(extra or {}) do recipe[k] = v end
  r[#r + 1] = recipe
  return recipe
end

-- Vanilla parts
for _, wood in ipairs({ "birch", "oak", "spruce", "jungle", "acacia", "dark_oak" }) do
  add("minecraft:" .. wood .. "_planks", { "L" }, { L = "minecraft:" .. wood .. "_log" }, 4)
end
add("minecraft:stick", { "P", "P" }, { P = PLANKS }, 4)
add("minecraft:chest", { "PPP", "P P", "PPP" }, { P = PLANKS })
add("minecraft:crafting_table", { "PP", "PP" }, { P = PLANKS })
add("minecraft:furnace", { "CCC", "C C", "CCC" }, { C = "minecraft:cobblestone" })
add("minecraft:bucket", { "I I", " I " }, { I = "minecraft:iron_ingot" })
add("minecraft:torch", { "C", "S" }, { C = "minecraft:coal", S = "minecraft:stick" }, 4)
-- Shapeless in-game; any two cells side by side do.
add("minecraft:ender_eye", { "PB" }, { P = "minecraft:ender_pearl", B = "minecraft:blaze_powder" })
add("minecraft:glass_pane", { "GGG", "GGG" }, { G = "minecraft:glass" }, 16)
add("minecraft:paper", { "SSS" }, { S = "minecraft:sugar_cane" }, 3)
add("minecraft:note_block", { "PPP", "PRP", "PPP" }, { P = PLANKS, R = REDSTONE })
add("minecraft:golden_apple", { "GGG", "GAG", "GGG" }, { G = GOLD, A = "minecraft:apple" })
-- Create's andesite alloy (cut into andesite bars on a stonecutter or a
-- Mechanical Saw, which turtles can't do).
add("minecraft:iron_nugget", { "I" }, { I = "minecraft:iron_ingot" }, 9)
add("create:andesite_alloy", { "NA", "AN" }, { N = "minecraft:iron_nugget", A = "minecraft:andesite" })
add("minecraft:diamond_pickaxe", { "DDD", " S ", " S " }, { D = "minecraft:diamond", S = "minecraft:stick" })

-- CC: Tweaked
add("computercraft:computer_normal", { "SSS", "SRS", "SGS" }, { S = STONE, R = REDSTONE, G = PANE })
add("computercraft:computer_advanced", { "GGG", "GRG", "GPG" }, { G = GOLD, R = REDSTONE, P = PANE })
add("computercraft:turtle_normal", { "III", "ICI", "IHI" },
  { I = "minecraft:iron_ingot", C = "computercraft:computer_normal", H = "minecraft:chest" })
add("computercraft:turtle_advanced", { "GGG", "GCG", "GHG" },
  { G = GOLD, C = "computercraft:computer_advanced", H = "minecraft:chest" })
add("computercraft:wired_modem", { "SSS", "SRS", "SSS" }, { S = STONE, R = REDSTONE })
add("computercraft:wired_modem_full", { "M" }, { M = "computercraft:wired_modem" })
add("computercraft:cable", { " S ", "SRS", " S " }, { S = STONE, R = REDSTONE }, 6)
add("computercraft:wireless_modem_normal", { "SSS", "SPS", "SSS" }, { S = STONE, P = "minecraft:ender_pearl" })
add("computercraft:wireless_modem_advanced", { "GGG", "GEG", "GGG" }, { G = GOLD, E = "minecraft:ender_eye" })
add("computercraft:disk_drive", { "SSS", "SRS", "SRS" }, { S = STONE, R = REDSTONE })
-- New floppies carry item data (their colour), so storage can't match them by name.
add("computercraft:disk", { "RP" }, { R = REDSTONE, P = "minecraft:paper" }, 1,
  { direct = true, output = "computercraft:disk" })
add("computercraft:monitor_normal", { "SSS", "SGS", "SSS" }, { S = STONE, G = PANE })
add("computercraft:monitor_advanced", { "GGG", "GPG", "GGG" }, { G = GOLD, P = PANE }, 4)
add("computercraft:printer", { "SSS", "SRS", "SIS" }, { S = STONE, R = REDSTONE,
  I = { tag = "c:dyes/black", make = { "minecraft:black_dye", "minecraft:ink_sac" } } })
add("computercraft:speaker", { "SSS", "SNS", "SRS" }, { S = STONE, N = "minecraft:note_block", R = REDSTONE })
add("computercraft:pocket_computer_normal", { "SSS", "SAS", "SGS" },
  { S = STONE, A = "minecraft:golden_apple", G = PANE })

-- Upgraded turtles: the upgrade goes on the side it sits in the grid.
add("mining_turtle", { "TP" }, { T = "computercraft:turtle_normal", P = "minecraft:diamond_pickaxe" }, 1,
  { direct = true, output = "computercraft:turtle_normal" })
-- Advanced Peripherals' chunk controller (a turtle upgrade that keeps its
-- chunk loaded): the ender eyes come from the player.
add("advancedperipherals:chunk_controller", { "IRI", "RAR", "IRI" },
  { I = "minecraft:iron_ingot", R = REDSTONE, A = "minecraft:ender_eye" })
-- Both sides at once: chunk controller on the left, pickaxe on the right.
add("chunky_mining_turtle", { "CTP" }, { C = "advancedperipherals:chunk_controller",
  T = "computercraft:turtle_normal", P = "minecraft:diamond_pickaxe" }, 1,
  { direct = true, output = "computercraft:turtle_normal" })
-- Doorman: an Environment Detector on the left, a pickaxe on the right.
add("doorman_turtle", { "ETP" }, { E = "advancedperipherals:environment_detector",
  T = "computercraft:turtle_normal", P = "minecraft:diamond_pickaxe" }, 1,
  { direct = true, output = "computercraft:turtle_normal" })
-- Gate guard: an Environment Detector on the left, a diamond sword on the right.
add("minecraft:diamond_sword", { "D", "D", "S" }, { D = "minecraft:diamond", S = "minecraft:stick" })
add("guard_turtle", { "ETS" }, { E = "advancedperipherals:environment_detector",
  T = "computercraft:turtle_normal", S = "minecraft:diamond_sword" }, 1,
  { direct = true, output = "computercraft:turtle_normal" })
-- Advanced Peripherals' Player Detector (Doorman's eyes on the gate) and
-- the casing it's built on.
add("minecraft:iron_bars", { "III", "III" }, { I = "minecraft:iron_ingot" }, 16)
add("advancedperipherals:peripheral_casing", { "IBI", "BRB", "IBI" },
  { I = "minecraft:iron_ingot", B = "minecraft:iron_bars", R = "minecraft:redstone_block" })
add("advancedperipherals:player_detector", { "SSS", "SAS", "SRS" },
  { S = "minecraft:smooth_stone", A = "advancedperipherals:peripheral_casing", R = "minecraft:redstone_block" })
add("crafty_turtle", { "TC" }, { T = "computercraft:turtle_normal", C = "minecraft:crafting_table" }, 1,
  { direct = true, output = "computercraft:turtle_normal" })

-- Short names for the command line.
local alias = {
  computer = "computercraft:computer_normal",
  advanced_computer = "computercraft:computer_advanced",
  turtle = "computercraft:turtle_normal",
  advanced_turtle = "computercraft:turtle_advanced",
  wired_modem = "computercraft:wired_modem",
  modem_block = "computercraft:wired_modem_full",
  cable = "computercraft:cable",
  wireless_modem = "computercraft:wireless_modem_normal",
  ender_modem = "computercraft:wireless_modem_advanced",
  disk_drive = "computercraft:disk_drive",
  disk = "computercraft:disk",
  monitor = "computercraft:monitor_normal",
  advanced_monitor = "computercraft:monitor_advanced",
  printer = "computercraft:printer",
  speaker = "computercraft:speaker",
  pocket = "computercraft:pocket_computer_normal",
}

-- Plain Factory Blocks (4 iron + 4 stone -> 32), turned into the variants
-- the Clockworks needs at a Chipped Mason Table by the player.
add("factory_blocks:factory", { "ISI", "S S", "ISI" }, { I = "minecraft:iron_ingot", S = "minecraft:stone" }, 32)

-- What the furnaces make. `keep` is the stock to aim for; raw ores are
-- always smelted. `spare` is how much input to leave for crafting.
local smelting = {
  { input = "minecraft:raw_iron", output = "minecraft:iron_ingot", keep = math.huge },
  { input = "minecraft:raw_gold", output = "minecraft:gold_ingot", keep = math.huge },
  { input = "minecraft:iron_ore", output = "minecraft:iron_ingot", keep = math.huge },
  { input = "minecraft:deepslate_iron_ore", output = "minecraft:iron_ingot", keep = math.huge },
  { input = "minecraft:gold_ore", output = "minecraft:gold_ingot", keep = math.huge },
  { input = "minecraft:deepslate_gold_ore", output = "minecraft:gold_ingot", keep = math.huge },
  { input = "minecraft:cobblestone", output = "minecraft:stone", keep = 1400 }, -- plain Factory Blocks for the Clockworks
  { input = "minecraft:sand", output = "minecraft:glass", keep = 64 },
  { input = "minecraft:stone", output = "minecraft:smooth_stone", keep = 16 },
  { input = { tag = "minecraft:logs" }, output = "minecraft:charcoal", keep = 32, spare = 16 },
}

-- Best first. Planks only get the furnaces started when there is no charcoal yet.
local fuels = { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", PLANKS }

local byName = {}
for _, recipe in ipairs(r) do byName[recipe.name] = byName[recipe.name] or recipe end

-- Short name, recipe name or full id -> the id used in storage and recipes.
-- Bare names are vanilla: "gold_ingot" -> "minecraft:gold_ingot".
local function resolve(name)
  if alias[name] or byName[name] then return alias[name] or name end
  if not name:find(":", 1, true) then return "minecraft:" .. name end
  return name
end

-- Modded woods follow the vanilla naming: "mod:pine_log" -> 4 "mod:pine_planks".
local function get(name)
  name = resolve(name)
  if byName[name] then return byName[name] end
  local log = name:match("^(.+)_planks$")
  if log then
    byName[name] = { name = name, pattern = { "L" }, key = { L = log .. "_log" }, count = 4 }
    return byName[name]
  end
end

return {
  list = r,
  get = get,
  -- Stripped logs make the plain planks, which this naming can't reach.
  planksFor = function(log)
    if log:find("stripped", 1, true) or not log:match("_log$") then return nil end
    return (log:gsub("_log$", "_planks"))
  end,
  resolve = resolve,
  alias = alias,
  smelting = smelting,
  fuels = fuels,
}
