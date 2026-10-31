-- Geo scanner miner (phase 5) for the mining dimension.
--
-- Born at the factory as a mining turtle with a chunk controller. There it
-- only waits: the player carries it through the portal, places it at the
-- depth to mine, and gives it its kit:
--   a geo scanner, a linked chest or ender drawer (its twin is on the
--   factory network),
--   a bucket and some charcoal.
--
-- It puts the linked storage in the ceiling above where it was placed (home),
-- then works area by area: it swaps its pickaxe for the scanner to scan
-- (radius 8 costs no fuel), digs straight to every target ore, drops junk,
-- and moves on 14 blocks along a back-and-forth sweep. It refuels from coal
-- and lava pools, and empties into the linked storage when full. A drawer
-- holds one item type at a time: it hands over one type, waits for the
-- factory to empty the twin, then the next.
--
-- Position is saved on every move (lib/nav), so it carries on after reboots.
--
-- Usage: geominer           (what autorun runs)
--        geominer status    print progress

local nav = require("lib.nav")

local STATE = "/.geominer"
local RADIUS = 8          -- free scan radius
local AREA = 14           -- distance between scan areas
local ROWS = 8            -- areas per sweep line
local LOW_FUEL = 1500     -- burn coal below this
local RESERVE = 150       -- spare fuel on top of the way home

local TARGETS = { "iron_ore", "gold_ore", "redstone_ore", "diamond_ore", "coal_ore" }
-- What the targets drop, plus the kit. Everything else is dropped as junk.
local KEEP = {
  ["minecraft:raw_iron"] = true, ["minecraft:raw_gold"] = true, ["minecraft:redstone"] = true,
  ["minecraft:diamond"] = true, ["minecraft:coal"] = true, ["minecraft:charcoal"] = true,
  ["minecraft:bucket"] = true, ["minecraft:lava_bucket"] = true,
  ["advancedperipherals:geo_scanner"] = true, ["minecraft:diamond_pickaxe"] = true,
}
local FACTORY = { ["computercraft:turtle_normal"] = true, ["computercraft:turtle_advanced"] = true }
local SCANNER = "advancedperipherals:geo_scanner"

local function isTarget(name)
  for _, t in ipairs(TARGETS) do if name:find(t, 1, true) then return true end end
  return false
end
-- The linked storage: a linked chest or an ender drawer.
local function isLinked(name) return name:find("chest", 1, true) ~= nil or name:find("drawer", 1, true) ~= nil end
local function kept(name) return KEEP[name] or isLinked(name) end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state
do
  local h = fs.open(STATE, "r")
  if h then
    state = textutils.unserialise(h.readAll())
    h.close()
  end
end

local function save()
  local h = fs.open(STATE, "w")
  h.write(textutils.serialise(state))
  h.close()
end

local function fail(msg) error(msg, 0) end

local function report()
  local s = state.stats or {}
  local parts = {}
  for name, n in pairs(s.ores or {}) do parts[#parts + 1] = n .. " " .. name end
  table.sort(parts)
  print(("Area %d | fuel %d | mined %s | home trips %d"):format(state.area or 0, turtle.getFuelLevel(),
    #parts > 0 and table.concat(parts, ", ") or "nothing yet", s.trips or 0))
end

if ... == "status" then
  if state then report() else print("Not started") end
  return
end

---------------------------------------------------------------------------
-- Waiting for the trip to the mining dimension, and the kit
---------------------------------------------------------------------------

local function slotOf(match)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and match(item.name) then return slot, item end
  end
end

if not state then
  -- Still beside the factory: nothing to do until we're carried away.
  for _ = 1, 4 do
    local ok, b = turtle.inspect()
    if ok and FACTORY[b.name] then
      print("Ready. Carry me to the mining dimension; my kit is in the factory's output chest.")
      while true do sleep(3600) end
    end
    turtle.turnRight()
  end

  -- Placed in the mining dimension: wait for the kit.
  while true do
    local missing = {}
    if not slotOf(function(n) return n == SCANNER end) then missing[#missing + 1] = "a geo scanner" end
    if not slotOf(isLinked) then missing[#missing + 1] = "the linked chest or ender drawer" end
    if turtle.getFuelLevel() < 500 and not slotOf(function(n) return n == "minecraft:charcoal" or n == "minecraft:coal" end) then
      missing[#missing + 1] = "some charcoal"
    end
    if #missing == 0 then break end
    print("Waiting for " .. table.concat(missing, ", ") .. " in my inventory")
    os.pullEvent("turtle_inventory")
  end

  -- The linked storage goes in the ceiling above home.
  if turtle.detectUp() then
    if not turtle.digUp() then fail("Can't clear the block above me for the chest") end
  end
  turtle.select(slotOf(isLinked))
  if not turtle.placeUp() then fail("Couldn't place the linked storage above me") end
  turtle.select(1)
  state = { area = 0, stats = { ores = {}, trips = 0 } }
  print("Linked storage placed. Mining.")
end

nav.init(state, save)
nav.recover()
save()

-- Never dig the linked storage at home, bedrock or another turtle.
local function canDig(b)
  if isLinked(b.name) or FACTORY[b.name] or b.name == "minecraft:bedrock" then return false end
  return true
end
local DIG = { canDig = canDig }

local function stepTo(axis, v)
  return nav.stepTo(axis, v, DIG)
end

-- Straight there: y first (so tunnels stay level), then x, then z.
local function goTo(x, y, z)
  for _, step in ipairs({ { "y", y }, { "x", x }, { "z", z } }) do
    local ok, why = stepTo(step[1], step[2])
    if not ok then return false, why end
  end
  return true
end

---------------------------------------------------------------------------
-- Equipment: the scanner and the pickaxe share a side
---------------------------------------------------------------------------

local function pickSide()
  local r, l = turtle.getEquippedRight(), turtle.getEquippedLeft()
  if r and r.name:find("pickaxe", 1, true) then return "right" end
  if l and l.name:find("pickaxe", 1, true) then return "left" end
  if r and r.name == SCANNER then return "right" end -- a reboot mid-scan
  if l and l.name == SCANNER then return "left" end
end

local function equip(side)
  return side == "right" and turtle.equipRight() or turtle.equipLeft()
end

-- After a reboot mid-scan the scanner may still be on: put the pickaxe back.
local function ensurePickaxe()
  local side = pickSide()
  if not side then fail("I've lost my pickaxe") end
  local e = side == "right" and turtle.getEquippedRight() or turtle.getEquippedLeft()
  if e.name == SCANNER then
    local slot = slotOf(function(n) return n:find("pickaxe", 1, true) ~= nil end)
    if not slot then fail("I've lost my pickaxe") end
    turtle.select(slot)
    equip(side)
    turtle.select(1)
  end
  return side
end

-- Swaps the scanner in for the pickaxe, scans, swaps back. Returns the
-- blocks around us, positioned on world axes relative to the turtle.
local function rawScan()
  local side = ensurePickaxe()
  local slot = slotOf(function(n) return n == SCANNER end)
  if not slot then fail("No geo scanner in my inventory") end
  turtle.select(slot)
  equip(side)                         -- scanner on, pickaxe into the slot
  sleep(0.2)
  local blocks, err = peripheral.call(side, "scanBlocks", RADIUS)
  equip(side)                         -- pickaxe back on
  turtle.select(1)
  if not blocks then print("Scan failed: " .. tostring(err)) end
  return blocks or {}
end

-- The scanner uses world axes, nav uses our start facing. A scan, one step
-- forward and another scan show which world direction "forward" is: every
-- block appears shifted the opposite way.
local function calibrate()
  local before = {}
  for _, b in ipairs(rawScan()) do before[b.x .. "," .. b.y .. "," .. b.z] = b.name end
  local ok, why = nav.move("forward", DIG)
  if not ok then fail("Can't step forward to find my bearings: " .. tostring(why)) end
  local after = rawScan()
  local best, bestScore = nil, -1
  for _, f in ipairs({ { x = 1, z = 0 }, { x = -1, z = 0 }, { x = 0, z = 1 }, { x = 0, z = -1 } }) do
    local score = 0
    for _, b in ipairs(after) do
      if before[(b.x + f.x) .. "," .. b.y .. "," .. (b.z + f.z)] == b.name then score = score + 1 end
    end
    if score > bestScore then best, bestScore = f, score end
  end
  nav.move("back", DIG)
  state.forward = best
  save()
end

-- Returns the target ores around us in nav coordinates.
local function scan()
  local p, found = nav.pos(), {}
  local f = state.forward
  local right = { x = -f.z, z = f.x } -- right of north is east, right of east is south
  for _, b in ipairs(rawScan()) do
    if isTarget(b.name) then
      found[#found + 1] = {
        x = p.x + b.x * right.x + b.z * right.z,
        y = p.y + b.y,
        z = p.z + b.x * f.x + b.z * f.z,
        name = b.name,
      }
    end
  end
  return found
end

---------------------------------------------------------------------------
-- Inventory, fuel and the trip home
---------------------------------------------------------------------------

local function freeSlots()
  local n = 0
  for slot = 1, 16 do if turtle.getItemCount(slot) == 0 then n = n + 1 end end
  return n
end

local function dropJunk()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not kept(item.name) then
      turtle.select(slot)
      turtle.dropDown()
    end
  end
  turtle.select(1)
end

local function refuel()
  if turtle.getFuelLevel() >= LOW_FUEL then return end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name == "minecraft:lava_bucket"
        or item.name == "minecraft:coal" or item.name == "minecraft:charcoal") then
      turtle.select(slot)
      while turtle.getFuelLevel() < LOW_FUEL and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- Scoops a lava source next to us into the bucket and burns it.
local function scoopLava()
  local slot = slotOf(function(n) return n == "minecraft:bucket" end)
  if not slot or turtle.getFuelLevel() > turtle.getFuelLimit() - 1000 then return end
  for _, side in ipairs({ { turtle.inspectUp, turtle.placeUp }, { turtle.inspectDown, turtle.placeDown } }) do
    local ok, b = side[1]()
    if ok and b.name == "minecraft:lava" and (b.state or {}).level == 0 then
      turtle.select(slot)
      if side[2]() then turtle.refuel() end
      turtle.select(1)
      return
    end
  end
end

local function distanceHome()
  local p = nav.pos()
  return math.abs(p.x) + math.abs(p.y) + math.abs(p.z)
end

local function needHome()
  return freeSlots() < 3 or turtle.getFuelLevel() < distanceHome() + RESERVE
end

-- Home, empty everything worth delivering into the linked storage, and back.
local function deposit()
  local back = { x = nav.pos().x, y = nav.pos().y, z = nav.pos().z }
  dropJunk()
  local ok, why = goTo(0, 0, 0)
  if not ok then fail("Can't get home: " .. tostring(why)) end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name:find("raw_", 1, true) or item.name == "minecraft:redstone"
        or item.name == "minecraft:diamond" or item.name == "minecraft:coal") then
      turtle.select(slot)
      -- Keep a little coal for ourselves.
      local keep = item.name == "minecraft:coal" and math.min(16, item.count) or 0
      while turtle.getItemCount(slot) > keep and not turtle.dropUp(turtle.getItemCount(slot) - keep) do
        -- Full, or a drawer still holding another type: the factory empties
        -- its twin every ~10 seconds.
        print("Linked storage busy, waiting for the factory")
        sleep(10)
      end
    end
  end
  turtle.select(1)
  state.stats.trips = (state.stats.trips or 0) + 1
  save()
  goTo(back.x, back.y, back.z)
end

---------------------------------------------------------------------------
-- Mining
---------------------------------------------------------------------------

-- Area 0 is home; after that lines of ROWS areas straight ahead, each next
-- line one area to the right and walked the other way.
local function areaCenter(i)
  local k = i - 1
  local line, row = math.floor(k / ROWS), k % ROWS
  if line % 2 == 1 then row = ROWS - 1 - row end
  return line * AREA, 0, (row + 1) * AREA
end

local function nearest(list)
  local p, best, bestD = nav.pos(), nil, math.huge
  for i, t in ipairs(list) do
    local d = math.abs(t.x - p.x) + math.abs(t.y - p.y) + math.abs(t.z - p.z)
    if d < bestD then best, bestD = i, d end
  end
  return best
end

local function count(name)
  local short = name:gsub("^.*:", ""):gsub("^deepslate_", "")
  state.stats.ores[short] = (state.stats.ores[short] or 0) + 1
end

if not state.forward then calibrate() end
print("Geo miner running")
while true do
  refuel()
  if needHome() then deposit() end
  if not state.targets then
    state.targets = scan()
    save()
  end
  if #state.targets == 0 then
    -- Nothing (left) here: on to the next area.
    dropJunk()
    report()
    state.area = state.area + 1
    state.targets = nil
    save()
    local x, y, z = areaCenter(state.area)
    local ok, why = goTo(x, y, z)
    if not ok then
      print("Skipping area " .. state.area .. ": " .. tostring(why))
    end
  else
    local i = nearest(state.targets)
    local t = table.remove(state.targets, i)
    save()
    local ok = goTo(t.x, t.y, t.z)
    if ok then count(t.name) end
    scoopLava()
    if freeSlots() < 3 then dropJunk() end
  end
end
