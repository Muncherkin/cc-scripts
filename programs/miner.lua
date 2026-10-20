-- Branch miner. Digs a main tunnel straight ahead forever, with branches to
-- both sides, mines out every ore vein it sees and keeps only the valuables.
--
-- * Tunnels are 1 high. Branches every SPACING blocks with side scanning
--   means every block on the mining layer gets looked at.
-- * Junk (stone, dirt, gravel...) is dropped; anything unknown is kept.
-- * When the inventory is full it places a chest in the ceiling and empties
--   into it. With no chests left it goes home and stops.
-- * Refuels from mined coal, and scoops lava pools with an empty bucket.
-- * Position is saved on every move, so it resumes after server restarts.
--
-- Equip: pickaxe + chunk loader (Advanced Peripherals Chunky Turtle).
-- Inventory: chests, an empty bucket, some starting fuel.
--
-- Usage:
--   miner new [branchLength] [spacing]   start mining here, facing the main tunnel direction
--   miner                                resume (what autorun uses)
--   miner status                         print progress without running
--   miner continue                       carry on after stopping for fuel or chests

local STATE_FILE = "/.miner/state"
local MAX_VEIN = 48         -- max recursion depth when following a vein
local FUEL_TARGET = 10000   -- burn coal into the tank up to this level
local FUEL_MARGIN = 200     -- spare fuel kept on top of the trip home

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state

local lastReport = -1

-- Tells the bridge (dashboard, Claude OS) where we are, at most every 5s.
local function reportPosition(force)
  if not bridge or not state.pos then return end
  local now = os.clock()
  if not force and now - lastReport < 5 then return end
  lastReport = now
  pcall(bridge.send, { action = "pos", pos = state.pos, dir = state.dir, frame = "start" })
end

local function save()
  local h = fs.open(STATE_FILE .. ".tmp", "w")
  h.write(textutils.serialise(state, { compact = true }))
  h.close()
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
  fs.move(STATE_FILE .. ".tmp", STATE_FILE)
  reportPosition()
end

local function load()
  for _, path in ipairs({ STATE_FILE, STATE_FILE .. ".tmp" }) do
    if fs.exists(path) then
      local h = fs.open(path, "r")
      local s = textutils.unserialise(h.readAll())
      h.close()
      if s then return s end
    end
  end
end

---------------------------------------------------------------------------
-- Position tracking. Coordinates are relative to the start: +z is the main
-- tunnel direction, +x is to the right, +y is up. dir: 0=+z 1=+x 2=-z 3=-x.
---------------------------------------------------------------------------

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local function applyMove(kind, dir)
  local p = state.pos
  if kind == "up" then p.y = p.y + 1
  elseif kind == "down" then p.y = p.y - 1
  else
    local sign = kind == "back" and -1 or 1
    p.x = p.x + DX[dir] * sign
    p.z = p.z + DZ[dir] * sign
  end
end

-- After a restart: a move that was in progress happened if fuel went down.
local function recover()
  local pend = state.pending
  if not pend then return end
  if pend.kind == "turn" then
    printError("Restarted during a turn; assuming it did not happen")
  elseif turtle.getFuelLevel() < pend.fuel then
    applyMove(pend.kind, pend.dir)
  end
  state.pending = nil
  save()
end

local function turn(right)
  state.pending = { kind = "turn" }
  if right then turtle.turnRight() else turtle.turnLeft() end
  state.dir = (state.dir + (right and 1 or 3)) % 4
  state.pending = nil
  save()
end

local function face(dir)
  local diff = (dir - state.dir) % 4
  if diff == 1 then turn(true)
  elseif diff == 2 then turn(true) turn(true)
  elseif diff == 3 then turn(false) end
end

local ACTIONS = {
  forward = { move = turtle.forward, detect = turtle.detect, dig = turtle.dig, attack = turtle.attack },
  up = { move = turtle.up, detect = turtle.detectUp, dig = turtle.digUp, attack = turtle.attackUp },
  down = { move = turtle.down, detect = turtle.detectDown, dig = turtle.digDown, attack = turtle.attackDown },
}

-- Moves one block, digging and fighting through whatever is in the way.
-- Returns moved, dug (whether a block had to be dug), or false, reason.
local function move(kind)
  local a = ACTIONS[kind]
  local dug = false
  for _ = 1, 40 do
    if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
    state.pending = { kind = kind, dir = state.dir, fuel = turtle.getFuelLevel() }
    save()
    if a.move() then
      applyMove(kind, state.dir)
      state.pending = nil
      save()
      return true, dug
    end
    state.pending = nil
    if a.detect() then
      if not a.dig() then return false, "unbreakable block" end
      dug = true
      state.stats.blocks = state.stats.blocks + 1
    else
      a.attack()
      sleep(0.3)
    end
  end
  return false, "stuck"
end

local function moveBack()
  state.pending = { kind = "back", dir = state.dir, fuel = turtle.getFuelLevel() }
  save()
  if turtle.back() then
    applyMove("back", state.dir)
    state.pending = nil
    save()
    return true
  end
  state.pending = nil
  turn(true) turn(true)
  local ok, why = move("forward")
  turn(true) turn(true)
  return ok, why
end

---------------------------------------------------------------------------
-- Inventory and fuel
---------------------------------------------------------------------------

local FUEL_ITEMS = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
}
local JUNK_TAGS = {
  "c:stones", "c:cobblestones", "c:gravels", "c:sands", "c:netherracks", "c:end_stones",
  "minecraft:dirt", "minecraft:base_stone_overworld", "minecraft:stone_crafting_materials",
}
local JUNK_NAMES = {
  ["minecraft:tuff"] = true, ["minecraft:calcite"] = true, ["minecraft:dripstone_block"] = true,
  ["minecraft:pointed_dripstone"] = true, ["minecraft:flint"] = true, ["minecraft:clay_ball"] = true,
  ["minecraft:smooth_basalt"] = true, ["minecraft:basalt"] = true, ["minecraft:blackstone"] = true,
}

local function isJunk(d)
  if JUNK_NAMES[d.name] then return true end
  for _, tag in ipairs(JUNK_TAGS) do
    if d.tags and d.tags[tag] then return true end
  end
  return false
end

local function isDepositChest(d)
  return d.name == "minecraft:chest" or (d.tags and d.tags["c:chests"]) and not d.name:find("boat")
end

local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local function countChests()
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s, true)
    if d and isDepositChest(d) then n = n + d.count end
  end
  return n
end

local function distanceHome()
  local p = state.pos
  return math.abs(p.x) + math.abs(p.y) + math.abs(p.z)
end

local function refuel()
  local limit = math.min(turtle.getFuelLimit(), FUEL_TARGET)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and (FUEL_ITEMS[d.name] or d.name == "minecraft:lava_bucket") then
      turtle.select(s)
      while turtle.getItemCount(s) > 0 and turtle.getFuelLevel() + 80 <= limit do
        if not turtle.refuel(1) then break end
      end
    end
  end
end

local function hasFuelForHome()
  return turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= distanceHome() + FUEL_MARGIN
end

local function dropJunk()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s, true)
    if d and isJunk(d) then
      turtle.select(s)
      turtle.dropDown()
    end
  end
end

-- Things that never go into a deposit chest.
local function isReserved(d)
  return isDepositChest(d) or d.name == "minecraft:bucket"
    or (FUEL_ITEMS[d.name] and turtle.getFuelLevel() < FUEL_TARGET)
end

-- Places a chest above (or below, if "up" is the way back) and empties into it.
local function deposit(avoid)
  local slot
  for s = 1, 16 do
    local d = turtle.getItemDetail(s, true)
    if d and isDepositChest(d) then slot = s break end
  end
  if not slot then return false end

  local up = avoid ~= "up"
  while up and turtle.detectUp() do
    if not turtle.digUp() then up = false break end
  end
  turtle.select(slot)
  local placed = up and turtle.placeUp()
  if not placed and avoid ~= "down" then
    while turtle.detectDown() do turtle.digDown() end
    placed = turtle.placeDown()
    up = false
  end
  if not placed then return false end

  for s = 1, 16 do
    local d = turtle.getItemDetail(s, true)
    if d and not isReserved(d) then
      turtle.select(s)
      if up then turtle.dropUp() else turtle.dropDown() end
    end
  end
  local p = state.pos
  state.chests[#state.chests + 1] = { x = p.x, y = p.y + (up and 1 or -1), z = p.z }
  print(("Filled a chest at %d,%d,%d (%d chests left)"):format(p.x, p.y, p.z, countChests()))
  save()
  return true
end

local OutOfChests = {}
local OutOfFuel = {}
local homing = false -- on the final trip home: keep going whatever happens

-- Makes room and checks fuel; throws OutOfChests / OutOfFuel when stuck.
-- avoid: "up"/"down" if that side is the way back, so no chest goes there.
local function maintain(avoid)
  refuel()
  if not homing and not hasFuelForHome() then error(OutOfFuel, 0) end
  if freeSlots() >= 2 then return end
  dropJunk()
  if freeSlots() >= 3 or homing then return end
  if countChests() == 0 then error(OutOfChests, 0) end
  if not deposit(avoid) then printError("Couldn't place a chest here, carrying on") end
end

---------------------------------------------------------------------------
-- Ore detection, lava scooping and vein mining
---------------------------------------------------------------------------

local INSPECT = { front = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local PLACE = { front = turtle.place, up = turtle.placeUp, down = turtle.placeDown }

local function isOre(b)
  return b.tags and (b.tags["c:ores"] or b.tags["forge:ores"]) or b.name:find("_ore$") ~= nil
    or b.name == "minecraft:ancient_debris"
end

local function scoopLava(side)
  if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLimit() - turtle.getFuelLevel() < 1000 then return end
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == "minecraft:bucket" then
      turtle.select(s)
      if PLACE[side]() then
        turtle.refuel()
        state.stats.lava = state.stats.lava + 1
      end
      return
    end
  end
end

local mineVein

local function check(side, depth, back)
  -- Make room first: a chest placed now can't end up where we're about to dig.
  if depth <= MAX_VEIN then maintain(back) end
  local ok, b = INSPECT[side]()
  if not ok then return end
  if b.name == "minecraft:lava" and b.state and b.state.level == 0 then
    scoopLava(side)
  elseif isOre(b) and depth <= MAX_VEIN then
    state.stats.ores[b.name] = (state.stats.ores[b.name] or 0) + 1
    if side == "up" then
      if move("up") then mineVein(depth + 1, "down") move("down") end
    elseif side == "down" then
      if move("down") then mineVein(depth + 1, "up") move("up") end
    else
      if move("forward") then mineVein(depth + 1) moveBack() end
    end
  end
end

-- Mines out every ore block touching the current position. back is the
-- side ("up"/"down"/nil) leading back to where the vein was entered from.
mineVein = function(depth, back)
  check("up", depth, back)
  check("down", depth, back)
  for _ = 1, 4 do
    check("front", depth, back)
    turn(true)
  end
end

-- Looks above, below, left and right of a tunnel block (not front/back).
local function scanTunnel()
  check("up", 1)
  check("down", 1)
  turn(false)
  check("front", 1)
  turn(true) turn(true)
  check("front", 1)
  turn(false)
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local function stepTo(axis, target, scan)
  while state.pos[axis] ~= target do
    local kind
    if axis == "y" then
      kind = state.pos.y < target and "up" or "down"
    else
      if axis == "x" then face(state.pos.x < target and 1 or 3) else face(state.pos.z < target and 0 or 2) end
      kind = "forward"
    end
    maintain()
    local ok, dug = move(kind)
    if not ok then return false, dug end
    if scan and dug then scanTunnel() end
  end
  return true
end

-- Goes to a position: height first, then sideways, then along the main tunnel.
local function goTo(x, y, z, scan)
  for _, step in ipairs({ { "y", y }, { "x", x }, { "z", z } }) do
    local ok, why = stepTo(step[1], step[2], scan)
    if not ok then return false, why end
  end
  return true
end

---------------------------------------------------------------------------
-- Mining plan
---------------------------------------------------------------------------

local function report()
  local ores, total = {}, 0
  for name, n in pairs(state.stats.ores) do
    total = total + n
    ores[#ores + 1] = { name = name:gsub("^.-:", ""), n = n }
  end
  table.sort(ores, function(a, b) return a.n > b.n end)
  local top = {}
  for i = 1, math.min(4, #ores) do top[i] = ores[i].name .. " " .. ores[i].n end
  print(("Branch %d | pos %d,%d,%d | fuel %s | ores %d (%s) | lava %d | chests %d placed, %d left")
    :format(state.branch, state.pos.x, state.pos.y, state.pos.z, tostring(turtle.getFuelLevel()), total,
      table.concat(top, ", "), state.stats.lava, #state.chests, countChests()))
end

local function mineBranch(side)
  local z = state.branch * state.cfg.spacing
  face(side > 0 and 1 or 3)
  for _ = 1, state.cfg.branchLength do
    maintain()
    local ok, dug = move("forward")
    if not ok then break end -- bedrock, protected area etc: branch ends early
    if dug then scanTunnel() end
  end
  local ok, why = goTo(0, 0, z, false)
  if not ok then error("Can't get back to the main tunnel: " .. tostring(why), 0) end
end

local function finish(reason)
  print("Stopping: " .. reason .. ". Heading home.")
  homing = true
  local ok, why = goTo(0, 0, 0, false)
  if ok then face(0) else printError("Could not get home: " .. tostring(why)) end
  state.done = reason
  save()
  report()
end

local function checkEquipment()
  local names = {}
  for _, side in ipairs({ "Left", "Right" }) do
    local d = turtle["getEquipped" .. side] and turtle["getEquipped" .. side]()
    names[#names + 1] = d and d.name or "nothing"
  end
  local joined = table.concat(names, " + ")
  if not joined:find("pickaxe") then error("Needs a pickaxe equipped (has " .. joined .. ")", 0) end
  if not joined:find("chunk") then
    printError("No chunk loader equipped (" .. joined .. "): mining stops whenever nobody is nearby")
  end
end

local function run(fresh)
  checkEquipment()
  recover()
  reportPosition(true)
  refuel()
  print(("Miner %s at %d,%d,%d, branch %d, %d chests"):format(state.done and "finished" or fresh and "starting" or "resuming",
    state.pos.x, state.pos.y, state.pos.z, state.branch, countChests()))
  if state.done then return state.done end

  local ok, err = pcall(function()
    while true do
      local z = state.branch * state.cfg.spacing
      local okMain, why = goTo(0, 0, z, true)
      if not okMain then error({ blocked = why }, 0) end
      for _, side in ipairs({ 1, -1 }) do
        if not state.sidesDone[tostring(side)] then
          mineBranch(side)
          state.sidesDone[tostring(side)] = true
          save()
        end
      end
      report()
      state.branch = state.branch + 1
      state.sidesDone = {}
      save()
    end
  end)

  if err == OutOfChests then finish("out of deposit chests")
  elseif err == OutOfFuel then finish("low on fuel")
  elseif type(err) == "table" and err.blocked then finish("main tunnel blocked (" .. tostring(err.blocked) .. ")")
  else error(err, 0) end
  return state.done
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

local cmd, a1, a2 = ...
if cmd == "new" then
  if fs.exists(STATE_FILE) and not (load() or {}).done then
    printError("Overwriting an unfinished mining run")
  end
  state = {
    version = 1,
    cfg = { branchLength = tonumber(a1) or 16, spacing = tonumber(a2) or 3 },
    pos = { x = 0, y = 0, z = 0 }, dir = 0,
    branch = 1, sidesDone = {}, chests = {},
    stats = { blocks = 0, lava = 0, ores = {} },
  }
  save()
  return run(true)
end

state = load()
if not state then error("No mining run here yet. Start one with: miner new [branchLength] [spacing]", 0) end
if cmd == "status" then
  reportPosition(true)
  report()
  return state.stats.ores
end
if cmd == "continue" then
  -- After a stop (fuel, chests): carry on from the same branch.
  state.done = nil
  save()
end
return run()
