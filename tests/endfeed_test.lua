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
  local f = { world = world, endermen = {}, others = {}, fed = 0, made = 0, killed = 0, scans = 0, sleeps = 0 }
  for _, e in ipairs(opts.endermen or {}) do f.endermen[#f.endermen + 1] = { x = e[1], y = e[2], z = e[3] } end
  for _, e in ipairs(opts.others or {}) do f.others[#f.others + 1] = { x = e[1], y = e[2], z = e[3], hp = 3 } end
  f.t = sim.newTurtle(world, {
    fuel = opts.fuel or 5000, left = opts.left or CONTROLLER, right = opts.right or CORE,
    inventory = opts.inventory or { { DETECTOR, 1 }, { CORE, 1 }, { "minecraft:coal", 32 } },
  })
  local t = f.t
  f.computer = sim.newComputer()
  f.computer.sleep = function()
    f.sleeps = f.sleeps + 1
    if f.sleeps > (opts.maxSleeps or 3000) then error("STUCK_SLEEPING", 0) end
    -- Endermen wander in now and then.
    if opts.spawn and #f.endermen == 0 and #opts.spawn > 0 then
      local e = table.remove(opts.spawn, 1)
      f.endermen[1] = { x = e[1], y = e[2], z = e[3] }
    end
  end
  f.computer.peripheral = {
    isPresent = function(side) return t[side] ~= nil end,
    hasType = function(side, ty) return ty == "environment_detector" and t[side] == DETECTOR end,
    call = function(side, method)
      if method == "scanEntities" then
        if t[side] ~= DETECTOR then error("No such method") end
        f.scans = f.scans + 1
        local list = { { name = "minecraft:cow", uuid = "cow", x = 3 - t.x, y = 0, z = -(3 - t.z) } }
        for _, e in ipairs(f.endermen) do
          list[#list + 1] = { name = "minecraft:enderman", x = e.x - t.x + 0.3, y = e.y - t.y, z = -(e.z - t.z) - 0.2 }
        end
        for _, e in ipairs(f.others) do
          list[#list + 1] = { name = "endermanoverhaul:end_enderman", x = e.x - t.x, y = e.y - t.y, z = -(e.z - t.z) }
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
            held.fed = (held.fed or 0) + 1
            if held.fed >= 10 then held.name = END_CORE end
            return true
          end
        end
        return nil, "Nothing found"
      end
      error("unexpected " .. tostring(method))
    end,
  }
  -- The sword: three hits and an End Enderman is gone, leaving a pearl.
  t.api.attack = function()
    if not (t.right and t.right:find("_sword$") or t.left and t.left:find("_sword$")) then return false end
    local a = AHEAD[t.dir]
    for i, e in ipairs(f.others) do
      if e.x == t.x + a[1] and e.z == t.z + a[2] and t.y >= e.y and t.y <= e.y + 2 then
        e.hp = e.hp - 1
        if e.hp <= 0 then
          table.remove(f.others, i)
          f.killed = f.killed + 1
          for slot = 1, 12 do
            local it = t.inv[slot]
            if it and it.name == "minecraft:ender_pearl" then it.count = it.count + 1 break end
            if not it then t.inv[slot] = { name = "minecraft:ender_pearl", count = 1 } break end
          end
        end
        return true
      end
    end
    return false
  end
  return f
end

local function inv(f, name)
  local n = 0
  for slot = 1, 16 do
    local it = f.t.inv[slot]
    if it and it.name == name then n = n + it.count end
  end
  return n
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

print("Makes End cores one after another, the next Weak core into slot 16")
do
  local spawn = {}
  local spots = { { 3, 0, 4 }, { -5, 0, 2 }, { 6, 0, -6 }, { 0, 0, 7 }, { -7, 0, -3 },
    { 2, 0, -1 }, { 7, 0, 7 }, { -2, 0, 5 }, { 4, 0, 0 }, { -6, 0, -7 }, { 1, 0, 3 }, { 5, 0, 5 } }
  for _, s in ipairs(spots) do spawn[#spawn + 1] = s end
  local f = setup({ spawn = spawn, inventory = { { DETECTOR, 1 }, { CORE, 1 }, { CORE, 1 }, { "minecraft:coal", 32 } } })
  local ok, res, log = run(f, "north")
  check(not ok and res == "STUCK_SLEEPING", "keeps going until stopped (" .. tostring(res) .. ")")
  check(f.fed == 12, "fed every vanilla one (" .. f.fed .. ")")
  check(inv(f, END_CORE) == 1, "one End core made, in the inventory (" .. inv(f, END_CORE) .. ")")
  check(f.t.inv[16] and f.t.inv[16].name == CORE and f.t.inv[16].fed == 2, "the next Weak core in slot 16, fed twice")
  check(f.t.left == CONTROLLER, "the chunk controller never off")
  check(f.t.inv[13] and f.t.inv[13].name == DETECTOR or f.t.right == DETECTOR, "the detector in its slot or on")
  check(log:find("Made End Automata Core 1", 1, true) ~= nil, "says so")
end

print("Kills End Endermen with its sword, feeds the vanilla ones")
do
  local f = setup({ others = { { 3, 0, 2 }, { -4, 0, 1 } }, spawn = { { 2, 0, -3 } },
    inventory = { { DETECTOR, 1 }, { CORE, 1 }, { "minecraft:diamond_sword", 1 }, { "minecraft:coal", 32 } } })
  run(f, "north")
  check(f.killed == 2, "killed both End Endermen (" .. f.killed .. ")")
  check(inv(f, "minecraft:ender_pearl") == 2, "kept their pearls")
  check(f.fed == 1, "fed the vanilla one (" .. f.fed .. ")")
end

print("With no core to feed, the sword takes vanilla ones too")
do
  local f = setup({ right = CORE, others = {}, inventory = { { DETECTOR, 1 }, { "minecraft:diamond_sword", 1 } } })
  f.others = {}
  -- No Weak core in slot 16 or waiting: everything gets the sword.
  f.endermen = {}
  table.insert(f.others, { x = 3, y = 0, z = 3, hp = 3 })
  run(f, "north")
  check(f.killed == 1, "killed it (" .. f.killed .. ")")
end

print("Burns its coal when it starts empty")
do
  local f = setup({ fuel = 0, spawn = { { 3, 0, 0 } } })
  run(f, "north")
  check(f.fed == 1, "fed one on coal it carried (" .. f.fed .. ")")
  check(f.t.fuel > 0, "has fuel (" .. f.t.fuel .. ")")
end

print("Finds its own facing (auto)")
do
  -- Set down facing north (nav +z), with the detector on and both cores loose.
  local f = setup({ right = DETECTOR, inventory = { { CORE, 1 }, { CORE, 1 }, { "minecraft:coal", 32 } },
    spawn = { { 2, 0, 3 } } })
  local ok, res, log = run(f, "auto")
  check(log:find("I face north", 1, true) ~= nil, "says north (" .. tostring(res) .. ") " .. log:sub(1, 300))
  check(f.fed == 1, "and feeds (" .. f.fed .. ")")
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

print("Needs its own core and a facing")
do
  local f = setup({ right = DETECTOR, inventory = {} })
  local ok, res = run(f, "north")
  check(not ok and tostring(res):find("of my own", 1, true) ~= nil, "asks for its core (" .. tostring(res) .. ")")
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
