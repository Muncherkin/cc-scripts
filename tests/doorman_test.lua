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
  for z = 4747, 4752 do for x = 3545, 3548 do set(x, 72, z, "minecraft:snow") end end
  set(3545, 72, 4747, "minecraft:iron_door")                      -- the gate, moved a block in
  set(3545, 73, 4747, "minecraft:iron_door")
  set(3545, 74, 4747, "factory_blocks:circuit")                   -- the solid block above it
  for x = 3540, 3550 do                                           -- the fence
    set(x, 72, 4746, "minecraft:iron_bars") set(x, 73, 4746, "minecraft:iron_bars")
  end
  set(3545, 72, 4746, nil) set(3545, 73, 4746, nil)               -- its gap, in front of the gate
  set(3547, 72, 4753, "minecraft:iron_door")                      -- the vault door
  set(3547, 73, 4753, "minecraft:iron_door")
  set(3548, 72, 4753, "factory_blocks:circuit")
  set(3548, 73, 4753, "factory_blocks:circuit")                   -- the block east of the door
  set(3549, 72, 4749, "waystones:waystone")                       -- the waystone in the yard
  set(3549, 73, 4749, "waystones:waystone")
  -- The vault: x 3546-3548, z 4753-4756, y 72-74, with the shed door and
  -- Keeper on its north side and the hole for Doorman's home on the east.
  for x = 3546, 3548 do for z = 4754, 4756 do for y = 72, 74 do set(x, y, z, "factory_blocks:circuit") end end end
  set(3546, 72, 4753, "factory_blocks:circuit") set(3546, 73, 4753, "computercraft:computer_normal") -- Keeper, west of the door
  set(3548, 73, 4755, nil)                                        -- the hole the player dug for its home
  set(3549, 72, 4755, "minecraft:snow")                           -- on its doorstep, east
  local t = sim.newTurtle(world, { fuel = 0, right = "minecraft:diamond_pickaxe", left = "advancedperipherals:environment_detector",
    inventory = { { "minecraft:coal", 64 }, { "factory_blocks:circuit", 1 } } })
  local computer = sim.newComputer()
  local f = { world = world, t = t, computer = computer, out = {}, sleeps = 0, player = nil, opened = 0, shut = 0, dug = 0 }
  -- Counts digs of anything but snow.
  for _, side in ipairs({ "", "Up", "Down" }) do
    local dig, inspect = t.api["dig" .. side], t.api["inspect" .. side]
    t.api["dig" .. side] = function()
      local ok, b = inspect()
      if ok and b.name ~= "minecraft:snow" then f.dug = f.dug + 1 end
      return dig()
    end
  end
  computer.globals = {
    redstone = { setOutput = function(side, v)
      f.out[side] = v
      if side == "left" then if v then f.opened = f.opened + 1 else f.shut = f.shut + 1 end end
    end },
  }
  computer.peripheral = {
    hasType = function(side, ty) return side == "left" and ty == "environment_detector" end,
    call = function(side, method)
      if method ~= "scanEntities" then error("no method " .. method) end
      local list = {}
      if f.player then
        local wx, wy, wz = F.x + t.x, F.y + t.y, F.z - 1 - t.z
        list[1] = { name = "minecraft:player", uuid = f.player[4] or "someone-else",
          x = f.player[1] - wx, y = f.player[2] - wy, z = f.player[3] - wz }
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

local OWNER = "f725aa4e-d936-3b45-bc95-0962562e7d67"
local function posOf(f) local x, y, z = f.world_pos() return x .. " " .. y .. " " .. z end

print("Rests at home, opens the gate for anyone, clears the path round the waystone")
do
  local f = setup()
  local home
  local onTop = false
  f.onSleep = function(clock)
    local x, y, z = f.world_pos()
    if x == 3548 and y == 73 and z == 4755 then home = home or clock end
    if x == 3546 and y == 73 and z == 4748 and f.t.dir == 1 and f.out.left then onTop = true end
    if home and clock - home > 100 and clock - home < 115 then f.player = { 3545, 72, 4745 } else f.player = nil end
  end
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")\n" .. log:sub(-500))
  check(posOf(f) == "3548 73 4755", "back home (" .. posOf(f) .. ")")
  check(f.t.dir == 1, "looking out east")
  check(onTop, "opened the gate from beside it, facing along the fence")
  check(f.opened >= 1 and f.shut >= 1 and f.out.bottom == false, "and shut it after")
  check(f.w(3545, 74, 4747) == "factory_blocks:circuit", "block above the gate left as it was")
  local path = { { 3548, 4751 }, { 3547, 4751 }, { 3548, 4750 }, { 3547, 4750 }, { 3548, 4749 },
    { 3547, 4749 }, { 3546, 4749 }, { 3547, 4748 }, { 3546, 4748 }, { 3545, 4748 } }
  local left = 0
  for _, c in ipairs(path) do if f.w(c[1], 72, c[2]) == "minecraft:snow" then left = left + 1 end end
  check(left == 0, "the path is clear of snow (" .. left .. " left)")
  check(f.w(3545, 72, 4752) == "minecraft:snow", "snow off the path left alone")
  check(f.w(3549, 73, 4749) == "waystones:waystone", "waystone untouched")
  check(f.w(3546, 73, 4753) == "computercraft:computer_normal", "Keeper untouched")
  check(f.dug == 0, "dug nothing but snow (" .. f.dug .. " other digs)")
end

print("Holds the gate while a player waits by it, instead of going in and out")
do
  local f = setup()
  local home, entries, wasHome, onTopFor = nil, 0, false, 0
  f.onSleep = function(clock)
    local x, y, z = f.world_pos()
    local isHome = x == 3548 and y == 73 and z == 4755
    if isHome and not wasHome then entries = entries + 1 end
    wasHome = isHome
    home = home or (isHome and clock)
    if home and clock - home > 60 and clock - home < 400 then
      f.player = { 3545, 72, 4745 }
      if x == 3546 and y == 73 and z == 4748 and f.out.left then onTopFor = onTopFor + 1 end
    else
      f.player = nil
    end
  end
  run(f)
  check(onTopFor > 100, "held the gate open while the player waited (" .. onTopFor .. ")")
  check(entries <= 3, "went home only when they'd gone (" .. entries .. " times home)")
end

print("Opens the vault door for its owner only")
do
  for _, who in ipairs({ OWNER, "someone-else" }) do
    local f = setup()
    local home, atDoor = nil, 0
    f.onSleep = function(clock)
      local x, y, z = f.world_pos()
      if x == 3548 and y == 73 and z == 4755 then home = home or clock end
      if home and clock - home > 60 and clock - home < 200 then
        f.player = { 3547, 72, 4751, who }
        if x == 3548 and y == 73 and z == 4752 and f.t.dir == 3 and f.out.left then atDoor = atDoor + 1 end
      else
        f.player = nil
      end
    end
    run(f)
    if who == OWNER then
      check(atDoor > 50, "opened it for the owner, facing along the path with the block on its left (" .. atDoor .. ")")
      check(posOf(f) == "3548 73 4755", "and went home after (" .. posOf(f) .. ")")
    else
      check(atDoor == 0, "not for anyone else")
    end
  end
end

print("Goes to the gate when Warden says a player's coming")
do
  local f = setup()
  local home, onTop = nil, false
  f.computer.events = {}
  f.onSleep = function(clock)
    local x, y, z = f.world_pos()
    if x == 3548 and y == 73 and z == 4755 then home = home or clock end
    if home and clock - home > 60 and clock - home < 120 then
      table.insert(f.computer.events, { "bridge_push", "gate_player", {} })
    end
    if x == 3546 and y == 73 and z == 4748 and f.t.dir == 1 and f.out.left then onTop = true end
  end
  run(f)
  check(onTop, "opened the gate on Warden's word")
end

print("At home, a Player Detector against it sees a player outside the gate")
do
  local f = setup()
  local home, opened = nil, false
  local outside = false
  f.computer.peripheral.hasType = function(side, ty)
    return (side == "left" and ty == "environment_detector") or (side == "back" and ty == "player_detector")
  end
  local call = f.computer.peripheral.call
  f.computer.peripheral.call = function(side, method, a, b)
    if side == "back" and method == "isPlayersInCoords" then
      -- Player at 3545 72 4744, outside the gate: in the box?
      return outside and a.x <= 3545 and b.x >= 3545 and a.z <= 4744 and b.z >= 4744
    end
    return call(side, method, a, b)
  end
  f.onSleep = function(clock)
    local x, y, z = f.world_pos()
    if x == 3548 and y == 73 and z == 4755 then home = home or clock end
    outside = home and clock - home > 60 and clock - home < 120 or false
    if x == 3546 and y == 73 and z == 4748 and f.out.left then opened = true end
  end
  run(f)
  check(opened, "opened the gate for a player its own scan couldn't see")
end

print("Comes home from where the survey left it")
do
  local f = setup()
  f.t.x, f.t.y, f.t.z = N(3546, 74, 4748)
  f.computer.files["/.doorman"] = ("{phase=\"home\",dir=3,pos={x=%d,y=%d,z=%d}}"):format(f.t.x, f.t.y, f.t.z)
  f.t.dir = 3
  local ok, res, log = run(f)
  check(res == "STOP_TEST", "keeps running (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(posOf(f) == "3548 73 4755", "home (" .. posOf(f) .. ")")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll doorman tests passed")
