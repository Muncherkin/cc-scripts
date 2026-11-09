-- Offline tests for programs/endfeed.lua (feeds endermen to a Weak Automata
-- Core). Run with: npm test
--
-- The simulator's coordinates are the turtle's nav frame: set down facing
-- north, nav +z north, +x east. The fake detector reports world offsets:
-- world dx = nav dx, world dz = -nav dz.
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local PROGRAM = "programs/endfeed.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local CORE = "advancedperipherals:weak_automata_core"
local END_CORE = "advancedperipherals:end_automata_core"
local DETECTOR = "advancedperipherals:environment_detector"
local CONTROLLER = "advancedperipherals:chunk_controller"
local AHEAD = { [0] = { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }

-- End stone below y 0; endermen at nav cells, standing on it.
local function setup(opts)
  opts = opts or {}
  local world = sim.newWorld(function(x, y, z)
    if y < 0 then return { name = "minecraft:stone" } end
    for _, w in ipairs(opts.walls or {}) do
      if w[1] == x and w[2] == y and w[3] == z then return { name = "minecraft:stone" } end
    end
  end)
  local f = { world = world, endermen = {}, fed = 0, scans = 0, sleeps = 0 }
  for _, e in ipairs(opts.endermen or {}) do f.endermen[#f.endermen + 1] = { x = e[1], y = e[2], z = e[3] } end
  f.t = sim.newTurtle(world, {
    fuel = opts.fuel or 5000, left = opts.left or CONTROLLER, right = opts.right or CORE,
    inventory = opts.inventory or { { DETECTOR, 1 }, { CORE, 1 }, { "minecraft:coal", 32 } },
  })
  local t = f.t
  f.computer = sim.newComputer()
  f.computer.sleep = function()
    f.sleeps = f.sleeps + 1
    if f.sleeps > 3000 then error("STUCK_SLEEPING", 0) end
    -- Endermen wander in now and then.
    if opts.spawn and #f.endermen == 0 and #opts.spawn > 0 then
      local e = table.remove(opts.spawn, 1)
      f.endermen[1] = { x = e[1], y = e[2], z = e[3] }
    end
  end
  f.computer.peripheral = {
    isPresent = function(side) return t[side] ~= nil end,
    call = function(side, method)
      if method == "scanEntities" then
        if t[side] ~= DETECTOR then error("No such method") end
        f.scans = f.scans + 1
        local list = { { name = "minecraft:cow", x = 2, y = 0, z = 2 },
          { name = "endermanoverhaul:end_enderman", x = 1, y = 0, z = 0 } }
        for _, e in ipairs(f.endermen) do
          list[#list + 1] = { name = "minecraft:enderman", x = e.x - t.x + 0.3, y = e.y - t.y, z = -(e.z - t.z) - 0.2 }
        end
        return list
      elseif method == "feedSoul" then
        if t[side] ~= CORE then error("No such method") end
        local held = t.inv[t.selected]
        if not (held and held.name == CORE) then return nil, "Well, you should feed correct mechanical soul!" end
        local a = AHEAD[t.dir]
        for i, e in ipairs(f.endermen) do
          if e.x == t.x + a[1] and e.z == t.z + a[2] and t.y >= e.y and t.y <= e.y + 2 then
            table.remove(f.endermen, i)
            f.fed = f.fed + 1
            if f.fed >= 10 then held.name = END_CORE end
            return true
          end
        end
        return nil, "Nothing found"
      end
      error("unexpected " .. tostring(method))
    end,
  }
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

print("Feeds ten endermen to the core in slot 16, then comes back")
do
  local spawn = {}
  local spots = { { 3, 0, 4 }, { -5, 0, 2 }, { 6, 0, -6 }, { 0, 0, 7 }, { -7, 0, -3 },
    { 2, 0, -1 }, { 7, 0, 7 }, { -2, 0, 5 }, { 4, 0, 0 }, { -6, 0, -7 }, { 1, 0, 3 } }
  for _, s in ipairs(spots) do spawn[#spawn + 1] = s end
  local f = setup({ spawn = spawn })
  local ok, res, log = run(f, "north")
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  check(f.fed == 10, "fed ten (" .. f.fed .. ")")
  local held = f.t.inv[16]
  check(held and held.name == CORE, "the weak core is back in slot 16")
  check(f.t.right == END_CORE and f.t.left == CONTROLLER, "the End core on, the chunk controller never off")
  check(f.t.x == 0 and f.t.y == 0 and f.t.z == 0 and f.t.dir == 0, "back where it started, facing the same way")
  check(log:find("Done", 1, true) ~= nil, "says so")
end

print("Burns its coal when it starts empty")
do
  local f = setup({ fuel = 0, spawn = { { 3, 0, 0 } } })
  run(f, "north")
  check(f.fed == 1, "fed one on coal it carried (" .. f.fed .. ")")
  check(f.t.fuel > 0, "has fuel (" .. f.t.fuel .. ")")
end

print("Never goes beyond its leash")
do
  local f = setup({ spawn = { { 14, 0, 0 } } })
  local maxd = 0
  local fwd = f.t.api.forward
  f.t.api.forward = function()
    local r = fwd()
    maxd = math.max(maxd, math.abs(f.t.x), math.abs(f.t.z))
    return r
  end
  local ok = run(f, "north")
  check(not ok, "runs until stopped (the test ends it)")
  check(maxd <= 10, "stayed within 10 (" .. maxd .. ")")
  check(f.fed == 0, "and didn't reach the far one")
end

print("Gets down into a dip and out over a wall")
do
  local walls = {}
  for z = -3, 3 do walls[#walls + 1] = { 2, 0, z } end
  -- A dip: the enderman stands a block lower, behind the wall.
  local f = setup({ walls = walls, spawn = { { 4, -1, 0 } } })
  f.world.set(4, -1, 0, nil)
  f.world.set(3, -1, 0, nil)
  run(f, "north")
  check(f.fed == 1, "fed it (" .. f.fed .. ")")
end

print("Goes over a wall")
do
  local walls = {}
  for z = -3, 3 do walls[#walls + 1] = { 2, 0, z } end
  local f = setup({ walls = walls, spawn = { { 4, 0, 0 } } })
  run(f, "north")
  check(f.fed == 1, "fed the one behind it (" .. f.fed .. ")")
end

print("Needs a second core and a facing")
do
  local f = setup({ inventory = { { DETECTOR, 1 } } })
  local ok, res = run(f, "north")
  check(not ok and tostring(res):find("second Weak Automata Core", 1, true) ~= nil, "asks for the core (" .. tostring(res) .. ")")
  local g = setup()
  ok, res = run(g)
  check(not ok and tostring(res):find("Usage", 1, true) ~= nil, "asks which way it faces")
  local h = setup({ left = "minecraft:diamond_pickaxe" })
  ok, res = run(h, "north")
  check(not ok and tostring(res):find("chunk controller", 1, true) ~= nil, "wants a chunk controller")
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("All passed")
