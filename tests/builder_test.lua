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
local function build(name, src)
  local bp = assert(load(src, "=" .. name, "t", {}))()
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

  local t = sim.newTurtle(world, { fuel = 0, right = "minecraft:diamond_pickaxe" })
  local computer = sim.newComputer()
  computer.peripheral = sim.sidePeripherals(world, t)
  computer.files["/blueprints/" .. name .. ".lua"] = src
  computer.sleep = function() error("WAITED", 0) end -- running out of supply would be a bug here
  local log = {}
  local ok, res = sim.run("programs/builder.lua", t, computer, log, name)
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

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll builder tests passed")
