-- Offline tests for programs/doorman.lua. Run with: npm test
--
-- The simulator's coordinates are the program's nav frame: the turtle is
-- born on the birth spot, one north of the factory at world (3559, 74, 4763),
-- with nav +z north and +x east: nav = (x - 3559, y - 74, 4762 - z).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local F = { x = 3559, y = 74, z = 4763 }
local function N(x, y, z) return x - F.x, y - F.y, F.z - 1 - z end

-- Ground up to y 71 around the yard, snow layers on the path, the gate (an
-- iron door) at 3545 72-73 4746 with iron bars above it, the shed door and
-- the factory block by it.
local function setup()
  local world = sim.newWorld(function(x, y, z)
    if y < 71 - F.y + 1 then return { name = "minecraft:stone" } end
  end)
  local function set(x, y, z, name) local a, b, c = N(x, y, z) world.set(a, b, c, name and { name = name }) end
  set(F.x, F.y, F.z, "computercraft:turtle_normal")              -- the factory
  set(F.x, F.y + 1, F.z - 1, "minecraft:cobblestone")              -- the generator's floor over the birth spot
  for z = 4747, 4752 do for x = 3545, 3547 do set(x, 72, z, "minecraft:snow") end end
  set(3545, 72, 4746, "minecraft:iron_door")
  set(3545, 73, 4746, "minecraft:iron_door")
  set(3545, 74, 4746, "minecraft:iron_bars")
  for x = 3540, 3550 do                                           -- the fence either side
    if x ~= 3545 then set(x, 72, 4746, "minecraft:iron_bars") set(x, 73, 4746, "minecraft:iron_bars") end
  end
  set(3547, 72, 4753, "minecraft:iron_door")                      -- the shed door
  set(3547, 73, 4753, "minecraft:iron_door")
  set(3548, 72, 4753, "factory_blocks:circuit")
  set(3548, 73, 4753, "computercraft:computer_normal")            -- Keeper
  for y = 72, 74 do set(3548, y, 4755, "factory_blocks:circuit") set(3548, y, 4756, "factory_blocks:circuit") end -- the vault's west wall
  set(3548, 73, 4755, nil)                                        -- the hole the player dug for its home
  set(3547, 72, 4755, "minecraft:snow")                           -- on its doorstep
  local t = sim.newTurtle(world, { fuel = 0, right = "minecraft:diamond_pickaxe", left = "advancedperipherals:environment_detector",
    inventory = { { "minecraft:coal", 64 }, { "factory_blocks:circuit", 1 } } })
  local computer = sim.newComputer()
  local f = { world = world, t = t, computer = computer, out = {}, sleeps = 0, player = nil, opened = 0, shut = 0 }
  computer.globals = {
    redstone = { setOutput = function(side, v)
      f.out[side] = v
      if side == "bottom" then if v then f.opened = f.opened + 1 else f.shut = f.shut + 1 end end
    end },
  }
  computer.peripheral = {
    hasType = function(side, ty) return side == "left" and ty == "environment_detector" end,
    call = function(side, method)
      if method ~= "scanEntities" then error("no method " .. method) end
      local list = {}
      if f.player then
        local wx, wy, wz = F.x + t.x, F.y + t.y, F.z - 1 - t.z
        list[1] = { name = "minecraft:player", x = f.player[1] - wx, y = f.player[2] - wy, z = f.player[3] - wz }
      end
      return list
    end,
  }
  local clock = 0
  computer.clock = function() return clock end
  computer.sleep = function(s)
    clock = clock + s
    f.sleeps = f.sleeps + 1
    if f.onSleep then f.onSleep(clock) end
    if f.sleeps > 4000 then error("STOP_TEST", 0) end
  end
  function f.w(x, y, z) local b = world.get(N(x, y, z)) return b and b.name end
  function f.world_pos() return F.x + t.x, F.y + t.y, F.z - 1 - t.z end
  return f
end

local function run(f)
  local log = {}
  local ok, res = sim.run("programs/doorman.lua", f.t, f.computer, log)
  return ok, res, table.concat(log, "\n")
end

print("Lives in the vault wall, opens the gate from on top of it, clears the path")
do
  local f = setup()
  -- A player comes up to the gate from outside once it's settled at home,
  -- and goes away again.
  local home
  local onTop = false
  f.onSleep = function(clock)
    local x, y, z = f.world_pos()
    if x == 3548 and y == 73 and z == 4755 then home = home or clock end
    if x == 3545 and y == 75 and z == 4746 and f.out.bottom then onTop = true end
    if home and clock - home > 100 and clock - home < 115 then f.player = { 3545, 72, 4744 } else f.player = nil end
  end
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")\n" .. log:sub(-500))
  local x, y, z = f.world_pos()
  check(x == 3548 and y == 73 and z == 4755, ("back home in the vault wall (%d %d %d)"):format(x, y, z))
  check(f.t.dir == 3, "looking out west")
  check(f.w(3547, 72, 4755) == nil, "cleared its doorstep")
  check(onTop, "opened the gate standing on the block above it")
  check(f.opened >= 1 and f.shut >= 1 and f.out.bottom == false, "and shut it after")
  check(f.w(3545, 74, 4746) == "factory_blocks:circuit", "the bar above the gate swapped for the factory block")
  local bars = 0
  for s = 1, 16 do local d = f.t.inv[s] if d and d.name == "minecraft:iron_bars" then bars = bars + d.count end end
  check(bars == 1, "kept the bar")
  local path = { { 3545, 4747 }, { 3545, 4748 }, { 3546, 4748 }, { 3546, 4749 }, { 3546, 4750 },
    { 3547, 4750 }, { 3547, 4751 }, { 3547, 4752 } }
  local left = 0
  for _, c in ipairs(path) do if f.w(c[1], 72, c[2]) == "minecraft:snow" then left = left + 1 end end
  check(left == 0, "the path is clear of snow (" .. left .. " left)")
  check(f.w(3547, 72, 4747) == "minecraft:snow" and f.w(3545, 72, 4752) == "minecraft:snow", "snow off the path left alone")
  check(f.w(3547, 72, 4753) == "minecraft:iron_door" and f.w(3548, 73, 4753) == "computercraft:computer_normal",
    "shed door and Keeper untouched")
  check(f.w(3545, 72, 4746) == "minecraft:iron_door" and f.w(3544, 72, 4746) == "minecraft:iron_bars", "gate and fence untouched")
end

print("Moving house: from the bar's place to the new home")
do
  local f = setup()
  -- As the first version left it: in the bar's place above the gate, the bar
  -- and the wall's factory block in its inventory.
  f.world.set(N(3545, 74, 4746))
  f.world.set(N(3548, 72, 4753))
  f.t.x, f.t.y, f.t.z = N(3545, 74, 4746)
  f.t.inv[2] = { name = "minecraft:iron_bars", count = 1 }
  f.t.inv[3] = { name = "factory_blocks:circuit", count = 1 }
  f.computer.files["/.doorman"] = ("{phase=\"post\",dir=0,pos={x=%d,y=%d,z=%d}}"):format(f.t.x, f.t.y, f.t.z)
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")\n" .. log:sub(-500))
  check(f.w(3545, 74, 4746) == "factory_blocks:circuit", "put the factory block above the gate")
  local x, y, z = f.world_pos()
  check(x == 3548 and y == 73 and z == 4755, ("went to the new home (%d %d %d)"):format(x, y, z))
end

print("Moving house: from the old home below Keeper to the new one")
do
  local f = setup()
  f.world.set(N(3548, 72, 4753))
  do local a, b, c = N(3545, 74, 4746) f.world.set(a, b, c, { name = "factory_blocks:circuit" }) end
  f.t.x, f.t.y, f.t.z = N(3548, 72, 4753)
  f.computer.files["/.doorman"] = ("{phase=\"home\",swapped=true,dir=0,pos={x=%d,y=%d,z=%d}}"):format(f.t.x, f.t.y, f.t.z)
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")")
  local x, y, z = f.world_pos()
  check(x == 3548 and y == 73 and z == 4755, ("in the new home (%d %d %d)"):format(x, y, z))
  check(f.w(3548, 73, 4753) == "computercraft:computer_normal", "Keeper untouched")
end

print("Waits on the doorstep until its home is dug out")
do
  local f = setup()
  do local a, b, c = N(3548, 73, 4755) f.world.set(a, b, c, { name = "factory_blocks:circuit" }) end
  local dug = false
  f.onSleep = function(clock)
    local x, y, z = f.world_pos()
    if x == 3547 and y == 73 and z == 4755 and clock > 200 and not dug then
      f.world.set(N(3548, 73, 4755)) dug = true
    end
  end
  local ok, res, log = run(f)
  check(log:find("Waiting for my home to be dug out", 1, true) ~= nil, "says it's waiting")
  local x, y, z = f.world_pos()
  check(dug and x == 3548 and y == 73 and z == 4755, ("moved in once it was dug (%d %d %d)"):format(x, y, z))
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll doorman tests passed")
