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
    files = { "treefarm.lua", "lib/nav.lua", "lib/state.lua" },
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
    files = { "geominer.lua", "lib/nav.lua", "lib/state.lua" },
    kit = {
      { "advancedperipherals:geo_scanner", 1 },
      { "minecraft:bucket", 1 },
    },
    fuel = 16,
    kitToOutput = true,
  },
  -- One of the crew digging out the Clockworks (see programs/excavate.lua):
  -- factory birth excavator <zone>. It flies to the works by itself; a zone
  -- takes about 4,500 fuel, and it waits on the birth spot (the fuel
  -- station) until it has enough to set out.
  excavator = {
    unit = "chunky_mining_turtle",
    program = "excavate",
    files = { "excavate.lua", "lib/nav.lua", "lib/move.lua", "lib/state.lua", "blueprints/excavation.lua" },
    kit = {
      { "minecraft:bucket", 1 },
    },
    fuel = 64,
  },
  -- Keeps the gate by Otis's shed (programs/doorman.lua): opens it for
  -- players, clears the path of snow. The Environment Detector comes from
  -- the player.
  doorman = {
    unit = "doorman_turtle",
    program = "doorman",
    files = { "doorman.lua", "lib/nav.lua", "lib/state.lua" },
    kit = {},
    fuel = 64,
  },
  -- Hunts monsters round the gate (programs/guard.lua). The Environment
  -- Detector comes from the player.
  guard = {
    unit = "guard_turtle",
    program = "guard",
    files = { "guard.lua", "lib/nav.lua", "lib/state.lua" },
    kit = {},
    fuel = 64,
  },
  -- Once the works are dug: sets torches on every floor so nothing spawns
  -- Maps the works with a geo scanner (factory birth scout): what's still
  -- standing and where the water is, into /scout.txt.
  scout = {
    unit = "chunky_mining_turtle",
    program = "excavate",
    args = { "scout" },
    files = { "excavate.lua", "lib/nav.lua", "lib/move.lua", "lib/state.lua", "blueprints/excavation.lua" },
    kit = {
      { "advancedperipherals:geo_scanner", 1 },
    },
    fuel = 32,
  },
  -- (factory birth lamplighter). The light route has 59 torches.
  lamplighter = {
    unit = "chunky_mining_turtle",
    program = "excavate",
    args = { "light" },
    files = { "excavate.lua", "lib/nav.lua", "lib/move.lua", "lib/state.lua", "blueprints/excavation.lua" },
    kit = {
      { "minecraft:torch", 64 },
    },
    fuel = 32,
  },
}
