-- Offline tests for programs/movestore.lua (the mover) and lib/way.lua.
-- Run with: npm test
--
-- The simulator's coordinates are the mover's nav frame: born on the
-- surface factory's birth spot, nav +z north, +x east.
-- World (x, y, z) = (O.x + nx, O.y + ny, O.z - 1 - nz).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")
local home = require("lib.home")
-- The move as it was: born at the surface factory, carrying to the hall.
home.at, home.factory, home.inHall = "surface", home.surface, false

local PROGRAM = "programs/movestore.lua"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

sim.BLOCKS["minecraft:barrel"] = { drop = "minecraft:barrel", container = true }
sim.BLOCKS["computercraft:wired_modem_full"] = { drop = "computercraft:wired_modem_full" }
sim.BLOCKS["minecraft:furnace"] = { drop = "minecraft:furnace" }
sim.BLOCKS["minecraft:chest"] = sim.BLOCKS["minecraft:chest"] or { drop = "minecraft:chest", container = true }
sim.BLOCKS["computercraft:disk_drive"] = { drop = "computercraft:disk_drive", container = true }

local STONE = { name = "minecraft:stone" }
local MACHINE = { name = "computercraft:turtle_normal" }
local O, H, S, L = home.surface, home.hall, home.shaft, home.lift

local function N(x, y, z) return x - O.x, y - O.y, O.z - 1 - z end
local function k(x, y, z) return x .. "," .. y .. "," .. z end

-- Stone below the surface but for the shaft and the hall; the hall empty
-- (the mover builds it from its kit), or with opts.built already built; the
-- surface factory south of the birth spot.
local function setup(opts)
  opts = opts or {}
  local layout = {}
  if opts.built then
    for _, c in ipairs(home.build(H)) do layout[k(c.x, c.y, c.z)] = c.item end
  end
  local world = sim.newWorld(function(nx, ny, nz)
    local x, y, z = O.x + nx, O.y + ny, O.z - 1 - nz
    if layout[k(x, y, z)] then return { name = layout[k(x, y, z)] } end
    if y >= O.y then return nil end
    if x == S.x and z == S.z and y >= S.foot then return nil end
    local sx, sy, sz = x - L.x, y - L.y, z - L.z
    if math.abs(sx) <= 24 and math.abs(sz) <= 24 and sy >= -14 and sy <= 8 then return nil end
    return STONE
  end)
  world.capacity = {}
  for _, c in ipairs(home.build(H)) do
    if c.what == "barrel" then world.capacity[k(N(c.x, c.y, c.z))] = opts.barrelStacks or 27 end
  end
  if opts.built then
    for _, c in ipairs(home.build(H)) do
      local nx, ny, nz = N(c.x, c.y, c.z)
      world.get(nx, ny, nz)
      world.containers[k(nx, ny, nz)] = {}
    end
  end
  world.set(0, 0, -1, MACHINE) -- the surface factory
  -- The drive under the birth spot, with the floppy in it.
  world.set(0, -1, 0, { name = "computercraft:disk_drive" })
  world.containers[k(0, -1, 0)] = { { name = "computercraft:disk", count = 1 } }
  local f = { world = world, sleeps = 0, loads = 0, stock = opts.stock or {} }
  local inventory = { { "minecraft:charcoal", 24 } }
  if not opts.built then
    for _, it in ipairs(home.kit(H)) do inventory[#inventory + 1] = { it[1], it[2] } end
  end
  f.t = sim.newTurtle(world, {
    fuel = 0, right = "minecraft:diamond_pickaxe", left = "advancedperipherals:chunk_controller",
    inventory = inventory,
  })
  f.computer = sim.newComputer()
  f.computer.modules = { ["lib.home"] = home }
  -- The factory: at the birth spot, up to 15 stacks a visit from its stock.
  f.computer.sleep = function()
    f.sleeps = f.sleeps + 1
    if f.sleeps > 40000 then error("STUCK_SLEEPING", 0) end
    if opts.onSleep then opts.onSleep(f) end
    if f.computer.label == "Mover" and f.t.x == 0 and f.t.y == 0 and f.t.z == 0 and #f.stock > 0 then
      local given = 0
      for slot = 1, 16 do
        if given < 15 and not f.t.inv[slot] and #f.stock > 0 then
          local it = table.remove(f.stock, 1)
          f.t.inv[slot] = { name = it[1], count = it[2] }
          given = given + 1
        end
      end
      if given > 0 then f.loads = f.loads + 1 end
    end
  end
  function f.barrels()
    local total, used = {}, 0
    for _, c in ipairs(home.build(H)) do
      if c.what == "barrel" then
        local items = world.containers[k(N(c.x, c.y, c.z))]
        if #items > 0 then used = used + 1 end
        for _, it in ipairs(items) do total[it.name] = (total[it.name] or 0) + it.count end
      end
    end
    return total, used
  end
  function f.built()
    for _, c in ipairs(home.build(H)) do
      local b = world.get(N(c.x, c.y, c.z))
      if not (b and b.name == c.item) then return false, c.what .. " at " .. k(c.x, c.y, c.z) end
    end
    return true
  end
  function f.world_()
    return O.x + f.t.x, O.y + f.t.y, O.z - 1 - f.t.z
  end
  return f
end

local function run(f, ...)
  local log = {}
  local ok, res = sim.run(PROGRAM, f.t, f.computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

print("Builds the hall factory, then carries the factory's stock down into its barrels")
do
  local stock = { { "minecraft:charcoal", 64 } }
  for i = 1, 40 do stock[#stock + 1] = { "mod:raw" .. (i % 12 + 1), 64 } end
  stock[#stock + 1] = { "minecraft:diamond", 17 }
  local want = {}
  for _, it in ipairs(stock) do want[it[1]] = (want[it[1]] or 0) + it[2] end
  local f = setup({ stock = stock })
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  check(f.computer.label == "Mover", "labels itself Mover")
  -- The first load shares the mover with its kit.
  check(f.loads == 4, "four loads of up to 15 stacks (" .. f.loads .. ")")
  local got, used = f.barrels()
  local missing = {}
  for name, n in pairs(want) do
    if name ~= "minecraft:charcoal" and (got[name] or 0) ~= n then missing[#missing + 1] = name .. " " .. (got[name] or 0) .. "/" .. n end
  end
  check(#missing == 0, "every stack is in the barrels (" .. table.concat(missing, ", ") .. ")")
  check(used == 2, "fills barrels in order, two used (" .. used .. ")")
  local built, what = f.built()
  check(built, "built the hall factory (" .. tostring(what) .. ")")
  local spare = {}
  for _, it in ipairs(home.kit(H)) do if (got[it[1]] or 0) > 0 then spare[#spare + 1] = it[1] end end
  check(#spare == 0, "used its whole kit (" .. table.concat(spare, ", ") .. ")")
  check(f.world.containers[k(N(H.x, H.y - 1, H.z - 1))][1] ~= nil, "put the floppy in the hall's drive")
  check(#f.world.containers[k(0, -1, 0)] == 0, "took it from the surface drive")
  local x, y, z = f.world_()
  check(x == H.x - 1 and y == H.y and z == H.z + 3, ("parks west of the furnaces (%d %d %d)"):format(x, y, z))
  check(log:find("All carried: 4 loads", 1, true) ~= nil, "says it's done")
  check(f.world.get(0, 0, -1) ~= nil, "the surface factory is still there")
end

print("Gives way in the shaft to a turtle coming down")
do
  local stock = {}
  for i = 1, 20 do stock[#stock + 1] = { "mod:raw" .. i, 10 } end
  local blocker, placed, cleared = nil, false, false
  local f
  f = setup({ stock = stock, onSleep = function(g)
    if placed and not cleared and g.sleeps - g.blockedAt > 40 then
      g.world.set(blocker[1], blocker[2], blocker[3], nil)
      cleared = true
    end
  end })
  -- On its first way back up, a turtle sits in the shaft above it a while.
  local up = f.t.api.up
  f.t.api.up = function()
    local x, y, z = O.x + f.t.x, O.y + f.t.y, O.z - 1 - f.t.z
    if not placed and x == S.x and z == S.z and y == 20 then
      blocker = { N(S.x, 40, S.z) }
      f.world.set(blocker[1], blocker[2], blocker[3], MACHINE)
      placed, f.blockedAt = true, f.sleeps
    end
    return up()
  end
  -- Only blocked going up: the stock arrives as two loads.
  local ok, res, log = run(f)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-400))
  check(placed and cleared, "met the turtle in the shaft")
  check(log:find("Giving way in the shaft", 1, true) ~= nil, "gave way")
  local got = f.barrels()
  check((got["mod:raw20"] or 0) == 10, "and still delivered both loads")
end

print("Waits for a turtle leaving the birth spot")
do
  -- Back on the surface from a trip: a turtle on the birth spot, then gone.
  local ok, res, log
  local g = setup({ built = true, stock = { { "mod:raw2", 64 } }, onSleep = function(g2)
    if g2.sleeps == 1 then g2.world.set(0, 0, 1, MACHINE) end
    if g2.sleeps == 25 then g2.world.set(0, 0, 1, nil) end
  end })
  -- Starts in the lane's mouth, north of the birth spot, phase "up".
  g.computer.label = "Mover"
  g.t.x, g.t.y, g.t.z = 0, 0, 3
  g.t.fuel = 2000
  g.computer.files["/.movestore"] = ('{ phase = "up", loads = 1, cell = 1, built = 99, dir = 2, origin = { x = %d, y = %d, z = %d }, to = { x = %d, y = %d, z = %d }, pos = { x = 0, y = 0, z = 3 } }')
    :format(O.x, O.y, O.z, H.x, H.y, H.z)
  g.t.dir = 2
  ok, res, log = run(g)
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log:sub(-300))
  check(log:find("making way", 1, true) ~= nil, "backed out of the lane for it")
  check((g.barrels()["mod:raw2"] or 0) == 64, "then got its load down")
end

print("lib/home: the hall layout")
do
  local seen, barrels, modems = {}, 0, 0
  local dup
  for _, c in ipairs(home.layout(H)) do
    local key = k(c.x, c.y, c.z)
    if seen[key] then dup = key end
    seen[key] = c.what
    if c.what == "barrel" then barrels = barrels + 1 end
    if c.what == "wired modem" then modems = modems + 1 end
  end
  check(not dup, "no two blocks in one cell (" .. tostring(dup) .. ")")
  check(barrels == 18 and modems == 10, ("18 barrels, 10 modems (%d, %d)"):format(barrels, modems))
  -- Every barrel and furnace touches exactly one wired modem: a second would
  -- show it twice on the network.
  local bad = {}
  local function modemAt(x, y, z) return seen[k(x, y, z)] == "wired modem" end
  for _, c in ipairs(home.layout(H)) do
    if c.what == "barrel" or c.what == "furnace" or c.what == "ender drawer" then
      local n = 0
      for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
        if modemAt(c.x + d[1], c.y + d[2], c.z + d[3]) then n = n + 1 end
      end
      if n ~= 1 then bad[#bad + 1] = c.what .. " " .. k(c.x, c.y, c.z) .. " touches " .. n end
    end
  end
  check(#bad == 0, "every barrel, furnace and the drawer on one modem (" .. table.concat(bad, "; ") .. ")")
  -- The input and output chests stay off the network.
  local P = home.places(H)
  check(not modemAt(H.x + 1, H.y + 1, H.z) and not modemAt(H.x + 1, H.y - 1, H.z), "input and output chests off the network")
  -- All of it in one chunk with the factory turtle (its chunk controller keeps it loaded).
  local cx, cz = math.floor(H.x / 16), math.floor(H.z / 16)
  local out = {}
  for _, c in ipairs(home.layout(H)) do
    if math.floor(c.x / 16) ~= cx or math.floor(c.z / 16) ~= cz then out[#out + 1] = k(c.x, c.y, c.z) end
  end
  check(#out == 0, "all in the factory's chunk (" .. table.concat(out, " ") .. ")")
  -- The ways in and out are open.
  local open = {}
  for _, c in ipairs({ P.station, P.stationOut, P.drop, P.dropIn, P.dropOut }) do
    if seen[k(c.x, c.y, c.z)] then open[#open + 1] = k(c.x, c.y, c.z) end
  end
  check(#open == 0, "lanes clear (" .. table.concat(open, " ") .. ")")
  local s = home.toSite(H)
  check(s.x == 22 and s.y == -13 and s.z == 10, "the factory at site 22 -13 10")
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("All passed")
