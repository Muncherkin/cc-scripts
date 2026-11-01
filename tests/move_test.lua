-- Offline tests for programs/lib/move.lua. Run with: npm test
--
-- The simulator's coordinates are nav's: born on the birth spot facing
-- north, nav +z is north. World = (O.x + x, O.y + y, O.z - z) with O the
-- birth spot. The tests' working frame is the world less O (offset = O), so
-- a working cell (x, y, z) is the simulator's (x, y, -z).
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local O = { x = 3559, y = 74, z = 4762 }
local STONE = { name = "minecraft:stone" }
local MACHINE = { name = "computercraft:turtle_normal" }

-- Every test program starts like this; G holds what the test hands it.
local PRE = [[
local move = require("lib.move")
local saved = require("lib.state")
local state = saved.load("/.s") or {}
local function save() saved.save("/.s", state) end
local opts = { offset = G.O, fuel = { ["minecraft:coal"] = true } }
for k, v in pairs(G.opts or {}) do opts[k] = v end
move.init(state, save, opts)
local key = move.key
]]

-- solid: "stone" for a world of stone, else open air. g: what the program
-- gets as G.
local function setup(opts)
  opts = opts or {}
  local world = sim.newWorld(function() if opts.solid == "stone" then return STONE end end)
  local f = { world = world, sleeps = 0, g = opts.g or {} }
  f.g.O = O
  f.t = sim.newTurtle(world, { fuel = opts.fuel or 1000, inventory = opts.inventory or {} })
  f.computer = sim.newComputer()
  f.computer.queued = {}
  f.computer.globals = { G = f.g }
  f.computer.sleep = function(s)
    f.sleeps = f.sleeps + 1
    if opts.onSleep then opts.onSleep(f, s) end
    if f.sleeps > 5000 then error("STUCK_SLEEPING", 0) end
  end
  -- The simulator cell of a working-frame cell.
  function f.cell(x, y, z) return x, y, -z end
  function f.at(x, y, z)
    local b = world.get(f.cell(x, y, z))
    return b and b.name
  end
  function f.run(src, ...)
    local log = {}
    local ok, res = sim.runSource(PRE .. src, f.t, f.computer, log, ...)
    return ok, res, table.concat(log, "\n")
  end
  return f
end

-- Cells in a set, working frame.
local function cellSet(list)
  local s = {}
  for _, c in ipairs(list) do s[c[1] .. "," .. c[2] .. "," .. c[3]] = true end
  return s
end
local function line(x0, z0, x1, z1, y, into)
  into = into or {}
  for x = math.min(x0, x1), math.max(x0, x1) do
    for z = math.min(z0, z1), math.max(z0, z1) do into[#into + 1] = { x, y or 0, z } end
  end
  return into
end

print("Knows where it is in world coordinates, through reboots")
do
  local f = setup()
  local src = [[
    move.flyTo(G.O.x + 3, G.O.z - 2, G.O.y + 2)
    print("at " .. key(move.world()) .. " here " .. key(move.here()))
  ]]
  f.t.crashAt = 4
  local ok, res = f.run(src)
  check(res == "SIMULATED_REBOOT", "stopped partway (" .. tostring(res) .. ")")
  local log
  ok, res, log = f.run(src)
  check(ok, "finishes after the reboot (" .. tostring(res) .. ")")
  check(log:find(("at %d,%d,%d here 3,2,-2"):format(O.x + 3, O.y + 2, O.z - 2), 1, true) ~= nil, "world and working frame right (" .. log .. ")")
  check(f.t.x == 3 and f.t.y == 2 and f.t.z == 2, "and really there (" .. f.t.x .. "," .. f.t.y .. "," .. f.t.z .. ")")
  check(f.t.moves == 7, "no move wasted (" .. f.t.moves .. ")")
end

print("Plans through known cells and digs only them")
do
  -- An L of cells north, then east, in solid stone.
  local f = setup({ solid = "stone", g = { cells = cellSet(line(0, 0, 0, -4, 0, line(1, -4, 4, -4))) } })
  local ok, res, log = f.run([[
    move.configure({ cells = function() return G.cells end })
    move.goTo({ x = 4, y = 0, z = -4 }, { dig = true })
    print("at " .. key(move.here()))
  ]])
  check(ok, "finishes (" .. tostring(res) .. ")")
  check(log:find("at 4,0,-4", 1, true) ~= nil, "got there")
  local extra = 0
  for k, b in pairs(f.world.blocks) do
    if b == false then
      local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
      if not f.g.cells[x .. "," .. y .. "," .. (-tonumber(z))] then extra = extra + 1 end
    end
  end
  check(extra == 0, "dug nothing outside the cells (" .. extra .. ")")
  check(f.t.moves == 8, "the short way (" .. f.t.moves .. " moves)")
end

print("Not told it may dig: refuses rather than digging")
do
  local f = setup({ solid = "stone", g = { cells = cellSet(line(0, -1, 0, -3)) } })
  local ok, res = f.run([[
    move.configure({ cells = function() return G.cells end })
    move.goTo({ x = 0, y = 0, z = -3 })
  ]])
  check(not ok and tostring(res):find("No way", 1, true), "says there's no way (" .. tostring(res) .. ")")
  check(f.at(0, 0, -1) == "minecraft:stone", "dug nothing")
end

print("Steps round a turtle that stays in the way")
do
  local f = setup({ g = { cells = cellSet(line(0, 0, 1, -6)) } })
  f.world.set(f.cell(0, 0, -3)) -- (clears it first, then the turtle)
  local x, y, z = f.cell(0, 0, -3)
  f.world.set(x, y, z, MACHINE)
  local ok, res, log = f.run([[
    move.configure({ cells = function() return G.cells end })
    move.goTo({ x = 0, y = 0, z = -6 }, { dig = true })
    print("at " .. key(move.here()))
  ]])
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Stepping round another turtle", 1, true) ~= nil, "says so")
  check(log:find("at 0,0,-6", 1, true) ~= nil, "got there")
  check(f.at(0, 0, -3) == MACHINE.name, "never dug the turtle")
end

print("One-way lanes: paths inside them only go their way")
do
  -- Two columns side by side; x 0 is one-way north.
  local f = setup({ g = { cells = cellSet(line(0, 0, 1, -3)) } })
  local ok, res, log = f.run([[
    move.configure({ cells = function() return G.cells end,
      lanes = { { name = "up lane", oneWay = "n", contains = function(p) return p.x == 0 end } } })
    print("north " .. table.concat(move.path({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -3 }), ""))
    print("south " .. table.concat(move.path({ x = 0, y = 0, z = -3 }, { x = 0, y = 0, z = 0 }), ""))
  ]])
  check(ok, "runs (" .. tostring(res) .. ")")
  check(log:find("north nnn", 1, true) ~= nil, "straight up the lane its way (" .. log .. ")")
  local south = log:match("south (%a+)") or ""
  check(south:sub(1, 1) == "e", "out of the lane first (" .. south .. ")")
  check(#south == 5 and south:sub(-1) == "w", "down the other column and back in (" .. south .. ")")
end

print("Open air above the surface counts as passable")
do
  local f = setup()
  local ok, res, log = f.run([[
    move.configure({ air = G.O.y + 5 })
    local over = move.path({ x = 0, y = 5, z = 0 }, { x = 6, y = 5, z = 0 })
    local under = move.path({ x = 0, y = 4, z = 0 }, { x = 6, y = 4, z = 0 })
    print("over " .. (over and table.concat(over, "") or "none") .. " under " .. (under and table.concat(under, "") or "none"))
  ]])
  check(ok, "runs (" .. tostring(res) .. ")")
  check(log:find("over eeeeee", 1, true) ~= nil, "straight across in the air (" .. log .. ")")
  local under = log:match("under (%a+)") or ""
  check(under ~= "none" and under:sub(1, 1) == "u" and under:sub(-1) == "d", "below it, up into the air and down at the end (" .. under .. ")")
end

print("Worst-case cost home by the birth spot's station")
do
  local f = setup()
  f.t.x, f.t.y, f.t.z = 10, -5, 20
  f.computer.files["/.s"] = "{ pos = { x = 10, y = -5, z = 20 }, dir = 0 }"
  local ok, res, log = f.run([[ print("cost " .. move.homeCost()) ]])
  check(ok, "runs (" .. tostring(res) .. ")")
  -- 1.5 x 30 across, 11 up to cruise height 80, 6 down to the station, 2 x 3
  -- for its lane, 100 margin.
  check(log:find("cost 168", 1, true) ~= nil, "168 (" .. log .. ")")
end

print("Won't set out without the fuel to get back")
do
  local f = setup({ fuel = 30, g = { cells = cellSet(line(0, 0, 0, -20)) } })
  local ok, res, log = f.run([[
    move.configure({ cells = function() return G.cells end })
    print("result " .. tostring(select(2, move.goTo({ x = 0, y = 0, z = -20 }, { dig = true }))))
  ]])
  check(ok, "runs (" .. tostring(res) .. ")")
  check(log:find("result short of fuel", 1, true) ~= nil, "refuses (" .. log .. ")")
  check(f.t.moves == 0, "and stays put")
end

print("Short of fuel with a way to get some: fetches it first")
do
  local f = setup({ fuel = 30, inventory = { { "minecraft:coal", 1 } }, g = { cells = cellSet(line(0, 0, 0, -20)) } })
  f.g.fetch = function() f.t.fuel = f.t.fuel + 1000 end
  local ok, res, log = f.run([[
    move.configure({ cells = function() return G.cells end,
      onShort = function(need) print("fetching " .. need) G.fetch() end })
    move.goTo({ x = 0, y = 0, z = -20 }, { dig = true })
    print("at " .. key(move.here()))
  ]])
  check(ok, "finishes (" .. tostring(res) .. ")")
  check(f.t.inv[1] == nil, "burnt the coal it carried first")
  local n = select(2, log:gsub("fetching", ""))
  check(n == 1, "fetched fuel once (" .. log .. ")")
  check(log:find("at 0,0,-20", 1, true) ~= nil, "then went")
end

print("Run dry: waits and calls for help, carries on when fuel comes")
do
  local f = setup({ fuel = 3, onSleep = function(ff)
    if ff.sleeps == 3 then ff.t.addItem("minecraft:coal", 2) end
  end })
  f.computer.label = "Digby"
  local ok, res, log = f.run([[
    move.flyTo(G.O.x + 8, G.O.z, G.O.y)
    print("at " .. key(move.here()))
  ]])
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("Out of fuel at", 1, true) ~= nil, "says it's out")
  local called = false
  for _, e in ipairs(f.computer.queued) do
    if e[1] == "bridge_send" and tostring(e[2].text):find("Digby is out of fuel", 1, true) then called = true end
  end
  check(called, "called for help over the bridge")
  check(log:find("at 8,0,0", 1, true) ~= nil, "and got there")
end

print("Into the fuel station by its lane, giving way to a turtle leaving")
do
  local f = setup({ onSleep = function(ff)
    if ff.sleeps == 4 then ff.world.set(0, 0, 2, nil) end
  end })
  f.world.set(0, 0, 2, MACHINE) -- leaving, in the lane
  f.t.x, f.t.z = 6, 10
  f.computer.files["/.s"] = "{ pos = { x = 6, y = 0, z = 10 }, dir = 0 }"
  local ok, res, log = f.run([[ move.intoStation("birth") ]])
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(log:find("making way", 1, true) ~= nil, "made way")
  check(f.t.x == 0 and f.t.y == 0 and f.t.z == 0, ("on the station (%d,%d,%d)"):format(f.t.x, f.t.y, f.t.z))
end

print("Asks the occupancy service before every cell")
do
  local f = setup({ g = { cells = cellSet(line(0, 0, 0, -3)), claims = {}, releases = {}, refused = 0 } })
  local g = f.g
  g.svc = {
    claim = function(k)
      g.claims[#g.claims + 1] = k
      -- The second cell north is someone else's for a while.
      if k == ("%d,%d,%d"):format(O.x, O.y, O.z - 2) and g.refused < 2 then g.refused = g.refused + 1 return false end
      return true
    end,
    release = function(k) g.releases[#g.releases + 1] = k end,
    taken = function() return false end,
  }
  local ok, res, log = f.run([[
    move.setOccupancy(G.svc)
    move.configure({ cells = function() return G.cells end })
    move.goTo({ x = 0, y = 0, z = -3 }, { dig = true })
  ]])
  check(ok, "finishes (" .. tostring(res) .. ")\n" .. log)
  check(g.refused == 2 and log:find("to come free", 1, true) ~= nil, "waited for the held cell")
  check(#g.releases == 3 and g.releases[1] == ("%d,%d,%d"):format(O.x, O.y, O.z), "released each cell it left")
  check(f.t.z == 3, "got there")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll move tests passed")
