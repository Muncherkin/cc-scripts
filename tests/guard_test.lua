-- Offline tests for programs/guard.lua. Run with: npm test
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
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

-- Ground up to y 71, the fence with its gate at 3545 72-73 4746, Doorman in
-- the bar's place above it, the factory. Mobs are entities the detector
-- reports and the sword can strike: { name, x, y, z, hp }.
local function setup(mobs)
  local world = sim.newWorld(function(x, y, z)
    if y < 71 - F.y + 1 then return { name = "minecraft:stone" } end
  end)
  local function set(x, y, z, name) local a, b, c = N(x, y, z) world.set(a, b, c, name and { name = name }) end
  set(F.x, F.y, F.z, "computercraft:turtle_normal")
  set(F.x, F.y + 1, F.z - 1, "minecraft:cobblestone")
  for x = 3538, 3552 do
    if x ~= 3545 then set(x, 72, 4746, "minecraft:iron_bars") set(x, 73, 4746, "minecraft:iron_bars") end
  end
  set(3545, 72, 4746, "minecraft:iron_door")
  set(3545, 73, 4746, "minecraft:iron_door")
  set(3545, 74, 4746, "computercraft:turtle_normal")                -- Doorman
  local t = sim.newTurtle(world, { fuel = 0, right = "minecraft:diamond_sword", left = "advancedperipherals:environment_detector",
    inventory = { { "minecraft:coal", 64 } } })
  local f = { world = world, t = t, mobs = mobs, hits = {}, sleeps = 0 }
  local function tw() return F.x + t.x, F.y + t.y, F.z - 1 - t.z end
  f.tw = tw
  local function strikeAt(x, y, z)
    for _, m in ipairs(f.mobs) do
      if m.hp > 0 and m.x == x and m.y == y and m.z == z then
        m.hp = m.hp - 1
        f.hits[m.name] = (f.hits[m.name] or 0) + 1
        return true
      end
    end
    return false, "Nothing to attack here"
  end
  t.api.attack = function() local x, y, z = tw() return strikeAt(x + DX[t.dir], y, z - DZ[t.dir]) end
  t.api.attackUp = function() local x, y, z = tw() return strikeAt(x, y + 1, z) end
  t.api.attackDown = function() local x, y, z = tw() return strikeAt(x, y - 1, z) end
  local computer = sim.newComputer()
  f.computer = computer
  computer.peripheral = {
    hasType = function(side, ty) return side == "left" and ty == "environment_detector" end,
    call = function(_, method, r)
      local x, y, z = tw()
      local list = {}
      for _, m in ipairs(f.mobs) do
        if m.hp > 0 and math.abs(m.x - x) <= r and math.abs(m.z - z) <= r then
          list[#list + 1] = { name = m.name, x = m.x - x, y = m.y - y, z = m.z - z }
        end
      end
      return list
    end,
  }
  local clock = 0
  computer.clock = function() return clock end
  computer.sleep = function(s)
    clock = clock + s
    f.sleeps = f.sleeps + 1
    if f.sleeps > 3000 then error("STOP_TEST", 0) end
  end
  function f.w(x, y, z) local b = world.get(N(x, y, z)) return b and b.name end
  return f
end

local function run(f)
  local log = {}
  local ok, res = sim.run("programs/guard.lua", f.t, f.computer, log)
  return ok, res, table.concat(log, "\n")
end

print("Kills the monsters by the gate, spares the rest, goes back to its post")
do
  local f = setup({
    { name = "minecraft:zombie", x = 3548, y = 72, z = 4741, hp = 3 },
    { name = "minecraft:skeleton", x = 3540, y = 72, z = 4743, hp = 3 },
    { name = "minecraft:creeper", x = 3546, y = 72, z = 4750, hp = 2 },  -- inside the fence
    { name = "minecraft:cow", x = 3544, y = 72, z = 4743, hp = 3 },
    { name = "minecraft:enderman", x = 3541, y = 72, z = 4741, hp = 3 },
    { name = "minecraft:player", x = 3546, y = 72, z = 4744, hp = 3 },
    { name = "minecraft:zombie", x = 3575, y = 72, z = 4746, hp = 3 },  -- far from the gate
  })
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps watch (" .. tostring(res) .. ")\n" .. log:sub(-500))
  local m = f.mobs
  check(m[1].hp <= 0 and m[2].hp <= 0, "killed the zombie and skeleton outside the gate")
  check(m[3].hp <= 0, "and the creeper inside the fence")
  check(not f.hits["minecraft:cow"] and not f.hits["minecraft:player"] and not f.hits["minecraft:enderman"],
    "never struck the cow, the player or the enderman")
  check(m[7].hp == 3, "left the zombie far from the gate alone")
  local x, y, z = f.tw()
  check(x == 3543 and y == 72 and z == 4744, ("back at its post (%d %d %d)"):format(x, y, z))
  check(f.w(3545, 72, 4746) == "minecraft:iron_door" and f.w(3545, 74, 4746) == "computercraft:turtle_normal"
    and f.w(3544, 72, 4746) == "minecraft:iron_bars", "gate, fence and Doorman untouched")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll guard tests passed")
