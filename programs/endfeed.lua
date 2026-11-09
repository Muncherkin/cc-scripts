-- End feeder: turns a Weak Automata Core into an End Automata Core by feeding
-- it 10 endermen (Advanced Peripherals). Set it down in the End where
-- endermen walk, on open ground, and leave it.
--
-- The turtle: a chunk controller on one side, a Weak Automata Core on the
-- other (that core gives it feedSoul). In its inventory: a second Weak
-- Automata Core, the one that gets fed (feedSoul feeds the core in the
-- turtle's hand, never the equipped one; it's kept in slot 16 so the two are
-- never mixed up), an Environment Detector, and fuel.
-- It swaps the detector in for the equipped core to look for endermen
-- (scanEntities, radius 8, free), flies up beside the nearest one, swaps the
-- core back and feeds it the enderman. The chunk controller stays on.
--
-- It never digs (it has no tool) and keeps within LEASH blocks of where it
-- was set down, at most 3 below and 8 above it. When the fed core has
-- turned into an End Automata Core it goes back to where it started and
-- equips it in place of the weak one, which goes into slot 16.
--
-- Usage: endfeed <facing>   which way it faces when set down: north, east,
--                           south or west (scans report world axes), or
--                           auto: it finds out itself (detector equipped);
--                           resumes after reboots
--        endfeed status

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.endfeed"
local SCAN = 8              -- wider scans cost fuel the detector refuses
local LEASH = 10            -- how far from its start it goes
local LOW, HIGH = -3, 8     -- how far below and above its start
local LOW_FUEL = 100

local CORE = "advancedperipherals:weak_automata_core"
local END_CORE = "advancedperipherals:end_automata_core"
local DETECTOR = "advancedperipherals:environment_detector"
local CONTROLLER = "advancedperipherals:chunk_controller"

local function fail(msg) error(msg, 0) end

local state = saved.load(STATE)
if ... == "status" then
  if not state then print("Not started") return end
  print(("Fed %d endermen; %s"):format(state.fed or 0, state.done and "done" or "feeding"))
  return
end

-- World directions as (x, z) steps.
local FACING = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
-- Which way it faces, from ground truth: the detector reports world axes,
-- so it scans, steps forward, scans again and sees which way everything
-- shifted (players and idle mobs barely move in 2 seconds; the median of
-- all of them is used). It steps back afterwards.
local function detectFacing()
  local side = (turtle.getEquippedLeft() or {}).name == "advancedperipherals:chunk_controller" and "right" or "left"
  local function scanNow()
    sleep(2.1)
    local ok, list = pcall(peripheral.call, side, "scanEntities", 8)
    local t = {}
    if ok and type(list) == "table" then
      for _, e in ipairs(list) do if e.uuid then t[e.uuid] = { e.x, e.z } end end
    end
    return t
  end
  if not peripheral.hasType(side, "environment_detector") then
    fail("auto needs the Environment Detector equipped opposite the chunk controller")
  end
  local function median(v)
    table.sort(v)
    return v[math.ceil(#v / 2)]
  end
  for _ = 1, 4 do
    if not turtle.detect() then
      local a = scanNow()
      if turtle.forward() then
        local b = scanNow()
        turtle.back()
        local dx, dz = {}, {}
        for id, p in pairs(a) do
          if b[id] then dx[#dx + 1], dz[#dz + 1] = b[id][1] - p[1], b[id][2] - p[2] end
        end
        if #dx > 0 then
          -- Stepping forward moves everything the other way.
          local mx, mz = -median(dx), -median(dz)
          if math.abs(mx) > math.abs(mz) then return mx > 0 and "east" or "west" end
          return mz > 0 and "south" or "north"
        end
      end
    end
    turtle.turnRight()
  end
  fail("Can't tell which way I face (no room to step, or nothing to see)")
end

if not state then
  local f = ...
  if f == "auto" then
    f = detectFacing()
    print("I face " .. f)
  end
  if not FACING[f or ""] then fail("Usage: endfeed <north|east|south|west|auto> (which way I face now)") end
  state = { facing = f, fed = 0 }
end
local function save() saved.save(STATE, state) end
nav.init(state, save)
nav.recover()
save()

-- nav counts from the start: +z the way it faced, +x to its right.
local FWD = FACING[state.facing]
local RIGHT = { -FWD[2], FWD[1] }
local function toNav(dx, dz) return dx * RIGHT[1] + dz * RIGHT[2], dx * FWD[1] + dz * FWD[2] end

---------------------------------------------------------------------------
-- Upgrades
---------------------------------------------------------------------------

local function equipped(side)
  local get = side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
  local d = get()
  return d and d.name
end

-- The side the chunk controller is on stays; the other takes turns.
local WORK
if equipped("left") == CONTROLLER then WORK = "right"
elseif equipped("right") == CONTROLLER then WORK = "left"
else fail("Equip a chunk controller: I can't stay loaded without one") end
local equipWork = WORK == "left" and turtle.equipLeft or turtle.equipRight

local FED = 16 -- the core being fed lives here

-- Finds `name` in slots 1-15.
local function find(name)
  for slot = 1, FED - 1 do
    local d = turtle.getItemDetail(slot)
    if d and d.name == name then return slot end
  end
end

-- Puts `name` on the work side (from slots 1-15) unless it's there; what
-- was on goes into that slot.
local function wear(name)
  if equipped(WORK) == name then return end
  local slot = find(name)
  if not slot then fail("No " .. name .. " to equip") end
  turtle.select(slot)
  if not equipWork() then fail("Can't equip " .. name) end
  turtle.select(1)
  for _ = 1, 10 do
    if peripheral.isPresent(WORK) then break end
    sleep(0.05)
  end
end

-- What's in slot 16: "weak" while it's being fed, "end" once it's done.
local function fedState()
  local d = turtle.getItemDetail(FED)
  if d and d.name == END_CORE then return "end" end
  if d and d.name == CORE then return "weak" end
end

-- First run: the core to feed goes into slot 16. With the detector
-- equipped, one core in slots 1-15 is the one that goes back on.
if not fedState() then
  if turtle.getItemCount(FED) > 0 then fail("Empty slot 16: the core to feed goes there") end
  local cores = {}
  for slot = 1, FED - 1 do
    local d = turtle.getItemDetail(slot)
    if d and d.name == CORE then cores[#cores + 1] = slot end
  end
  if #cores < (equipped(WORK) == CORE and 1 or 2) then
    fail("I need a second Weak Automata Core in my inventory to feed")
  end
  turtle.select(cores[#cores])
  turtle.transferTo(FED)
  turtle.select(1)
end
if equipped(WORK) ~= CORE and equipped(WORK) ~= DETECTOR then
  fail("Equip a Weak Automata Core opposite the chunk controller")
end
if not find(DETECTOR) and equipped(WORK) ~= DETECTOR then fail("I need an Environment Detector in my inventory") end

---------------------------------------------------------------------------
-- Moving
---------------------------------------------------------------------------

local function inLeash(p)
  return math.abs(p.x) <= LEASH and math.abs(p.z) <= LEASH and p.y >= LOW and p.y <= HIGH
end

local AHEAD = { [0] = { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } } -- nav dir -> (x, z)

-- One step; nothing is dug.
local function step(kind)
  local p = nav.pos()
  local nxt = { x = p.x, y = p.y, z = p.z }
  if kind == "up" then nxt.y = p.y + 1
  elseif kind == "down" then nxt.y = p.y - 1
  else
    local d = AHEAD[nav.dir()]
    nxt.x, nxt.z = p.x + d[1], p.z + d[2]
  end
  if not inLeash(nxt) then return false end
  return nav.move(kind)
end

-- Towards nav cell (x, y, z) along x, z, then y, going over what's in the
-- way. Returns true once there.
local function approach(x, y, z)
  -- Up to at least y first, then across, climbing over what's in the way
  -- (never down on the way), then straight down to y at the end.
  while nav.pos().y < y do
    if not step("up") then return false end
  end
  for _ = 1, 4 * (2 * LEASH + HIGH - LOW) do
    local p = nav.pos()
    if p.x == x and p.z == z then break end
    local moved = false
    if p.x ~= x then
      nav.face(x > p.x and 1 or 3)
      moved = step("forward")
    end
    if not moved and p.z ~= z then
      nav.face(z > p.z and 0 or 2)
      moved = step("forward")
    end
    if not moved and not step("up") then return false end
  end
  local p = nav.pos()
  if p.x ~= x or p.z ~= z then return false end
  while nav.pos().y > y do
    if not step("down") then return false end
  end
  return nav.pos().y == y
end

---------------------------------------------------------------------------
-- Looking and feeding
---------------------------------------------------------------------------

local lastScan = -math.huge

-- Endermen near by, nearest first: { x, y, z } in nav cells (their feet).
local function look()
  wear(DETECTOR)
  local wait = 2.05 - (os.clock() - lastScan)
  if wait > 0 then sleep(wait) end
  local ok, list = pcall(peripheral.call, WORK, "scanEntities", SCAN)
  lastScan = os.clock()
  if not ok or type(list) ~= "table" then return {} end
  local p, found = nav.pos(), {}
  for _, e in ipairs(list) do
    -- Only the vanilla one: the core takes no other (Enderman Overhaul's
    -- End Endermen walk the End too, and feeding them does nothing).
    if e.name == "minecraft:enderman" then
      local nx, nz = toNav(math.floor(e.x + 0.5), math.floor(e.z + 0.5))
      local c = { x = p.x + nx, y = p.y + math.floor(e.y + 0.5), z = p.z + nz }
      c.d = math.abs(c.x - p.x) + math.abs(c.y - p.y) + math.abs(c.z - p.z)
      found[#found + 1] = c
    end
  end
  table.sort(found, function(a, b) return a.d < b.d end)
  return found
end

-- Next to the enderman at nav cell c (on its level), facing it.
local function besides(c)
  -- From the cell south of it facing north, east of it facing west, ...,
  -- at its chest (an enderman is 3 tall), the nearest side first.
  local sides = { { 0, -1, 0 }, { 1, 0, 3 }, { 0, 1, 2 }, { -1, 0, 1 } }
  local p = nav.pos()
  table.sort(sides, function(a, b)
    return math.abs(c.x + a[1] - p.x) + math.abs(c.z + a[2] - p.z) < math.abs(c.x + b[1] - p.x) + math.abs(c.z + b[2] - p.z)
  end)
  for _, s in ipairs(sides) do
    local cell = { x = c.x + s[1], y = c.y + 1, z = c.z + s[2] }
    if inLeash(cell) and approach(cell.x, cell.y, cell.z) then
      nav.face(s[3])
      return true
    end
  end
  return false
end

local function feed()
  wear(CORE)
  turtle.select(FED)
  local ok, res, err = pcall(peripheral.call, WORK, "feedSoul")
  turtle.select(1)
  if ok and res then return true end
  return false, tostring(err or res)
end

local function home()
  approach(0, math.max(nav.pos().y, 0), 0)
  approach(0, 0, 0)
  nav.face(0)
end

---------------------------------------------------------------------------

if fedState() == "end" then state.done = true end
print(("End feeder: %d fed so far, facing %s at the start"):format(state.fed, state.facing))
-- Burns what it carries (never the cores or the detector) up to `target`.
local function refuel(target)
  for slot = 1, FED - 1 do
    if turtle.getFuelLevel() >= target then break end
    local d = turtle.getItemDetail(slot)
    if d and not d.name:find("advancedperipherals", 1, true) then
      turtle.select(slot)
      while turtle.getFuelLevel() < target and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

while not state.done do
  if turtle.getFuelLevel() < LOW_FUEL then refuel(2000) end
  if turtle.getFuelLevel() < LOW_FUEL then
    home()
    fail(("Fuel is low (%d): give me more and run me again"):format(turtle.getFuelLevel()))
  end
  local list = look()
  for _, c in ipairs(list) do
    if besides(c) then
      local ok, why = feed()
      if ok then
        state.fed = state.fed + 1
        save()
        print(("Fed enderman %d"):format(state.fed))
      else
        print("Missed: " .. why)
      end
      break
    end
  end
  if fedState() == "end" then
    state.done = true
    save()
  end
end
wear(CORE)
home()
-- The new End core goes on in place of the weak one (which goes into slot 16).
if equipped(WORK) ~= END_CORE and fedState() == "end" then
  turtle.select(FED)
  equipWork()
  turtle.select(1)
end
print(("Done: an End Automata Core is on (%d endermen). Back where I started"):format(state.fed))
