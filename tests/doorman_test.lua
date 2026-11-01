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
  local t = sim.newTurtle(world, { fuel = 0, right = "minecraft:diamond_pickaxe", left = "advancedperipherals:environment_detector",
    inventory = { { "minecraft:coal", 64 } } })
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

print("Takes its post above the gate, opens it for a player, clears the path")
do
  local f = setup()
  -- A player walks up to the gate from outside a while after it's settled,
  -- and goes away again.
  local arrived
  f.onSleep = function(clock)
    if not arrived and f.w(3545, 74, 4746) == nil and f.t.y == 0 then end
    local x, y, z = f.world_pos()
    if x == 3545 and y == 74 and z == 4746 then
      arrived = arrived or clock
      if clock - arrived > 400 and clock - arrived < 420 then f.player = { 3545, 72, 4744 } else f.player = nil end
    end
  end
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")\n" .. log:sub(-500))
  local x, y, z = f.world_pos()
  check(x == 3545 and y == 74 and z == 4746, ("at its post above the gate (%d %d %d)"):format(x, y, z))
  local bars = 0
  for s = 1, 16 do local d = f.t.inv[s] if d and d.name == "minecraft:iron_bars" then bars = bars + d.count end end
  check(bars == 1, "kept the bar it took the place of")
  check(f.opened >= 1 and f.shut >= 1 and f.out.bottom == false, "opened the gate for the player and shut it after")
  local snow = 0
  for zz = 4747, 4752 do for xx = 3545, 3547 do if f.w(xx, 72, zz) == "minecraft:snow" then snow = snow + 1 end end end
  check(snow == 0, "path cleared of snow (" .. snow .. " left)")
  check(f.w(3548, 72, 4753) == nil, "mined the factory block by the shed door")
  check(f.w(3547, 72, 4753) == "minecraft:iron_door" and f.w(3548, 73, 4753) == "computercraft:computer_normal",
    "shed door and Keeper untouched")
  check(f.w(3545, 72, 4746) == "minecraft:iron_door" and f.w(3544, 72, 4746) == "minecraft:iron_bars", "gate and fence untouched")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll doorman tests passed")
