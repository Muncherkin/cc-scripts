-- Offline tests for programs/relocate.lua (the factory turtle flies herself
-- into the Engine Hall). Run with: npm test
--
-- The simulator's coordinates are her nav frame: she starts at the surface
-- factory facing north, nav +z north, +x east.
-- World (x, y, z) = (O.x + nx, O.y + ny, O.z - nz).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")
local home = require("lib.home")

local PROGRAM = "programs/relocate.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

sim.BLOCKS["minecraft:barrel"] = { drop = "minecraft:barrel", container = true }
sim.BLOCKS["computercraft:wired_modem_full"] = { drop = "computercraft:wired_modem_full" }
sim.BLOCKS["minecraft:furnace"] = { drop = "minecraft:furnace" }
sim.BLOCKS["computercraft:disk_drive"] = { drop = "computercraft:disk_drive", container = true }

local STONE = { name = "minecraft:stone" }
local MACHINE = { name = "computercraft:turtle_normal" }
local O, H, S, L = home.surface, home.hall, home.shaft, home.lift

local function N(x, y, z) return x - O.x, y - O.y, O.z - z end
local function k(x, y, z) return x .. "," .. y .. "," .. z end
local function put(world, w, b) local x, y, z = N(w[1], w[2], w[3]) world.set(x, y, z, b) end

-- The hall factory built (lib/home.build), the shaft and the hall open, the
-- surface factory around her: chests above and below, Pebbles on top, the
-- drive under the birth spot, furnaces and chests behind her.
local function setup(opts)
  opts = opts or {}
  local layout = {}
  for _, c in ipairs(home.build(H)) do layout[k(c.x, c.y, c.z)] = c.item end
  local world = sim.newWorld(function(nx, ny, nz)
    local x, y, z = O.x + nx, O.y + ny, O.z - nz
    if layout[k(x, y, z)] then return { name = layout[k(x, y, z)] } end
    if y >= O.y then return nil end
    if x == S.x and z == S.z and y >= S.foot then return nil end
    local sx, sy, sz = x - L.x, y - L.y, z - L.z
    if math.abs(sx) <= 24 and math.abs(sz) <= 24 and sy >= -14 and sy <= 8 then return nil end
    return STONE
  end)
  put(world, {O.x, O.y + 1, O.z}, { name = "minecraft:chest" })
  put(world, {O.x, O.y + 2, O.z}, MACHINE) -- Pebbles
  put(world, {O.x, O.y - 1, O.z}, { name = "minecraft:chest" })
  put(world, {O.x, O.y - 1, O.z - 1}, { name = "computercraft:disk_drive" })
  put(world, {O.x + 1, O.y, O.z}, { name = "computercraft:wired_modem_full" })
  put(world, {O.x, O.y, O.z + 1}, { name = "minecraft:furnace" })
  for _, c in ipairs(opts.extra or {}) do put(world, {c[1], c[2], c[3]}, c[4]) end
  local f = { world = world, sleeps = 0 }
  f.t = sim.newTurtle(world, { fuel = opts.fuel or 318, inventory = opts.inventory or {} })
  f.computer = sim.newComputer()
  f.computer.label = "Forgemother"
  if opts.evacuated ~= false then f.computer.files["/.factory/evacuate"] = "{ caps = {}, moved = {}, done = true }" end
  f.computer.sleep = function()
    f.sleeps = f.sleeps + 1
    if f.sleeps > 5000 then error("STUCK_SLEEPING", 0) end
    if opts.onSleep then opts.onSleep(f) end
  end
  function f.at() return O.x + f.t.x, O.y + f.t.y, O.z - f.t.z end
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

print("Flies herself down into her place in the hall")
do
  local f = setup()
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  local x, y, z = f.at()
  check(x == H.x and y == H.y and z == H.z, ("in her place (%d %d %d)"):format(x, y, z))
  check(f.t.dir == 0, "facing north")
  local inChest = f.world.get(N(H.x, H.y + 1, H.z))
  local outChest = f.world.get(N(H.x, H.y - 1, H.z))
  check(inChest and inChest.name == "minecraft:barrel" and outChest and outChest.name == "minecraft:chest",
    "between the hall's input and output chests")
  check(f.t.fuel > 0, "with fuel to spare (" .. f.t.fuel .. ")")
  check(log:find("In the hall at", 1, true) ~= nil, "says so")
end

print("Waits for the evacuation")
do
  local f = setup({ evacuated = false })
  local ok, res = run(f)
  check(not ok and tostring(res):find("evacuation", 1, true) ~= nil, "won't leave before it's done (" .. tostring(res) .. ")")
  check(f.t.x == 0 and f.t.y == 0 and f.t.z == 0, "and stays put")
end

print("Burns coal she carries when she's low")
do
  local f = setup({ fuel = 20, inventory = { { "minecraft:coal", 4 } } })
  local ok, res = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")")
  local x, y, z = f.at()
  check(x == H.x and y == H.y and z == H.z, "in her place")
end

print("Waits for a turtle on the hall's birth spot")
do
  local B = home.places(H).station
  local f = setup({ extra = { { B.x, B.y, B.z, MACHINE } }, onSleep = function(g)
    if g.sleeps == 6 then put(g.world, {B.x, B.y, B.z}, nil) end
  end })
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-300))
  local x, y, z = f.at()
  check(x == H.x and y == H.y and z == H.z, "in her place once it has gone")
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("All passed")
