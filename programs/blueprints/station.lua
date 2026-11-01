-- Made by design/station.mjs: the chest station's chests and what goes in them.
-- Each chest: where it stands (site), how many plain Factory Blocks, and for which variants.
return {
  item = "factory_blocks:factory",
  chests = {
    { x = -3, y = 12, z = -5, n = 1728, for_ = { { "factory_blocks:circuit", 1728 } } },
    { x = -3, y = 13, z = -5, n = 970, for_ = { { "factory_blocks:circuit", 970 } } },
    { x = -3, y = 14, z = -5, n = 1728, for_ = { { "factory_blocks:large_plating", 1728 } } },
    { x = -1, y = 12, z = -5, n = 929, for_ = { { "factory_blocks:large_plating", 929 } } },
    { x = -1, y = 13, z = -5, n = 1426, for_ = { { "factory_blocks:sturdy", 1426 } } },
    { x = -1, y = 14, z = -5, n = 785, for_ = { { "factory_blocks:old_vents", 785 } } },
    { x = 1, y = 12, z = -5, n = 700, for_ = { { "factory_blocks:wireframe", 700 } } },
    { x = 1, y = 13, z = -5, n = 599, for_ = { { "factory_blocks:grate", 599 } } },
    { x = 1, y = 14, z = -5, n = 413, for_ = { { "factory_blocks:hex", 413 } } },
    { x = 3, y = 12, z = -5, n = 725, for_ = { { "factory_blocks:wgpanel", 228 }, { "factory_blocks:gvent", 203 }, { "factory_blocks:piping", 158 }, { "factory_blocks:fan", 81 }, { "factory_blocks:engineer", 55 } } },
  },
}
