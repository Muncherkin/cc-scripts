-- Offline tests for programs/builder.lua on the generated blueprints and a
-- small room with a rock ceiling and lamps in its rock walls.
-- Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- Builds blueprint source `src` in solid stone. The turtle starts at the
-- blueprint's home facing in.
-- Plain mode: what a cell's block becomes (nil: left open).
local function plainOf(id)
  if id:find("^factory_blocks:") then return "factory_blocks:factory" end
  if id == "create:andesite_bars" then return nil end
  return id
end

local function build(name, src, plain, prep)
  local bp = assert(load(src, "=" .. name, "t", {}))()
  bp.plain = plain
  local h = bp.home
  -- The turtle's frame: forward is the home's facing, right is Minecraft's
  -- right of it. The sim's x axis is the turtle's right, z its forward.
  local f = ({ n = { 0, -1 }, s = { 0, 1 }, e = { 1, 0 }, w = { -1, 0 } })[h.face]
  local right = { -f[2], f[1] }
  local function W(x, y, z)
    local dx, dz = x - h.x, z - h.z
    return dx * right[1] + dz * right[2], y - h.y, dx * f[1] + dz * f[2]
  end

  local world = sim.newWorld(function() return { name = "minecraft:stone" } end)
  for _, id in pairs(bp.palette) do
    if not sim.BLOCKS[id] then sim.BLOCKS[id] = { drop = id } end
  end
  world.set(W(h.x, h.y, h.z))
  local sx, sy, sz = W(h.x, h.y - 1, h.z)
  world.set(sx, sy, sz, { name = "minecraft:chest" })
  local ux, uy, uz = W(h.x, h.y + 1, h.z)           -- the staging chest above home
  world.set(ux, uy, uz, { name = "minecraft:chest" })
  world.containers[ux .. "," .. uy .. "," .. uz] = {}
  local supply = {}
  local need = {}
  for y = 1, bp.size.y do
    for z = 1, bp.size.z do
      local row = bp.layers[y][z]
      for x = 1, #row do
        local id = bp.palette[row:sub(x, x)]
        if id and plain then id = plainOf(id) end
        if id and id ~= "minecraft:air" then need[id] = (need[id] or 0) + 1 end
      end
    end
  end
  for id, n in pairs(need) do
    while n > 0 do
      supply[#supply + 1] = { name = id, count = math.min(64, n) }
      n = n - 64
    end
  end
  for _ = 1, 12 do supply[#supply + 1] = { name = "minecraft:charcoal", count = 64 } end
  world.containers[sx .. "," .. sy .. "," .. sz] = supply

  if prep then prep(world, W) end
  local t = sim.newTurtle(world, { fuel = 0, right = "minecraft:diamond_pickaxe" })
  local computer = sim.newComputer()
  computer.peripheral = sim.sidePeripherals(world, t)
  computer.files["/blueprints/" .. name .. ".lua"] = src
  computer.sleep = function() error("WAITED", 0) end -- running out of supply would be a bug here
  local log = {}
  sim.BLOCKS["factory_blocks:factory"] = sim.BLOCKS["factory_blocks:factory"] or { drop = "factory_blocks:factory" }
  local ok, res = sim.run("programs/builder.lua", t, computer, log, name, plain and "plain" or nil)
  return {
    ok = ok, res = res, log = table.concat(log, "\n"), t = t, world = world, bp = bp, W = W,
    fuelUsed = 12 * 64 * 80 - t.fuel - 80 * (function()
      local left = 0
      for _, it in ipairs(supply) do if it.name == "minecraft:charcoal" then left = left + it.count end end
      for s = 1, 16 do
        local it = t.inv[s]
        if it and it.name == "minecraft:charcoal" then left = left + it.count end
      end
      return left
    end)(),
  }
end

local function verify(r, label, allowCrawl)
  local bp, world, W = r.bp, r.world, r.W
  local wrong, dug, sample = 0, 0, nil
  for y = 0, bp.size.y - 1 do
    for z = 0, bp.size.z - 1 do
      local row = bp.layers[y + 1][z + 1]
      for x = 0, bp.size.x - 1 do
        local ch = row:sub(x + 1, x + 1)
        local b = world.get(W(x, y, z))
        local got = b and b.name
        if ch == " " then
          if got ~= "minecraft:stone" then dug = dug + 1 end
        else
          local want = bp.palette[ch]
          if want and bp.plain then want = plainOf(want) end
          if want == "minecraft:air" then want = nil end
          if got ~= want then
            wrong = wrong + 1
            sample = sample or ("%d,%d,%d wants %s has %s"):format(x, y, z, tostring(want), tostring(got))
          end
        end
      end
    end
  end
  -- Above the blueprint only crawlspace may be dug.
  local above = 0
  for z = 0, bp.size.z - 1 do
    for x = 0, bp.size.x - 1 do
      local b = r.world.get(W(x, bp.size.y, z))
      if not b then above = above + 1 end
    end
  end
  check(r.ok and r.log:find("Built", 1, true), label .. ": finishes (" .. tostring(r.res) .. ")")
  check(wrong == 0, label .. ": every cell as designed (" .. wrong .. " wrong" .. (sample and ", e.g. " .. sample or "") .. ")")
  check(dug == 0, label .. ": rock to keep left alone (" .. dug .. " dug)")
  check(above <= (allowCrawl or 0), label .. ": crawlspace above the roof (" .. above .. " cells, allowed " .. (allowCrawl or 0) .. ")")
  check(r.t.x == 0 and r.t.y == 0 and r.t.z == 0, label .. ": back home")
  print(("        fuel used: %d"):format(r.fuelUsed))
end

-- A small room: rock ceiling (keep), lamps set into the rock walls, a floor,
-- and a doorway on the north side with home outside it.
local ROOM = [[
return {
  name = "room", title = "Test room",
  size = { x = 7, y = 5, z = 7 },
  home = { x = 3, y = 1, z = -1, face = "s" },
  palette = { ["."] = "minecraft:air", F = "factory_blocks:large_plating", L = "minecraft:verdant_froglight", G = "factory_blocks:grate" },
  layers = {
    { "       ", " FFFFF ", " FFFFF ", " FFFFF ", " FFFFF ", " FFFFF ", "       " },
    { "   .   ", " ..... ", "L.....L", " ..... ", " ..... ", " ..... ", "       " },
    { "   .   ", " ..... ", " ..... ", " ..... ", " ..G.. ", " ..... ", "       " },
    { "       ", " ..... ", " ..... ", " ..... ", " ..... ", " ..... ", "       " },
    { "       ", "  L    ", "       ", "       ", "    L  ", "       ", "       " },
  },
}
]]

print("A room with a rock ceiling and lamps in its walls")
verify(build("room", ROOM), "room", 0)

for _, name in ipairs({ "core", "construct", "archive", "hq", "stack" }) do
  print("Generated blueprint: " .. name)
  local src = readfile("programs/blueprints/" .. name .. ".lua")
  local r = build(name, src)
  -- Roofs go in sideways and from below: no crawlspace anywhere.
  verify(r, name, 0)
end

-- Builds `src` with no chests: the turtle carries what it works with and
-- goes to a loading bay for more, three cells over its home (routes u3 and
-- d3). Standing there it's filled, 12 stacks a visit, as the factory would,
-- from `stock` (default: all the blueprint needs). `late`: visits at which
-- an item first becomes available, to try its patience.
-- opts.kit: the bay as in the hall, off the column (routes u4n1d1 and
-- u1s1d4) with a disk drive under it and its wired modem to the east.
-- opts.twist: the turtle is knocked half round just as it gets there, as a
-- turn lost to a restart would leave it; the bay must set it right.
local function buildFromBay(name, src, plain, late, opts)
  opts = opts or {}
  local bp = assert(load(src, "=" .. name, "t", {}))()
  bp.plain = plain
  local h = bp.home
  local f = ({ n = { 0, -1 }, s = { 0, 1 }, e = { 1, 0 }, w = { -1, 0 } })[h.face]
  local right = { -f[2], f[1] }
  local function W(x, y, z)
    local dx, dz = x - h.x, z - h.z
    return dx * right[1] + dz * right[2], y - h.y, dx * f[1] + dz * f[2]
  end
  local world = sim.newWorld(function() return { name = "minecraft:stone" } end)
  for _, id in pairs(bp.palette) do
    if not sim.BLOCKS[id] then sim.BLOCKS[id] = { drop = id } end
  end
  sim.BLOCKS["factory_blocks:factory"] = sim.BLOCKS["factory_blocks:factory"] or { drop = "factory_blocks:factory" }
  for up = 0, 3 do world.set(0, up, 0) end
  local bay = { x = 0, y = 3, z = 0 }
  local back, out = "u3", "d3"
  if opts.kit then
    local NORTH = (4 - ({ n = 0, e = 1, s = 2, w = 3 })[h.face]) % 4
    local DX, DZ = { [0] = 0, 1, 0, -1 }, { [0] = 1, 0, -1, 0 }
    bay = { x = DX[NORTH], y = 3, z = DZ[NORTH] }
    back, out = "u4n1d1", "u1s1d4"
    world.set(0, 4, 0)
    world.set(bay.x, 4, bay.z)
    world.set(bay.x, 3, bay.z)
    sim.BLOCKS["computercraft:disk_drive"] = sim.BLOCKS["computercraft:disk_drive"] or { drop = "computercraft:disk_drive" }
    sim.BLOCKS["computercraft:wired_modem_full"] = sim.BLOCKS["computercraft:wired_modem_full"] or { drop = "computercraft:wired_modem_full" }
    world.set(bay.x, 2, bay.z, { name = "computercraft:disk_drive" })
    local E = (NORTH + 1) % 4
    world.set(bay.x + DX[E], 3, bay.z + DZ[E], { name = "computercraft:wired_modem_full" })
  end
  local need = {}
  for y = 1, bp.size.y do
    for z = 1, bp.size.z do
      local row = bp.layers[y][z]
      for x = 1, #row do
        local id = bp.palette[row:sub(x, x)]
        if id and plain then id = plainOf(id) end
        if id and id ~= "minecraft:air" then need[id] = (need[id] or 0) + 1 end
      end
    end
  end
  local t = sim.newTurtle(world, { fuel = 2000, right = "minecraft:diamond_pickaxe" })
  local computer = sim.newComputer()
  computer.peripheral = sim.sidePeripherals(world, t)
  computer.files["/blueprints/" .. name .. ".lua"] = src
  local visits, wasThere = 0, false
  local twisted = false
  if opts.twist then
    local down = t.api.down
    t.api.down = function()
      local ok, why = down()
      if ok and not twisted and t.x == bay.x and t.y == bay.y and t.z == bay.z then
        t.dir, twisted = (t.dir + 2) % 4, true
      end
      return ok, why
    end
  end
  computer.sleep = function()
    local there = t.x == bay.x and t.y == bay.y and t.z == bay.z
    if there and not wasThere then
      visits = visits + 1
      local room = 12
      for s = 1, 16 do
        if not t.inv[s] and room > 0 then
          for id, n in pairs(need) do
            if n > 0 and visits >= ((late or {})[id] or 0) then
              local c = math.min(64, n)
              t.inv[s] = { name = id, count = c }
              need[id] = n - c
              room = room - 1
              break
            end
          end
        end
      end
      for s = 1, 16 do
        if not t.inv[s] then t.inv[s] = { name = "minecraft:coal", count = 16 } break end
      end
    end
    wasThere = there
  end
  local log = {}
  local args = { name, "out=" .. out, "back=" .. back }
  if plain then args[#args + 1] = "plain" end
  local ok, res = sim.run("programs/builder.lua", t, computer, log, table.unpack(args))
  return { ok = ok, res = res, log = table.concat(log, "\n"), t = t, world = world, bp = bp, W = W,
           visits = visits, fuelUsed = 0, twisted = twisted }
end

print("Supplied from the loading bay: no chests, it carries its blocks and goes back for more")
do
  local r = buildFromBay("room", ROOM)
  verify(r, "room from the bay", 0)
  check(r.visits >= 1, "it was loaded at the bay (" .. r.visits .. " visits)")
  local r2 = buildFromBay("construct", readfile("programs/blueprints/construct.lua"), true)
  verify(r2, "construct from the bay, plain", 0)
  check(r2.visits >= 1, "over several loads (" .. r2.visits .. " visits)")
  -- The factory is out of one block for a while: it asks again, and builds it all.
  local r3 = buildFromBay("room", ROOM, false, { ["minecraft:verdant_froglight"] = 3 })
  verify(r3, "room, with the lamps late", 0)
  -- The hall's bay: the disk drive under it says where it is.
  local r4 = buildFromBay("room", ROOM, false, nil, { kit = true })
  verify(r4, "room from a bay with a disk drive", 0)
  check(not r4.log:find("set right", 1, true) and not r4.log:find("No disk drive", 1, true),
    "nothing to set right when nothing went wrong")
  local r5 = buildFromBay("room", ROOM, false, nil, { kit = true, twist = true })
  check(r5.twisted, "the turtle was knocked half round in the bay")
  verify(r5, "room after a turn lost in the bay", 0)
  check(r5.log:find("facing set right", 1, true) ~= nil, "the bay set its facing right")
  check(r3.log:find("No minecraft:verdant_froglight to be had yet", 1, true) ~= nil and r3.visits >= 3,
    "it waited for the lamps and went back for them (" .. r3.visits .. " visits)")
end

print("Someone's things in the volume are left standing and built round")
do
  -- A machine where a floor block goes, a chest in the middle of the room,
  -- and a cable where air is wanted.
  local theirs = { { 2, 0, 2, "mekanism:crusher" }, { 3, 1, 3, "minecraft:chest" }, { 4, 2, 2, "mekanism:basic_universal_cable" } }
  for _, c in ipairs(theirs) do sim.BLOCKS[c[4]] = sim.BLOCKS[c[4]] or { drop = c[4] } end
  local r = build("room", ROOM, false, function(world, W)
    for _, c in ipairs(theirs) do
      local x, y, z = W(c[1], c[2], c[3])
      world.set(x, y, z, { name = c[4] })
    end
  end)
  check(r.ok and r.log:find("Built", 1, true) ~= nil, "finishes (" .. tostring(r.res) .. ")")
  local left = true
  for _, c in ipairs(theirs) do
    local b = r.world.get(r.W(c[1], c[2], c[3]))
    if not (b and b.name == c[4]) then left = false end
  end
  check(left, "the crusher, the chest and the cable are still there")
  check(r.log:find("Leaving mekanism:crusher", 1, true) ~= nil and r.log:find("3 cells left as they were", 1, true) ~= nil,
    "and it says what it left (" .. r.log:sub(-200) .. ")")
  local wrong = 0
  for y = 0, r.bp.size.y - 1 do
    for z = 0, r.bp.size.z - 1 do
      local row = r.bp.layers[y + 1][z + 1]
      for x = 0, r.bp.size.x - 1 do
        local ch = row:sub(x + 1, x + 1)
        local mine = true
        -- Theirs, and the floor right under the chest: it can't stand where the
        -- chest is, so what's under it stays as it was.
        for _, c in ipairs(theirs) do
          if c[1] == x and c[3] == z and (c[2] == y or (c[4] == "minecraft:chest" and c[2] == y + 1)) then mine = false end
        end
        if mine and ch ~= " " then
          local want = r.bp.palette[ch]
          if want == "minecraft:air" then want = nil end
          local b = r.world.get(r.W(x, y, z))
          if (b and b.name) ~= want then wrong = wrong + 1 print(("    wrong at %d,%d,%d: %s, wanted %s"):format(x, y, z, tostring(b and b.name), tostring(want))) end
        end
      end
    end
  end
  check(wrong == 0, "every other cell as designed (" .. wrong .. " wrong)")
end

for _, name in ipairs({ "construct", "core", "hydroponics" }) do
  print("Plain blocks only: " .. name)
  verify(build(name, readfile("programs/blueprints/" .. name .. ".lua"), true), name .. " plain", 0)
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll builder tests passed")
