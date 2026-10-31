-- Jobs a newborn turtle can be given with `factory birth <job>`.
--
-- unit:    what the factory crafts and places (a recipe name)
-- program: what the newborn runs on every boot (its agent autorun)
-- files:   programs copied onto it through the boot disk
-- kit:     items handed to it after it is placed
-- fuel:    charcoal (or coal) handed to it
-- kitToOutput: put kit and fuel in the output chest instead (for turtles the
--          player carries somewhere; a picked-up turtle spills its inventory)

return {
  cobble = {
    unit = "mining_turtle",
    program = "cobblesetup",
    files = { "cobblesetup.lua", "cobble.lua" },
    kit = {
      { "minecraft:lava_bucket", 1 },
      { "minecraft:water_bucket", 1 },
      { "minecraft:cobblestone", 32 }, -- 15 walls and floors, 9 for the lid
    },
    fuel = 2,
  },
  tree = {
    unit = "chunky_mining_turtle",
    program = "treefarm",
    files = { "treefarm.lua", "lib/nav.lua" },
    kit = {
      { "*pine_sapling", 4 }, -- any item whose id contains this
    },
    fuel = 8,
  },
  -- Carried to the mining dimension by the player, so the kit goes in the
  -- output chest. The linked chest pair comes from the player.
  geominer = {
    unit = "chunky_mining_turtle",
    program = "geominer",
    files = { "geominer.lua", "lib/nav.lua" },
    kit = {
      { "advancedperipherals:geo_scanner", 1 },
      { "minecraft:bucket", 1 },
    },
    fuel = 16,
    kitToOutput = true,
  },
}
