-- Jobs a newborn turtle can be given with `factory birth <job>`.
--
-- unit:    what the factory crafts and places (a recipe name)
-- program: what the newborn runs on every boot (its agent autorun)
-- files:   programs copied onto it through the boot disk
-- kit:     items handed to it after it is placed
-- fuel:    charcoal (or coal) handed to it

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
}
