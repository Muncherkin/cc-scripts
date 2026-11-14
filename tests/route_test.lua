-- Offline tests for programs/lib/route.lua. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- A program that walks a route with lib/nav and lib/route, keeping its
-- state in a file as a real one would.
local WALKER = [[
local nav = require("lib.nav")
local saved = require("lib.state")
local route = require("lib.route")
local text, north = ...
local state = saved.load("/.walk") or {}
nav.init(state, function() saved.save("/.walk", state) end)
nav.recover()
route.follow(nav, text, { north = tonumber(north) or 0, from = { x = 0, y = 0, z = 0 } })
local p = nav.pos()
return p.x .. "," .. p.y .. "," .. p.z
]]

local function walker(world, opts)
  local t = sim.newTurtle(world, opts or { fuel = 500 })
  local computer = sim.newComputer()
  return t, computer
end
local function walk(t, computer, ...)
  local log = {}
  local ok, res = sim.runSource(WALKER, t, computer, log, ...)
  return ok, res, table.concat(log, "\n")
end

print("Routes: parsing, cells and the way back")
do
  local env = sim.env(nil, sim.newComputer(), {})
  local route = env.require("lib.route")
  check(#route.ops("n1u20w22d18") == 61, "61 single steps")
  local c = route.finish("n2e3u1", { x = 0, y = 0, z = 0 }, 0)
  check(c.x == 3 and c.y == 1 and c.z == 2, "north is +z and east +x in a frame born facing north")
  c = route.finish("n2e3", { x = 0, y = 0, z = 0 }, 2)
  check(c.x == -3 and c.z == -2, "and turned about for a frame that faces south")
  check(route.reverse("n1u20w22") == "e22d20s1", "the reverse of a route")
end

print("Routes: walked through open air, never dug")
do
  local world = sim.newWorld(function() return nil end)
  local t, computer = walker(world)
  local ok, res = walk(t, computer, "n3u2e2d1")
  check(ok and res == "2,1,3", "ends where the route ends (" .. tostring(res) .. ")")
  -- Rock in the way is an error, not a hole.
  local world2 = sim.newWorld(function(x, y, z) if y == 0 and z == 2 then return { name = "minecraft:stone" } end end)
  local t2, c2 = walker(world2)
  local ok2, res2 = walk(t2, c2, "n3")
  check(not ok2 and tostring(res2):find("Blocked on my route at step 2 of 3", 1, true) ~= nil, "blocked by rock: says where (" .. tostring(res2) .. ")")
  check(world2.get(0, 0, 2) ~= nil, "and the rock still stands")
end

print("Routes: a turtle in the way is waited for; a reboot carries on")
do
  local world = sim.newWorld(function() return nil end)
  world.set(0, 0, 2, { name = "computercraft:turtle_normal" })
  local t, computer = walker(world)
  local waits = 0
  computer.sleep = function()
    waits = waits + 1
    if waits == 3 then world.set(0, 0, 2) end -- it moves on
  end
  local ok, res = walk(t, computer, "n4")
  check(ok and res == "0,0,4" and waits >= 3, "waits, then goes on (" .. tostring(res) .. ", " .. waits .. " waits)")
  -- Stopped half way: the next run goes on from where it stands.
  local world2 = sim.newWorld(function() return nil end)
  local t2, c2 = walker(world2)
  walk(t2, c2, "n2")
  local ok2, res2 = walk(t2, c2, "n2e3")
  check(ok2 and res2 == "3,0,2", "resumes a longer route from its position (" .. tostring(res2) .. ")")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll route tests passed")
