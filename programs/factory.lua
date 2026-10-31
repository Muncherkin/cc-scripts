-- Turtle factory, phase 1: storage + crafting for a crafty turtle.
--
-- Layout: a crafty turtle with an input chest on top, an output chest
-- below, and a full-block wired modem touching one of its sides. The
-- modem joins a cable network of storage chests and furnaces. Right-click
-- every modem (including the one on the turtle) so its peripherals connect.
--
-- The turtle moves items with the network inventory API: storage chests
-- push ingredients straight into its crafting grid and pull results back.
--
-- Usage:
--   factory stock [filter]     what is in storage
--   factory plan <item> [n]    what crafting n would take, and what's missing
--   factory craft <item> [n]   deliver n to the output chest, crafting the rest
--   factory get <item> [n]     deliver n from storage only
--   factory store              move the input chest into storage
--   factory smelt              one round of furnace service
--   factory run [seconds]      loop: store input, run the furnaces
--   factory birth <job>        build a turtle, place it in front and boot it
--                              into a job from lib/jobs.lua
--   factory input <name>       treat a network chest as an input (e.g. the
--                              twin of a linked chest in the mining dimension)
--   factory recipes            list craftable items

local recipes = require("lib.recipes")
local jobs = require("lib.jobs")

-- The crafting grid is the top-left 3x3: row r, column c is slot (r-1)*4+c.
local IN_GRID = { [1] = true, [2] = true, [3] = true, [5] = true, [6] = true, [7] = true,
                  [9] = true, [10] = true, [11] = true }
local INFO_FILE = "/.factory/items"
local FURNACE = "minecraft:furnace"

---------------------------------------------------------------------------
-- Network
---------------------------------------------------------------------------

local self, storage, furnaces, inputs
local INPUTS_FILE = "/.factory/inputs"

-- Network chests that only bring items in: emptied into storage, never filled.
local function inputNames()
  local h = fs.open(INPUTS_FILE, "r")
  if not h then return {} end
  local list = textutils.unserialise(h.readAll()) or {}
  h.close()
  local set = {}
  for _, name in ipairs(list) do set[name] = true end
  return set
end

-- Finds the modem and what's on the network. Returns nil or an error message.
-- Right after a reboot or chunk load the network can take a moment to appear.
local function connect()
  local modem
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.hasType(side, "modem") and not peripheral.call(side, "isWireless") then
      modem = peripheral.wrap(side)
      break
    end
  end
  if not modem then return "No wired modem next to the turtle. Place a modem block touching it." end
  self = modem.getNameLocal()
  if not self then return "The modem next to the turtle is off. Right-click it to connect the turtle." end
  storage, furnaces, inputs = {}, {}, {}
  local inputSet = inputNames()
  for _, name in ipairs(modem.getNamesRemote()) do
    if peripheral.hasType(name, FURNACE) then
      furnaces[#furnaces + 1] = name
    elseif inputSet[name] then
      inputs[#inputs + 1] = name
    elseif peripheral.hasType(name, "inventory") and not peripheral.hasType(name, "turtle") then
      storage[#storage + 1] = name
    end
  end
  table.sort(storage)
  table.sort(furnaces)
  if #storage == 0 then return "No storage chests on the network" end
end

---------------------------------------------------------------------------
-- Item info (tags, stack size), cached across runs
---------------------------------------------------------------------------

local info = {}
do
  local h = fs.open(INFO_FILE, "r")
  if h then
    info = textutils.unserialise(h.readAll()) or {}
    h.close()
  end
end
local infoDirty = false

local function saveInfo()
  if not infoDirty then return end
  local h = fs.open(INFO_FILE, "w")
  h.write(textutils.serialise(info))
  h.close()
  infoDirty = false
end

local function learn(name, detail)
  if info[name] or not detail then return end
  local tags = {}
  for tag in pairs(detail.tags or {}) do tags[#tags + 1] = tag end
  info[name] = { tags = tags, max = detail.maxCount or 64 }
  infoDirty = true
end

local function hasTag(name, tag)
  for _, t in ipairs(info[name] and info[name].tags or {}) do
    if t == tag then return true end
  end
  return false
end

local function itemKey(it) return it.nbt and (it.name .. "@" .. it.nbt) or it.name end

local function matches(ing, key)
  if type(ing) == "string" then return key == ing end
  if key:find("@", 1, true) then return false end
  -- Items we know how to make for a tag count even before we've seen one.
  for _, make in ipairs(ing.make or {}) do
    if make == key then return true end
  end
  return hasTag(key, ing.tag)
end

local function short(name) return (name:gsub("^minecraft:", ""):gsub("^computercraft:", "")) end

---------------------------------------------------------------------------
-- Lock: jobs share the turtle, so only one may move items at a time. A job
-- stopped mid-move leaves the lock behind, so it expires without heartbeats.
---------------------------------------------------------------------------

local function beat() if _G.factoryLock then _G.factoryLock.at = os.epoch("utc") end end

local function locked(fn, ...)
  while _G.factoryLock and os.epoch("utc") - _G.factoryLock.at < 30000 do sleep(0.5) end
  _G.factoryLock = { at = os.epoch("utc") }
  local res = table.pack(pcall(fn, ...))
  _G.factoryLock = nil
  saveInfo()
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

---------------------------------------------------------------------------
-- Storage index
---------------------------------------------------------------------------

-- stock[key] = { count = n, at = { { inv = name, slot = s, count = n }, ... } }
local function scan()
  local stock = {}
  for _, name in ipairs(storage) do
    local inv = peripheral.wrap(name)
    for slot, it in pairs(inv.list()) do
      beat()
      if not info[it.name] then learn(it.name, inv.getItemDetail(slot)) end
      local key = itemKey(it)
      local s = stock[key] or { count = 0, at = {} }
      s.count = s.count + it.count
      s.at[#s.at + 1] = { inv = name, slot = slot, count = it.count }
      stock[key] = s
    end
  end
  return stock
end

local function counts(stock)
  local have = {}
  for key, s in pairs(stock) do have[key] = s.count end
  return have
end

-- Moves up to n items matching ing from storage into turtle slot `to`.
-- Returns how many moved and which item they were.
local function fetch(stock, ing, n, to)
  local moved = 0
  for key, s in pairs(stock) do
    if matches(ing, key) then
      for _, at in ipairs(s.at) do
        if moved >= n then return moved, key end
        if at.count > 0 then
          beat()
          local got = peripheral.call(at.inv, "pushItems", self, at.slot, math.min(n - moved, at.count), to)
          at.count, s.count, moved = at.count - got, s.count - got, moved + got
        end
      end
      -- Take one kind of item only: a grid slot can't hold two.
      if moved > 0 then return moved, key end
    end
  end
  return moved
end

-- Moves everything in the turtle into storage, same items first.
local function storeAll(stock)
  for slot = 1, 16 do
    local it = turtle.getItemDetail(slot)
    if it then
      if not info[it.name] then learn(it.name, turtle.getItemDetail(slot, true)) end
      local key = itemKey(it)
      local order = {}
      for _, at in ipairs(stock and stock[key] and stock[key].at or {}) do order[#order + 1] = at.inv end
      for _, name in ipairs(storage) do order[#order + 1] = name end
      for _, name in ipairs(order) do
        beat()
        peripheral.call(name, "pullItems", self, slot)
        if turtle.getItemCount(slot) == 0 then break end
      end
      if turtle.getItemCount(slot) > 0 then error("Storage is full", 0) end
    end
  end
end

-- Drops the turtle's whole inventory into the output chest below.
local function deliverAll()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      if not turtle.dropDown() then error("Output chest below the turtle is full or missing", 0) end
    end
  end
  turtle.select(1)
end

---------------------------------------------------------------------------
-- Planning: works out the crafts on a copy of the stock counts
---------------------------------------------------------------------------

local MAX_DEPTH = 8

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local need

local function produce(recipe, n, have, steps, missing, depth)
  local crafts = math.ceil(n / recipe.count)
  local uses = {}
  for _, row in ipairs(recipe.pattern) do
    for ch in row:gmatch("%S") do uses[ch] = (uses[ch] or 0) + 1 end
  end
  for ch, k in pairs(uses) do need(recipe.key[ch], k * crafts, have, steps, missing, depth + 1) end
  steps[#steps + 1] = { recipe = recipe, crafts = crafts }
  local surplus = crafts * recipe.count - n
  if surplus > 0 and not recipe.direct then have[recipe.name] = (have[recipe.name] or 0) + surplus end
end

-- Takes n of ing from `have`, adding the crafts that make any shortfall to
-- `steps` and anything that can't be made to `missing`.
need = function(ing, n, have, steps, missing, depth)
  if type(ing) == "string" then
    local got = math.min(have[ing] or 0, n)
    have[ing], n = (have[ing] or 0) - got, n - got
    if n == 0 then return end
    local recipe = recipes.get(ing)
    if recipe and depth < MAX_DEPTH then
      produce(recipe, n, have, steps, missing, depth)
    else
      missing[ing] = (missing[ing] or 0) + n
    end
    return
  end
  for key, c in pairs(have) do
    if n == 0 then return end
    if c > 0 and matches(ing, key) then
      local got = math.min(c, n)
      have[key], n = c - got, n - got
    end
  end
  if n == 0 then return end
  -- Planks from logs we actually have come first, then the usual list.
  local candidates = {}
  if ing.fromLogs then
    for key, c in pairs(have) do
      local planks = c > 0 and recipes.planksFor(key)
      if planks then candidates[#candidates + 1] = planks end
    end
    table.sort(candidates)
  end
  for _, make in ipairs(ing.make or {}) do candidates[#candidates + 1] = make end
  for _, make in ipairs(candidates) do
    local h2, s2, m2 = copy(have), {}, {}
    need(make, n, h2, s2, m2, depth)
    if next(m2) == nil then
      for k in pairs(have) do have[k] = nil end
      for k, v in pairs(h2) do have[k] = v end
      for _, s in ipairs(s2) do steps[#steps + 1] = s end
      return
    end
  end
  missing["#" .. ing.tag] = (missing["#" .. ing.tag] or 0) + n
end

local function plan(name, n, stock)
  local steps, missing = {}, {}
  local recipe = recipes.get(name)
  local have = counts(stock)
  if recipe and recipe.direct then
    produce(recipe, n, have, steps, missing, 0)
  else
    need(recipes.resolve(name), n, have, steps, missing, 0)
  end
  return steps, missing
end

---------------------------------------------------------------------------
-- Crafting
---------------------------------------------------------------------------

local placeFront = false -- set while a birth places its turtle

local function maxStack(name) return info[name] and info[name].max or 1 end

-- Runs `crafts` crafts of a recipe in batches the turtle can hold.
local function craftStep(recipe, crafts)
  local cells = {}
  for r, row in ipairs(recipe.pattern) do
    for c = 1, #row do
      local ch = row:sub(c, c)
      if ch ~= " " then cells[#cells + 1] = { slot = (r - 1) * 4 + c, ing = recipe.key[ch] } end
    end
  end
  local out = recipe.output or recipe.name
  -- Results must fit in the 7 slots outside the grid.
  local batch = math.max(1, math.floor(7 * maxStack(out) / recipe.count))
  for _, cell in ipairs(cells) do
    if type(cell.ing) == "string" then batch = math.min(batch, maxStack(cell.ing)) end
  end
  batch = math.min(batch, 64)

  local done = 0
  while done < crafts do
    local n = math.min(batch, crafts - done)
    local stock = scan()
    for _, cell in ipairs(cells) do
      local got = fetch(stock, cell.ing, n, cell.slot)
      if got < n then
        storeAll(stock)
        local what = type(cell.ing) == "string" and short(cell.ing) or ("#" .. cell.ing.tag)
        error(("Ran out of %s while crafting %s"):format(what, short(recipe.name)), 0)
      end
    end
    -- Tagged cells may have picked a small stack; craft what every cell holds.
    for _, cell in ipairs(cells) do n = math.min(n, turtle.getItemCount(cell.slot)) end
    turtle.select(16)
    local ok, err = turtle.craft(n)
    turtle.select(1)
    if not ok then
      storeAll(stock)
      error(("Craft of %s failed (%s). Check its recipe in JEI against lib/recipes.lua"):format(
        short(recipe.name), tostring(err)), 0)
    end
    if recipe.direct then
      -- The result is outside the grid; leftovers in the grid go back.
      -- Births place it in front instead of the output chest.
      for slot = 1, 16 do
        if not IN_GRID[slot] and turtle.getItemCount(slot) > 0 then
          turtle.select(slot)
          if placeFront then
            if not turtle.place() then error("Could not place the new turtle in front", 0) end
          elseif not turtle.dropDown() then
            error("Output chest below the turtle is full or missing", 0)
          end
        end
      end
      turtle.select(1)
    end
    storeAll(scan())
    done = done + n
  end
end

local function describe(steps, missing)
  local lines = {}
  for _, s in ipairs(steps) do
    lines[#lines + 1] = ("  craft %s x%d"):format(short(s.recipe.name), s.crafts)
  end
  local miss = {}
  for k, v in pairs(missing) do miss[#miss + 1] = ("  %d %s"):format(v, short(k)) end
  table.sort(miss)
  return lines, miss
end

local function craft(name, n)
  storeAll(scan())
  local steps, missing = plan(name, n, scan())
  local _, miss = describe(steps, missing)
  if #miss > 0 then
    print("Missing:")
    for _, l in ipairs(miss) do print(l) end
    return false
  end
  for _, s in ipairs(steps) do
    print(("Crafting %s x%d"):format(short(s.recipe.name), s.crafts))
    craftStep(s.recipe, s.crafts)
  end
  local recipe = recipes.get(name)
  if not (recipe and recipe.direct) then
    local key = recipes.resolve(name)
    local left = n
    while left > 0 do
      local got = fetch(scan(), key, math.min(left, 64 * 16))
      if got == 0 then error("Lost track of " .. short(key), 0) end
      deliverAll()
      left = left - got
    end
  end
  print(("Delivered %d %s"):format(n, short(name)))
  return true
end

local function get(name, n)
  storeAll(scan())
  local key = recipes.resolve(name)
  local stock = scan()
  local have = stock[key] and stock[key].count or 0
  if have < n then
    print(("Only %d %s in storage"):format(have, short(key)))
    return false
  end
  local left = n
  while left > 0 do
    local got = fetch(stock, key, math.min(left, 64 * 16))
    deliverAll()
    left = left - got
    stock = scan()
  end
  print(("Delivered %d %s"):format(n, short(key)))
  return true
end

---------------------------------------------------------------------------
-- Births: the spot in front of the turtle is where new turtles are placed.
-- A disk drive touching that spot (and on the network, so we can write to
-- its floppy) boots them into their job.
---------------------------------------------------------------------------

local FUELS = { "minecraft:charcoal", "minecraft:coal" }
local LAST_BIRTH = "/.factory/lastbirth"

-- Births and the fuel station share the spot in front; a newborn booting
-- there mustn't be mistaken for a turtle asking for fuel.
local function writeLastBirth()
  local h = fs.open(LAST_BIRTH, "w")
  h.write(tostring(os.epoch("utc")))
  h.close()
end

local function lastBirth()
  local h = fs.open(LAST_BIRTH, "r")
  if not h then return 0 end
  local t = tonumber(h.readAll()) or 0
  h.close()
  return t
end

local function findDisk()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "drive") and peripheral.call(name, "isDiskPresent") then
      local mount = peripheral.call(name, "getMountPath")
      if mount then return "/" .. mount end
    end
  end
end

local function copyFile(from, to)
  local h = fs.open(from, "r")
  if not h then error("Missing " .. from .. " on the factory turtle", 0) end
  local data = h.readAll()
  h.close()
  local out = fs.open(to, "w")
  out.write(data)
  out.close()
end

-- Hands n of an item from storage to the turtle in front, or with
-- toOutput into the output chest (for a turtle the player will carry).
local function give(name, n, toOutput)
  local left = n
  while left > 0 do
    local got = fetch(scan(), name, left)
    if got == 0 then error("Ran out of " .. short(name) .. " for the new turtle", 0) end
    for slot = 1, 16 do
      if turtle.getItemCount(slot) > 0 then
        turtle.select(slot)
        if toOutput then
          if not turtle.dropDown() then error("The output chest is full", 0) end
        elseif not turtle.drop() then
          error("The new turtle has no room for " .. short(name), 0)
        end
      end
    end
    turtle.select(1)
    left = left - got
  end
end

local function birth(jobName)
  local job = jobs[jobName]
  if not job then error("No job called " .. jobName .. " in lib/jobs.lua", 0) end
  local disk = findDisk()
  if not disk then
    error("No floppy in a disk drive on the network. The drive goes next to the spot in front of the turtle.", 0)
  end
  if turtle.detect() then error("The birth spot in front of the turtle is taken", 0) end
  storeAll(scan())

  -- Check everything first, so a birth never stops halfway.
  local stock = scan()
  local steps, missing = plan(job.unit, 1, stock)
  local have = counts(stock)
  -- Kit items match by name whatever their item data (some modded buckets carry some).
  local kit = {}
  for _, item in ipairs(job.kit) do
    local name, n = item[1], item[2]
    local key = (have[name] or 0) >= n and name or nil
    -- "*part" matches any item whose id contains part, e.g. "*pine_sapling".
    local part = name:match("^%*(.+)")
    for k, c in pairs(have) do
      local base = k:match("^[^@]+")
      if not key and c >= n and (base == name or (part and base:find(part, 1, true))) then key = k end
    end
    if key then kit[#kit + 1] = { key, n } else missing[name] = n end
  end
  local fuel
  for _, f in ipairs(FUELS) do
    if (have[f] or 0) >= job.fuel then fuel = f break end
  end
  if not fuel then missing["minecraft:charcoal"] = job.fuel end
  local _, miss = describe(steps, missing)
  if #miss > 0 then
    print("Missing:")
    for _, l in ipairs(miss) do print(l) end
    return false
  end

  -- The boot disk: installer, agent config, the job and its programs.
  copyFile("/birth/startup.lua", disk .. "/startup.lua")
  copyFile("/.agent/config", disk .. "/agent-config")
  if fs.exists(disk .. "/files") then fs.delete(disk .. "/files") end
  for _, file in ipairs(job.files) do copyFile("/" .. file, disk .. "/files/" .. file) end
  local h = fs.open(disk .. "/job", "w")
  h.write(textutils.serialise({ program = job.program, args = job.args or {} }))
  h.close()

  placeFront = true
  local ok, err = pcall(function()
    for _, s in ipairs(steps) do
      print(("Crafting %s x%d"):format(short(s.recipe.name), s.crafts))
      craftStep(s.recipe, s.crafts)
    end
  end)
  placeFront = false
  if not ok then error(err, 0) end
  if not turtle.detect() then error("The new turtle wasn't placed", 0) end

  -- A turtle the player carries elsewhere would spill its inventory when
  -- picked up, so its kit waits in the output chest instead.
  for _, item in ipairs(kit) do give(item[1], item[2], job.kitToOutput) end
  give(fuel, job.fuel, job.kitToOutput)
  peripheral.call("front", "turnOn")
  writeLastBirth()
  print(("Born: a %s for the %s job, booting from the disk"):format(short(job.unit), jobName))
  return true
end

-- Fuel station: a turtle parked on the birth spot gets charcoal, a few
-- per round, while storage has more than a reserve for the furnaces.
local STATION_GIVE, STATION_RESERVE, NEWBORN_GRACE = 8, 16, 120000

local function fuelStation()
  if os.epoch("utc") - lastBirth() < NEWBORN_GRACE then return nil end
  local ok, b = turtle.inspect()
  if not (ok and b.name:find("^computercraft:turtle")) then return nil end
  local have = counts(scan())
  for _, fuel in ipairs(FUELS) do
    if (have[fuel] or 0) > STATION_RESERVE then
      give(fuel, math.min(STATION_GIVE, have[fuel] - STATION_RESERVE))
      return ("Fuel station: gave %s"):format(short(fuel))
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Input chest and furnaces
---------------------------------------------------------------------------

-- Moves the input chest above into storage. Returns how many items moved.
-- A few rounds at most: the cobble turtle tops the chest up every second
-- or so, and an "until empty" loop would never let go of the turtle.
local INTAKE_ROUNDS = 4

-- Empties the network input chests into storage.
local function networkIntake()
  local total = 0
  for _, input in ipairs(inputs) do
    for slot, it in pairs(peripheral.call(input, "list")) do
      for _, name in ipairs(storage) do
        beat()
        local moved = peripheral.call(name, "pullItems", input, slot)
        total = total + moved
        if moved >= it.count then break end
        it.count = it.count - moved
      end
    end
  end
  return total
end

local function intake()
  local total = 0
  for _ = 1, INTAKE_ROUNDS do
    local got = 0
    for slot = 1, 16 do
      turtle.select(slot)
      if turtle.getItemCount(slot) == 0 and turtle.suckUp() then got = got + turtle.getItemCount(slot) end
    end
    turtle.select(1)
    if got == 0 then break end
    storeAll(scan())
    total = total + got
  end
  return total + networkIntake()
end

-- Stock entries that can burn, best fuel first.
local function fuelsInStock(stock)
  local found = {}
  for _, fuel in ipairs(recipes.fuels) do
    for key, s in pairs(stock) do
      if s.count > 0 and matches(fuel, key) then found[#found + 1] = s end
    end
  end
  return found
end

-- With nothing to burn at all, turns two logs into planks so the furnaces
-- can start making charcoal. Returns true if it made some.
local function bootstrapFuel(stock)
  if #fuelsInStock(stock) > 0 then return false end
  for _, f in ipairs(furnaces) do
    if peripheral.call(f, "list")[2] then return false end
  end
  for key, s in pairs(stock) do
    local recipe = s.count >= 2 and recipes.get((key:gsub("_log$", "_planks")))
    if recipe and recipe.key.L == key then
      craftStep(recipe, 2)
      return true
    end
  end
  return false
end

-- Empties furnace outputs, tops up fuel, and loads inputs for whatever is
-- below its stock target. Returns a short summary, or nil if idle.
local function serviceFurnaces()
  if #furnaces == 0 then return nil end
  local stock = scan()
  local moved = {}
  if bootstrapFuel(stock) then
    moved[#moved + 1] = "8 planks for fuel"
    stock = scan()
  end
  local have = counts(stock)
  for _, f in ipairs(furnaces) do
    local slots = peripheral.call(f, "list")
    if slots[3] then
      for _, name in ipairs(storage) do
        beat()
        if peripheral.call(name, "pullItems", f, 3) > 0 and not peripheral.call(f, "list")[3] then break end
      end
      moved[#moved + 1] = ("%d %s"):format(slots[3].count, short(slots[3].name))
    end
    local fuelled = slots[2] ~= nil
    if not slots[2] or slots[2].count < 4 then
      -- The fuel slot holds one kind, so a push of another kind moves nothing.
      for _, s in ipairs(fuelsInStock(stock)) do
        for _, at in ipairs(s.at) do
          if at.count > 0 then
            beat()
            local got = peripheral.call(at.inv, "pushItems", f, at.slot, math.min(8, at.count), 2)
            at.count, s.count = at.count - got, s.count - got
            if got > 0 then fuelled = true break end
          end
        end
        if fuelled then break end
      end
    end
    if not fuelled and slots[1] then
      -- Nothing to burn: hand the input back so it can be used elsewhere.
      for _, name in ipairs(storage) do
        beat()
        peripheral.call(name, "pullItems", f, 1)
        if not peripheral.call(f, "list")[1] then break end
      end
    elseif fuelled and not slots[1] then
      for _, job in ipairs(recipes.smelting) do
        -- Leave `spare` of the input in storage (logs are also for crafting).
        local spare = -(job.spare or 0)
        for key, c in pairs(have) do
          if matches(job.input, key) then spare = spare + c end
        end
        if (have[job.output] or 0) < job.keep and spare > 0 then
          local got, key = fetch(stock, job.input, math.min(16, spare))
          -- fetch() fills the turtle; hand the items to the furnace instead.
          if got > 0 then
            for slot = 1, 16 do
              if turtle.getItemCount(slot) > 0 then
                beat()
                peripheral.call(f, "pullItems", self, slot, 64, 1)
              end
            end
            storeAll(stock)
            have[job.output] = (have[job.output] or 0) + got
            have[key] = have[key] - got
            break
          end
        end
      end
    end
  end
  if #moved == 0 then return nil end
  return "Smelted " .. table.concat(moved, ", ")
end

-- One line with the stock that matters most, e.g. for the glasses HUD:
-- "Stock: 308 cobble, 259 stone, 31 charcoal, 13 logs, 55 glass"
local LOGS = { tag = "minecraft:logs" }
local function stockLine(stock)
  local have = counts(stock)
  local logs = 0
  for key, c in pairs(have) do
    if matches(LOGS, key) then logs = logs + c end
  end
  return ("Stock: %d cobble, %d stone, %d charcoal, %d logs, %d glass"):format(
    have["minecraft:cobblestone"] or 0, have["minecraft:stone"] or 0, have["minecraft:charcoal"] or 0,
    logs, have["minecraft:glass"] or 0)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local cmd, a1, a2 = ...
local n = tonumber(a2) or 1

if cmd ~= "run" then
  local err = connect()
  if err then error(err, 0) end
end

if cmd == "stock" then
  local stock = locked(scan)
  local rows = {}
  for key, s in pairs(stock) do
    if not a1 or key:find(a1, 1, true) then rows[#rows + 1] = { key = key, count = s.count } end
  end
  table.sort(rows, function(x, y) return x.key < y.key end)
  for _, r in ipairs(rows) do print(("%6d %s"):format(r.count, short(r.key))) end
  print(("%d kinds in %d chests, %d furnaces"):format(#rows, #storage, #furnaces))
elseif cmd == "plan" and a1 then
  local steps, missing = plan(a1, n, locked(scan))
  local lines, miss = describe(steps, missing)
  if #lines == 0 and #miss == 0 then print("All in stock") end
  for _, l in ipairs(lines) do print(l) end
  if #miss > 0 then
    print("Missing:")
    for _, l in ipairs(miss) do print(l) end
  end
  return #miss == 0
elseif cmd == "craft" and a1 then
  if not recipes.get(a1) then error("No recipe for " .. a1 .. " (see: factory recipes)", 0) end
  return locked(craft, a1, n)
elseif cmd == "birth" and a1 then
  return locked(birth, a1)
elseif cmd == "get" and a1 then
  return locked(get, a1, n)
elseif cmd == "input" and a1 then
  local set = inputNames()
  local list = {}
  for name in pairs(set) do list[#list + 1] = name end
  if not set[a1] then list[#list + 1] = a1 end
  table.sort(list)
  local h = fs.open(INPUTS_FILE, "w")
  h.write(textutils.serialise(list))
  h.close()
  print("Input chests: " .. table.concat(list, ", "))
elseif cmd == "store" then
  print(("Stored %d items"):format(locked(intake)))
elseif cmd == "smelt" then
  print(locked(serviceFurnaces) or "Furnaces idle")
elseif cmd == "run" then
  -- Runs unattended, so it never gives up: it waits for the network after a
  -- reboot and reports errors (a chest unloading, storage full) then retries.
  local interval = tonumber(a1) or 10
  local STOCK_EVERY = 60000
  local lastStock = -STOCK_EVERY
  local lastErr
  local function report(err)
    if err ~= lastErr then printError(err) end
    lastErr = err
  end
  while true do
    local err = connect()
    if err then
      report(err)
    else
      if lastErr ~= false then
        print(("Factory running: %d chests, %d furnaces"):format(#storage, #furnaces))
        lastErr = false
      end
      -- Quiet apart from a stock line a minute: dashboards and the glasses
      -- HUD read the last line of this job.
      local ok, res = pcall(function()
        locked(intake)
        locked(serviceFurnaces)
        locked(fuelStation)
        if os.epoch("utc") - lastStock >= STOCK_EVERY then
          print(stockLine(locked(scan)))
          lastStock = os.epoch("utc")
        end
      end)
      if not ok then report(res) end
    end
    sleep(interval)
  end
elseif cmd == "recipes" then
  local names = {}
  for name in pairs(recipes.alias) do names[#names + 1] = name end
  for _, r in ipairs(recipes.list) do
    if r.direct then names[#names + 1] = r.name end
  end
  table.sort(names)
  print(table.concat(names, ", "))
  print("Or any full item name from lib/recipes.lua")
else
  print("Usage: factory stock|plan|craft|get|store|smelt|run|birth|recipes")
end
