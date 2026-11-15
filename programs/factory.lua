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
--   factory tree <item> [n]    the rest of the way from stock: raw materials,
--                              smelts, fuel and a time on these furnaces
--   factory craft <item> [n]   deliver n to the output chest, crafting the rest
--   factory get <item> [n]     deliver n from storage only
--   factory store              move the input chest into storage
--   factory smelt              one round of furnace service
--   factory run [seconds]      loop: store input, run the furnaces, compact
--   factory compact            one round of squeezing what there's too much
--                              of (recipes.compacting: cobble into compressed)
--   factory birth <job> [args] build a turtle, place it in front and boot it
--                              (args, if any, replace the job's own)
--                              into a job from lib/jobs.lua
--   factory input <name>       treat a network chest as an input (e.g. the
--                              twin of a linked chest in the mining dimension);
--                              ender drawers always are. `input all`: every
--                              storage chest now on the network (to empty
--                              them into chests added later), `input clear`
--   factory evacuate [on [item=n ...]]|off   moving out (docs/factory-move.md):
--                              the turtle labelled Mover on the birth spot is
--                              loaded with everything in storage, a few
--                              stacks a visit, at most n of each item named
--                              (default minecraft:cobblestone=3000); the
--                              furnaces are emptied, not loaded
--   factory order <item> [n] [keep]   queue an order: n delivered to the
--                              output chest, or with keep, n held in stock.
--                              `factory run` works on the oldest: it smelts
--                              and crafts what it can and waits for the rest
--   factory order birth <job> [args]  queue a birth, made when it can be
--   factory order cancel <id>
--   factory orders             the queue and what each order waits for
--   factory flow               items a minute in and out (lib/rates), and
--                              what the balancer says to gather faster
--   factory allow [id item=n ...]   the loading bay's ledger (lib/bay.lua):
--                              what each turtle may still draw when it parks
--                              on the birth spot; with an id, adds to it
--   factory recipes            list craftable items

local recipes = require("lib.recipes")
local jobs = require("lib.jobs")
local Plan = require("lib.plan")
local Rates = require("lib.rates")
local Orders = require("lib.orders")
local Bay = require("lib.bay")

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
    elseif inputSet[name] or name:find("ender_drawer", 1, true) then
      -- An ender drawer's twin is in the mining dimension: never fill it.
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

-- Item flows for lib/rates, recorded while `factory run` is measuring:
-- n > 0 came into storage, n < 0 went out.
local rates
local function nowS() return os.epoch("utc") / 1000 end
local function flow(item, n)
  if rates and item and n ~= 0 then rates.flow(nowS(), item, n) end
end
-- Smelt targets from the order being worked on: output -> stock to reach.
local wants = {}

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
-- Planning (lib/plan.lua): works out the crafts on a copy of the stock counts
---------------------------------------------------------------------------

local planner = Plan.new(recipes, matches)

local function plan(name, n, stock)
  return planner.plan(name, n, counts(stock))
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
      local got, key = fetch(stock, cell.ing, n, cell.slot)
      cell.key = key
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
    for _, cell in ipairs(cells) do flow(cell.key, -n) end
    flow(out, n * recipe.count)
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

-- The floppy holds 125 kB and an excavator's files come close: Lua goes on
-- without its comment lines and indentation (unless it has long strings,
-- which that could break).
local function slim(data)
  if data:find("[[", 1, true) then return data end
  local out = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    local s = line:match("^%s*(.-)$")
    if s ~= "" and not s:find("^%-%-") then out[#out + 1] = s end
  end
  return table.concat(out, "\n") .. "\n"
end

local function copyFile(from, to)
  local h = fs.open(from, "r")
  if not h then error("Missing " .. from .. " on the factory turtle", 0) end
  local data = h.readAll()
  h.close()
  if to:find("%.lua$") then data = slim(data) end
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

local function birth(jobName, ...)
  local job = jobs[jobName]
  local args = { ... }
  if not job then error("No job called " .. jobName .. " in lib/jobs.lua", 0) end
  -- A job with argKit names what its turtle is to work with in its
  -- arguments, as item=n. That isn't handed over here: it becomes the
  -- turtle's allowance at the loading bay (lib/bay.lua), which the birth
  -- spot is, so the newborn is loaded like any turtle that parks there.
  local jobKit = job.kit
  local allow, allowFuel
  if job.argKit then
    local rest = {}
    allow, allowFuel = {}, job.fuel
    for _, a in ipairs(args) do
      local item, n = tostring(a):match("^([%w_:]+)=(%d+)$")
      if item then
        item = recipes.resolve(item)
        if item == "minecraft:coal" or item == "minecraft:charcoal" then
          allowFuel = allowFuel + tonumber(n)
        else
          allow[item] = (allow[item] or 0) + tonumber(n)
        end
      else
        rest[#rest + 1] = a
      end
    end
    args = rest
  end
  local disk = findDisk()
  if not disk then
    error("No floppy in a disk drive on the network. The drive goes next to the spot in front of the turtle.", 0)
  end
  if turtle.detect() then error("The birth spot in front of the turtle is taken", 0) end
  storeAll(scan())

  -- Kit items the factory can make (a bucket, say) are made first, into storage.
  for _, item in ipairs(jobKit) do
    local name, n = item[1], item[2]
    if not name:find("^%*") and recipes.get(name) then
      local have = 0
      for k, c in pairs(counts(scan())) do if k:match("^[^@]+") == name then have = have + c end end
      if have < n then
        -- The plan takes what's in stock first, so it's asked for all n:
        -- asking for the shortfall alone would be met from the same stock.
        local steps, missing = plan(name, n, scan())
        local _, miss = describe(steps, missing)
        if #miss == 0 then
          for _, s in ipairs(steps) do
            print(("Crafting %s x%d for the kit"):format(short(s.recipe.name), s.crafts))
            craftStep(s.recipe, s.crafts)
          end
        end
      end
    end
  end

  -- Check everything first, so a birth never stops halfway.
  local stock = scan()
  local steps, missing = plan(job.unit, 1, stock)
  local have = counts(stock)
  -- Kit items match by name whatever their item data (some modded buckets carry some).
  local kit = {}
  for _, item in ipairs(jobKit) do
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
  if not fuel and not allow then missing["minecraft:charcoal"] = job.fuel end
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
  if job.blueprintArg and args[1] then
    local file = "blueprints/" .. args[1] .. ".lua"
    copyFile("/" .. file, disk .. "/files/" .. file)
  end
  local h = fs.open(disk .. "/job", "w")
  h.write(textutils.serialise({ program = job.program, args = #args > 0 and args or job.args or {} }))
  h.close()

  -- Its allowance is on the ledger before the turtle exists: whatever
  -- happens from here, the first new turtle in the bay is loaded with it.
  if allow then Bay.add("next", allow, allowFuel) end

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
  if allow then
    peripheral.call("front", "turnOn")
    writeLastBirth()
    print(("Born: a %s for the %s job; the bay loads it"):format(short(job.unit), jobName))
    return true
  end

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

-- The chest station (blueprints/station.lua, from design/station.mjs): the
-- turtle labelled Porter is loaded here, its chests first, then plain
-- Factory Blocks, made as it goes as far as iron and stone allow, until the
-- station has all it needs. What's been handed over is kept in /.station.
local STATION, GIVEN = "/blueprints/station.lua", "/.station"
local PORTER_LOAD = 13 * 64 -- leaves it room for fuel and odds and ends

-- Hands up to n of an item to the turtle in front, as many as it has room
-- for; the rest goes back into storage. Returns how many went over.
local function giveSome(name, n)
  local gone = 0
  -- Anything already in the turtle (handed back by the one in front, say)
  -- would go over with it: put that away first.
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      storeAll(scan())
      break
    end
  end
  while gone < n do
    local got = fetch(scan(), name, n - gone)
    if got == 0 then break end
    local full = false
    for slot = 1, 16 do
      local c = turtle.getItemCount(slot)
      if c > 0 then
        -- Only into a turtle: with the spot empty a drop throws the items
        -- on the floor (a turtle that left with half its load).
        local there, b = turtle.inspect()
        if not (there and b.name:find("^computercraft:turtle")) then
          full = true
          break
        end
        turtle.select(slot)
        turtle.drop()
        gone = gone + c - turtle.getItemCount(slot)
        if turtle.getItemCount(slot) > 0 then full = true end
      end
    end
    turtle.select(1)
    if full then
      storeAll(scan())
      break
    end
  end
  return gone
end

local function porterLoad()
  if not fs.exists(STATION) then return nil end
  local okL, label = pcall(peripheral.call, "front", "getLabel")
  if not okL or label ~= "Porter" then return nil end
  local h = fs.open(STATION, "r")
  local station = load(h.readAll())()
  h.close()
  local given = { chests = 0, blocks = 0 }
  if fs.exists(GIVEN) then
    local g = fs.open(GIVEN, "r")
    given = textutils.unserialise(g.readAll()) or given
    g.close()
  end
  local function saveGiven()
    local g = fs.open(GIVEN, "w")
    g.write(textutils.serialise(given))
    g.close()
  end
  local total = 0
  for _, c in ipairs(station.chests) do total = total + c.n end
  local function have(name)
    local n = 0
    for k, c in pairs(counts(scan())) do if k:match("^[^@]+") == name then n = n + c end end
    return n
  end
  local function make(name, n)
    local steps, missing = plan(name, n, scan())
    local _, miss = describe(steps, missing)
    if #miss > 0 then return false end
    for _, s in ipairs(steps) do craftStep(s.recipe, s.crafts) end
    return true
  end
  if given.chests < #station.chests then
    local n = #station.chests - given.chests
    if have("minecraft:chest") < n and not make("minecraft:chest", n) then return "Station: can't make the chests" end
    give("minecraft:chest", n)
    given.chests = given.chests + n
    saveGiven()
    return ("Station: gave the porter %d chests"):format(n)
  end
  local left = total - given.blocks
  if left <= 0 then return nil end
  local load = math.min(left, PORTER_LOAD)
  local got = have(station.item)
  if got < load then
    -- As many as the iron and stone allow.
    local c = counts(scan())
    local crafts = math.floor(math.min(c["minecraft:iron_ingot"] or 0, c["minecraft:stone"] or 0) / 4)
    load = math.min(load, got + crafts * 32)
    if load > got then
      -- A craft that fails halfway (stock moved meanwhile) mustn't stop the
      -- round: give what there is.
      local okM, made = pcall(make, station.item, load)
      if not (okM and made) then
        storeAll(scan())
        load = have(station.item)
      end
    end
  end
  if load <= 0 then return "Station: out of iron or stone for Factory Blocks" end
  -- A porter with no room left (still carrying its last load) gets nothing,
  -- and then the round goes on to give it fuel.
  local went = giveSome(station.item, load)
  if went == 0 then return nil end
  given.blocks = given.blocks + went
  saveGiven()
  return ("Station: gave the porter %d Factory Blocks (%d of %d)"):format(went, given.blocks, total)
end

-- Moving out: the turtle labelled Mover (programs/movestore.lua) is loaded
-- on the birth spot with what's in storage, fuel first, MOVER_SLOTS stacks
-- a visit, until all of it has gone but what's over an item's cap.
-- /.factory/evacuate: { caps = { [item] = n }, moved = { [key] = n }, done }
local EVACUATE = "/.factory/evacuate"
local MOVER_SLOTS = 15 -- one slot of its own, for fuel it finds it needs
local DEFAULT_CAPS = { ["minecraft:cobblestone"] = 3000 }

local function readEvacuate()
  local h = fs.open(EVACUATE, "r")
  if not h then return nil end
  local ev = textutils.unserialise(h.readAll())
  h.close()
  return ev
end

local function writeEvacuate(ev)
  local h = fs.open(EVACUATE, "w")
  h.write(textutils.serialise(ev))
  h.close()
end

-- What may still go, { { key, n } }, fuel first, then by name.
local function toCarry(ev, stock)
  local list = {}
  for key, s in pairs(stock) do
    local cap = ev.caps[key:match("^[^@]+")]
    local n = cap and math.min(s.count, cap - (ev.moved[key] or 0)) or s.count
    if n > 0 then list[#list + 1] = { key = key, n = n } end
  end
  local function rank(e)
    for i, f in ipairs(FUELS) do if e.key == f then return i end end
    return #FUELS + 1
  end
  table.sort(list, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    return a.key < b.key
  end)
  return list
end

local function stacksOf(list)
  local n = 0
  for _, e in ipairs(list) do n = n + math.ceil(e.n / maxStack(e.key:match("^[^@]+"))) end
  return n
end

-- Returns false if there's no mover to load, else true and what it did.
local function moverLoad()
  local ev = readEvacuate()
  if not ev then return false end
  local okL, label = pcall(peripheral.call, "front", "getLabel")
  if not okL or label ~= "Mover" then return false end
  storeAll(scan())
  local stock = scan()
  local list = toCarry(ev, stock)
  if #list == 0 then
    if ev.done then return true, nil end
    ev.done = true
    writeEvacuate(ev)
    local left = {}
    for key, s in pairs(stock) do left[#left + 1] = ("%d %s"):format(s.count, short(key)) end
    table.sort(left)
    return true, "Evacuated: all of it has gone" .. (#left > 0 and ("; left behind " .. table.concat(left, ", ")) or "")
  end
  local stacks, items = 0, 0
  for _, e in ipairs(list) do
    local per = maxStack(e.key:match("^[^@]+"))
    while e.n > 0 and stacks < MOVER_SLOTS do
      local got = fetch(stock, e.key, math.min(e.n, per), 1)
      if got == 0 then break end
      turtle.select(1)
      turtle.drop()
      local dropped = got - turtle.getItemCount(1)
      turtle.select(1)
      if dropped > 0 then
        ev.moved[e.key] = (ev.moved[e.key] or 0) + dropped
        e.n, stacks, items = e.n - dropped, stacks + 1, items + dropped
      end
      if dropped < got then
        -- The mover is full.
        storeAll(stock)
        stacks = MOVER_SLOTS
      end
    end
    if stacks >= MOVER_SLOTS then break end
  end
  writeEvacuate(ev)
  if items == 0 then return true, nil end
  return true, ("Evacuating: gave the mover %d stacks (%d items), about %d stacks to go"):format(
    stacks, items, stacksOf(toCarry(ev, scan())))
end

---------------------------------------------------------------------------
-- The loading bay (lib/bay.lua): a turtle on the birth spot is on the
-- network, so storage pushes straight into it. Each visit: some fuel, then
-- its items as far as its allowance and its pockets go.
---------------------------------------------------------------------------

local BAY_FUEL = 48          -- fuel items a visit
local BAY_LOAD = 12 * 64     -- items a visit: four slots stay free for what it digs
local BAY_AGAIN = 45000      -- ms before the same turtle is served again
local bayServed = {}
local SIDES = { front = true, back = true, left = true, right = true, top = true, bottom = true }

-- A turtle nobody has named yet: no label, or the one its installer gives it.
local function isNewborn(label) return label == nil or tostring(label):find("^turtle%-%d+$") ~= nil end

-- The network name of the turtle with this computer id.
local function turtleName(id)
  for _, name in ipairs(peripheral.getNames()) do
    -- On the network, not the one it also sees straight in front of it.
    if name ~= self and not SIDES[name] and peripheral.hasType(name, "turtle") then
      local ok, got = pcall(peripheral.call, name, "getID")
      if ok and got == id then return name end
    end
  end
end

local function bayServe()
  local okI, id = pcall(peripheral.call, "front", "getID")
  if not okI or type(id) ~= "number" or id < 0 then return nil end
  local entry = Bay.get(id)
  if not entry then
    -- A newborn: no label yet, and an allowance waiting for it.
    local okL, label = pcall(peripheral.call, "front", "getLabel")
    if okL and isNewborn(label) then entry = Bay.adopt(id) end
    if not entry then return nil end
  end
  if os.epoch("utc") - (bayServed[id] or 0) < BAY_AGAIN then return nil end
  local name = turtleName(id)
  if not name then return nil end
  storeAll(scan())
  local stock = scan()
  -- What it's owed least of first: the few special things (chests, modems)
  -- get their slots before the bulk blocks fill the rest.
  local items = {}
  for item in pairs(entry.items) do items[#items + 1] = item end
  table.sort(items, function(a, b)
    if entry.items[a] ~= entry.items[b] then return entry.items[a] < entry.items[b] end
    return a < b
  end)
  -- First make what's short and can be made, a visit's worth: the turtle
  -- takes "nothing more is coming" as its sign to go, so nothing slow may
  -- happen once the first stack has gone over.
  local room = BAY_LOAD
  for _, item in ipairs(items) do
    local want = math.min(entry.items[item], room)
    if want > 0 and (stock[item] and stock[item].count or 0) < want and recipes.get(item) then
      local okP = pcall(function()
        local steps, missing = plan(item, want, stock)
        if next(missing) == nil then
          for _, s in ipairs(steps) do craftStep(s.recipe, s.crafts) end
        end
      end)
      if not okP then storeAll(scan()) end
      stock = scan()
    end
    room = room - math.ceil(want / 64) * 64
  end
  -- Pushes up to n of an item from storage into the turtle. Returns how
  -- many went, and whether that's all it will take (full, or gone).
  local function push(item, n)
    local moved = 0
    local s = stock[item]
    for _, at in ipairs(s and s.at or {}) do
      if moved >= n then break end
      if at.count > 0 then
        beat()
        local want = math.min(n - moved, at.count)
        local okP, got = pcall(peripheral.call, at.inv, "pushItems", name, at.slot, want)
        if not okP then return moved, true end -- it has left
        at.count, s.count, moved = at.count - got, s.count - got, moved + got
        flow(item, -got)
        if got < want then return moved, true end
      end
    end
    return moved, false
  end
  -- Then all of it in one go. Fuel first, while it surely has a slot for
  -- it, and every visit: fuel is a service, not a ration (a turtle that
  -- can't get back out of the hall is worth more than the coal).
  local said, full = {}, false
  for _, fuel in ipairs(FUELS) do
    local spare = (stock[fuel] and stock[fuel].count or 0) - STATION_RESERVE
    if spare > 0 then
      local got = push(fuel, math.min(spare, BAY_FUEL))
      if got > 0 then
        said[#said + 1] = ("%d %s"):format(got, short(fuel))
        break
      end
    end
  end
  if #said == 0 then said[1] = "no fuel (none to spare, or no free slot)" end
  room = BAY_LOAD
  for _, item in ipairs(items) do
    if full or room < 64 then break end
    local got
    got, full = push(item, math.min(entry.items[item], room))
    if got > 0 then
      entry.items[item] = entry.items[item] - got
      if entry.items[item] <= 0 then entry.items[item] = nil end
      room = room - math.ceil(got / 64) * 64
      said[#said + 1] = ("%d %s"):format(got, short(item))
    end
  end
  entry.fuel = nil
  Bay.set(id, entry)
  bayServed[id] = os.epoch("utc")
  return ("Bay: loaded #%d with %s (%d still to draw)"):format(id, table.concat(said, ", "), Bay.left(entry))
end

-- The bay's turn: true and what it did if the turtle in front is one the
-- ledger knows (or a newborn it has an allowance waiting for).
local function bayTurn()
  local ok, b = turtle.inspect()
  if not (ok and b.name:find("^computercraft:turtle")) then return false end
  -- A newborn left switched off (a birth cut short): on with it.
  local okOn, on = pcall(peripheral.call, "front", "isOn")
  if okOn and on == false then pcall(peripheral.call, "front", "turnOn") end
  local okB, id = pcall(peripheral.call, "front", "getID")
  if okB and type(id) == "number" then
    local okL, label = pcall(peripheral.call, "front", "getLabel")
    local ledger = Bay.read()
    if ledger[id] then
      -- What it handed back (a stack to keep a slot free) is in my own
      -- inventory: back on its ledger, and into storage.
      local back, n = {}, 0
      for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then
          n = n + it.count
          -- Fuel it had no use for is just stock again.
          local isFuel = false
          for _, f in ipairs(FUELS) do if it.name == f then isFuel = true end end
          if not isFuel then back[it.name] = (back[it.name] or 0) + it.count end
        end
      end
      if n > 0 then
        Bay.add(id, back, 0)
        storeAll(scan())
      end
    end
    if ledger[id] or (okL and isNewborn(label) and #ledger.next > 0) then return true, bayServe() end
  end
  return false
end

local function fuelStation()
  local ok, b = turtle.inspect()
  if not (ok and b.name:find("^computercraft:turtle")) then return nil end
  local mine, did = bayTurn()
  if mine then return did end
  local isMover, moved = moverLoad()
  if isMover then return moved end
  if os.epoch("utc") - lastBirth() < NEWBORN_GRACE then return nil end
  local loaded = porterLoad()
  if loaded then return loaded end
  -- A turtle asking for something in its label: "Tappet [need cobblestone 768]"
  -- (labels hold 32 characters, so minecraft: is left off).
  local okL, label = pcall(peripheral.call, "front", "getLabel")
  -- Short names (modem_block, cable, ...) go through the recipe aliases.
  local want, n = tostring(okL and label or ""):match("%[need ([%w_:]+) (%d+)%]")
  if want then want = recipes.resolve(want) end
  if want then
    local have = 0
    for k, c in pairs(counts(scan())) do if k:match("^[^@]+") == want then have = have + c end end
    n = math.min(tonumber(n), have)
    if n > 0 then
      give(want, n)
      return ("Fuel station: gave %d %s to %s"):format(n, short(want), label)
    end
  end
  local have = counts(scan())
  for _, fuel in ipairs(FUELS) do
    if (have[fuel] or 0) > STATION_RESERVE then
      -- A turtle with no room gets none, quietly, and the round goes on.
      if giveSome(fuel, math.min(STATION_GIVE, have[fuel] - STATION_RESERVE)) == 0 then return nil end
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
        flow(it.name, moved)
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
      if turtle.getItemCount(slot) == 0 and turtle.suckUp() then
        got = got + turtle.getItemCount(slot)
        flow(turtle.getItemDetail(slot).name, turtle.getItemCount(slot))
      end
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
      if s.count > 0 and matches(fuel, key) then
        s.key = key
        found[#found + 1] = s
      end
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

-- Adds what the furnaces hold (smelted, or about to be) to `have`, as its
-- output, and returns each furnace's slots. Without this every round would
-- load more for the same need.
local function furnaceHeld(have)
  local lists = {}
  for _, f in ipairs(furnaces) do
    beat()
    local slots = peripheral.call(f, "list")
    lists[f] = slots
    if slots[3] then have[slots[3].name] = (have[slots[3].name] or 0) + slots[3].count end
    if slots[1] then
      for _, job in ipairs(recipes.smelting) do
        if matches(job.input, slots[1].name) then
          have[job.output] = (have[job.output] or 0) + slots[1].count
          break
        end
      end
    end
  end
  return lists
end

-- Empties furnace outputs, tops up fuel, and loads inputs for whatever is
-- below its stock target. Returns a short summary, or nil if idle.
local function serviceFurnaces()
  if #furnaces == 0 then return nil end
  if readEvacuate() then
    -- Moving out: everything in them goes back into storage, to be carried.
    local moved = 0
    for _, f in ipairs(furnaces) do
      for slot in pairs(peripheral.call(f, "list")) do
        for _, name in ipairs(storage) do
          beat()
          moved = moved + peripheral.call(name, "pullItems", f, slot)
          if not peripheral.call(f, "list")[slot] then break end
        end
      end
    end
    return moved > 0 and ("Emptied the furnaces (%d items)"):format(moved) or nil
  end
  local stock = scan()
  local moved = {}
  if bootstrapFuel(stock) then
    moved[#moved + 1] = "8 planks for fuel"
    stock = scan()
  end
  local have = counts(stock)
  local lists = furnaceHeld(have)
  for _, f in ipairs(furnaces) do
    local slots = lists[f]
    if slots[3] then
      flow(slots[3].name, slots[3].count)
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
            if got > 0 then
              flow(s.key, -got)
              fuelled = true
              break
            end
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
        local need = math.max(job.keep, wants[job.output] or 0) - (have[job.output] or 0)
        if job.unless and (have[job.unless] or 0) > 64 then need = 0 end
        if need > 0 and spare > 0 then
          -- Straight from the chest into the furnace, up to a stack: what's
          -- still needed is shared out as the furnaces come round.
          local want = math.min(64, spare, math.max(8, need))
          local got, key = 0, nil
          for k, st in pairs(stock) do
            if matches(job.input, k) then
              for _, at in ipairs(st.at) do
                if got >= want then break end
                if at.count > 0 then
                  beat()
                  local n = peripheral.call(at.inv, "pushItems", f, at.slot, math.min(want - got, at.count), 1)
                  at.count, st.count, got = at.count - n, st.count - n, got + n
                  if n > 0 then key = k end
                end
              end
              -- One kind in the input slot at a time.
              if got > 0 then break end
            end
          end
          if got > 0 then
            flow(key, -got)
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

-- Squeezes what there's too much of (recipes.compacting): one kind a round,
-- up to 64 crafts. Returns what it did, or nil.
local function compact()
  local have = counts(scan())
  for _, c in ipairs(recipes.compacting or {}) do
    local n = math.min(64, math.floor(((have[c.item] or 0) - c.keep) / 9))
    if n > 0 then
      -- The plan takes what's in stock first: ask for what's there and n more.
      local steps, missing = plan(c.into, (have[c.into] or 0) + n, scan())
      local _, miss = describe(steps, missing)
      if #miss == 0 then
        for _, s in ipairs(steps) do craftStep(s.recipe, s.crafts) end
        return ("Compacted %d %s into %d %s"):format(n * 9, short(c.item), n, short(c.into))
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Orders (lib/orders.lua): each round the oldest unfinished one that can
-- get on is worked on; one that's waiting for something doesn't hold up
-- those behind it. Their smelts become furnace targets, what can be crafted
-- now is crafted a chunk at a time, and what's missing is what it waits for.
---------------------------------------------------------------------------

local ORDER_CHUNK = 256 -- items a round, so the furnaces keep being served
local BIRTH_RETRY = 60000
local lastBirthTry = 0
local ORDER_REST = 300000 -- ms an order that failed is left alone
local orderRest = {}

local function orderState(o, state, quiet)
  if o.state == state then return end
  Orders.update(o.id, { state = state })
  if not quiet then print(("Order %d (%s): %s"):format(o.id, Orders.label(o), state)) end
end

local function orderDone(o, what)
  Orders.update(o.id, { done = true, state = "done", left = 0 })
  print(("Order %d done: %s"):format(o.id, what or Orders.label(o)))
  return true
end

-- The most of an item that can be had by crafting now, from lo (which is
-- known to work) up to hi.
local function craftable(item, lo, hi, have)
  local function fine(k)
    local _, missing = planner.plan(item, k, have)
    return next(missing) == nil
  end
  if hi <= lo or fine(hi) then return math.max(lo, hi) end
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if fine(mid) then lo = mid else hi = mid end
  end
  return lo
end

local function waitingFor(tree)
  local parts = {}
  for item, n in pairs(tree.raws) do parts[#parts + 1] = { item = item, n = n } end
  table.sort(parts, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.item < b.item
  end)
  local out = {}
  for i = 1, math.min(3, #parts) do out[i] = ("%d %s"):format(parts[i].n, short(parts[i].item)) end
  if #out > 0 then return "waiting for " .. table.concat(out, ", ") end
  return "smelting"
end

-- Works on one order. have: what's in storage; soon: that and what the
-- furnaces hold. True if it got something done (storage has changed).
local function serviceOrder(o, have, soon)
  if o.birth and not jobs[o.birth] then
    Orders.update(o.id, { done = true, state = "no such job" })
    return false
  end
  local item = o.birth and jobs[o.birth].unit or recipes.resolve(o.item)
  local goal = o.birth and 1 or (o.keep and o.n or o.left)
  -- The tree counts what's in the furnaces as on its way; crafting below
  -- only what's in storage.
  local tree = planner.tree(item, goal, soon)
  for _, m in ipairs(tree.smelts) do
    wants[m.output] = math.max(wants[m.output] or 0, (soon[m.output] or 0) + m.n)
  end

  if o.birth then
    if next(tree.raws) or tree.smeltCount > 0 then return orderState(o, waitingFor(tree)) end
    if next((select(2, planner.plan(item, 1, have)))) then return orderState(o, "smelting") end
    if os.epoch("utc") - lastBirthTry < BIRTH_RETRY then return false end
    lastBirthTry = os.epoch("utc")
    local ok, res = pcall(birth, o.birth, table.unpack(o.args or {}))
    if ok and res then
      orderDone(o, "born a turtle for the " .. o.birth .. " job")
      lastBirthTry = 0 -- the next one may follow at once
    else
      orderState(o, ok and "waiting for its kit or fuel" or tostring(res))
    end
    return true
  end

  local base = o.keep and (have[item] or 0) or 0
  if o.keep and base >= o.n then return orderDone(o) end
  local k = craftable(item, base, math.min(goal, base + ORDER_CHUNK), have)
  if k <= base then return orderState(o, waitingFor(tree)) end
  local recipe = recipes.get(item)
  for _, s in ipairs((planner.plan(item, k, have))) do craftStep(s.recipe, s.crafts) end
  if o.keep then
    if k >= o.n then return orderDone(o) end
    orderState(o, ("%d of %d"):format(k, o.n), true)
    return true
  end
  -- Deliver: direct recipes drop their results in the output chest as
  -- they're made; the rest is fetched and dropped, as far as there's room.
  local dropped, full = recipe and recipe.direct and k or 0, false
  local want = recipe and recipe.direct and 0 or k
  while want > 0 and not full do
    local got = fetch(scan(), item, math.min(want, 64 * 16))
    if got == 0 then break end
    for slot = 1, 16 do
      local c = turtle.getItemCount(slot)
      if c > 0 then
        turtle.select(slot)
        turtle.dropDown()
        dropped = dropped + c - turtle.getItemCount(slot)
        if turtle.getItemCount(slot) > 0 then full = true end
      end
    end
    want = want - got
  end
  turtle.select(1)
  storeAll(scan())
  flow(item, -dropped)
  local left = o.left - dropped
  if left <= 0 then return orderDone(o) end
  Orders.update(o.id, { left = left })
  o.left = left
  orderState(o, full and "the output chest is full" or ("%d to go"):format(left), not full)
  return true
end

local function serviceOrders()
  local q = Orders.read()
  wants = {}
  if not Orders.head(q) then return end
  storeAll(scan())
  local have = counts(scan())
  local soon = {}
  for k, v in pairs(have) do soon[k] = v end
  furnaceHeld(soon)
  for _, o in ipairs(q.list) do
    if not o.done and os.epoch("utc") >= (orderRest[o.id] or 0) then
      -- One that fails (a craft that ran short) rests a while; the others go on.
      local ok, res = pcall(serviceOrder, o, have, soon)
      if not ok then
        orderRest[o.id] = os.epoch("utc") + ORDER_REST
        orderState(o, tostring(res))
        storeAll(scan())
        return
      end
      if res then return end
    end
  end
end

-- Once a minute: a storage snapshot for the rates, what the orders are
-- short of, and the balancer (lib/orders): gatherers the factory can birth
-- itself are queued, the rest is advice in /.factory/needs.
local RATES_FILE, NEEDS_FILE = "/.factory/rates", "/.factory/needs"

local function loadTable(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local t = textutils.unserialise(h.readAll())
  h.close()
  return t
end

local function saveTable(path, t)
  local h = fs.open(path, "w")
  h.write(textutils.serialise(t, { compact = true }))
  h.close()
end

-- Items a minute in and out; "#tag" sums every item with that tag.
local function flowsOf(r)
  return function(item)
    local tag = item:match("^#(.+)")
    if not tag then return r.inflow(item), r.outflow(item) end
    local inn, out = 0, 0
    for _, row in ipairs(r.report()) do
      if hasTag(row.item, tag) then inn, out = inn + row.inn, out + row.out end
    end
    return inn, out
  end
end

local function measure(have)
  rates.snapshot(nowS(), have)
  saveTable(RATES_FILE, rates.state())
  local q = Orders.read()
  local ranked = planner.rank(Orders.pending(q, jobs), have)
  local advice, births = Orders.balance(Rates, ranked, have, flowsOf(rates), jobs, q, os.epoch("utc"))
  for _, job in ipairs(births) do
    local o = Orders.add({ birth = job, by = "balancer" })
    print(("Balancer: queued a %s (order %d)"):format(job, o.id))
  end
  local rows = {}
  for _, r in ipairs(ranked) do rows[#rows + 1] = { item = r.item, n = r.n } end
  saveTable(NEEDS_FILE, { at = os.epoch("utc"), rows = rows, advice = advice })
end

-- Opens compressed blocks again when what they're made of runs low
-- (recipes.expanding): one kind a round. Returns what it did, or nil.
local function expand()
  local have = counts(scan())
  for _, e in ipairs(recipes.expanding or {}) do
    local n = math.min(64, have[e.item] or 0)
    if (have[e.into] or 0) < e.below and n > 0 then
      craftStep({ name = e.into, pattern = { "C" }, key = { C = e.item }, count = 9 }, n)
      return ("Opened %d %s into %d %s"):format(n, short(e.item), n * 9, short(e.into))
    end
  end
  return nil
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
elseif cmd == "tree" and a1 then
  local stock = locked(scan)
  local tree = planner.tree(a1, n, counts(stock))
  for _, l in ipairs(Plan.lines(tree, { furnaces = #furnaces, chests = #storage })) do print(l) end
elseif cmd == "craft" and a1 then
  if not recipes.get(a1) then error("No recipe for " .. a1 .. " (see: factory recipes)", 0) end
  return locked(craft, a1, n)
elseif cmd == "birth" and a1 then
  return locked(birth, a1, select(3, ...))
elseif cmd == "get" and a1 then
  return locked(get, a1, n)
elseif cmd == "input" and a1 then
  local set = inputNames()
  local list = {}
  for name in pairs(set) do list[#list + 1] = name end
  if a1 == "clear" then
    list = {}
  elseif a1 == "all" then
    -- Every storage chest now: chests joined to the network later take it all.
    for _, name in ipairs(storage) do if not set[name] then list[#list + 1] = name end end
  elseif not set[a1] then
    list[#list + 1] = a1
  end
  table.sort(list)
  local h = fs.open(INPUTS_FILE, "w")
  h.write(textutils.serialise(list))
  h.close()
  print("Input chests: " .. (#list > 0 and table.concat(list, ", ") or "none"))
elseif cmd == "evacuate" then
  if a1 == "off" then
    fs.delete(EVACUATE)
    print("Not evacuating")
    return true
  end
  local ev = readEvacuate()
  if a1 == "on" then
    ev = { caps = {}, moved = {} }
    local custom = false
    for i = 3, select("#", ...) do
      local item, cap = select(i, ...):match("^(.+)=(%d+)$")
      if item then ev.caps[recipes.resolve(item)], custom = tonumber(cap), true end
    end
    if not custom then for k, v in pairs(DEFAULT_CAPS) do ev.caps[k] = v end end
    writeEvacuate(ev)
  end
  if not ev then
    print("Not evacuating (factory evacuate on)")
    return false
  end
  local list = toCarry(ev, locked(scan))
  local caps = {}
  for k, v in pairs(ev.caps) do caps[#caps + 1] = ("%s at most %d"):format(short(k), v) end
  table.sort(caps)
  print(("Evacuating: %d kinds, about %d stacks to go%s"):format(#list, stacksOf(list),
    #caps > 0 and (" (" .. table.concat(caps, ", ") .. ")") or ""))
  return true
elseif cmd == "order" and a1 then
  local o
  if a1 == "cancel" then
    o = Orders.update(tonumber(a2) or -1, { done = true, state = "cancelled" })
    print(o and ("Cancelled order %d (%s)"):format(o.id, Orders.label(o)) or "No such order")
    return o ~= nil
  elseif a1 == "birth" then
    if not jobs[a2 or ""] then error("No job called " .. tostring(a2) .. " in lib/jobs.lua", 0) end
    o = Orders.add({ birth = a2, args = { select(4, ...) } })
  else
    local keep = select(4, ...) == "keep"
    local recipe = recipes.get(a1)
    if keep and recipe and recipe.direct then error("Can't keep " .. a1 .. " in stock: it's made straight into the output chest", 0) end
    o = Orders.add({ item = recipes.resolve(a1), n = n, left = n, keep = keep or nil })
  end
  print(("Order %d: %s"):format(o.id, Orders.label(o)))
  return o.id
elseif cmd == "allow" then
  if a1 then
    local id = tonumber(a1) or (a1 == "next" and "next")
    if not id then error("Usage: factory allow [id|next item=n ...]", 0) end
    local items, fuel = {}, 0
    for i = 3, select("#", ...) do
      local item, c = tostring(select(i, ...)):match("^([%w_:]+)=(%d+)$")
      if item then
        item = recipes.resolve(item)
        if item == "minecraft:coal" or item == "minecraft:charcoal" then fuel = fuel + tonumber(c)
        else items[item] = (items[item] or 0) + tonumber(c) end
      end
    end
    Bay.add(id, items, fuel)
  end
  local ledger = Bay.read()
  local function line(who, entry)
    local parts = {}
    for item, c in pairs(entry.items) do parts[#parts + 1] = ("%d %s"):format(c, short(item)) end
    table.sort(parts)
    print(("%s: %s"):format(who, #parts > 0 and table.concat(parts, ", ") or "nothing"))
  end
  local ids = {}
  for id in pairs(ledger) do if type(id) == "number" then ids[#ids + 1] = id end end
  table.sort(ids)
  for _, id in ipairs(ids) do line("#" .. id, ledger[id]) end
  for i, entry in ipairs(ledger.next) do line("newborn " .. i, entry) end
  if #ids == 0 and #ledger.next == 0 then print("No allowances") end
elseif cmd == "orders" then
  local q = Orders.read()
  for _, o in ipairs(q.list) do
    print(("#%d %s: %s"):format(o.id, Orders.label(o), o.state or "queued"))
  end
  if #q.list == 0 then print("No orders") end
elseif cmd == "flow" then
  local r = Rates.new(nil, loadTable(RATES_FILE))
  local rows = {}
  for _, row in ipairs(r.report()) do
    if row.inn > 0 or row.out > 0 then rows[#rows + 1] = row end
  end
  table.sort(rows, function(x, y) return x.inn + x.out > y.inn + y.out end)
  print("FLOW /min          in    out    net")
  for i = 1, math.min(15, #rows) do
    local row = rows[i]
    print(("%-14s %6.1f %6.1f %+6.1f"):format(short(row.item):sub(1, 14), row.inn, row.out, row.net or 0))
  end
  if #rows == 0 then print("No flows measured yet (factory run records them)") end
  local needs = loadTable(NEEDS_FILE)
  for _, a in ipairs(needs and needs.advice or {}) do
    if a.action == "add" then
      print(("%s: %.1f/min short, add %d %s"):format(short(a.item), a.gap, a.count, a.job or "gatherer"))
    elseif a.action == "slow" then
      print(("%s: %.1f/min short, no gatherer for it"):format(short(a.item), a.gap))
    elseif a.action == "cut" then
      print(("%s: over its cap and growing"):format(short(a.item)))
    end
  end
elseif cmd == "store" then
  print(("Stored %d items"):format(locked(intake)))
elseif cmd == "smelt" then
  print(locked(serviceFurnaces) or "Furnaces idle")
elseif cmd == "compact" then
  local err = connect()
  if err then print(err) return false end
  print(locked(compact) or "Nothing to compact")
elseif cmd == "run" then
  -- Runs unattended, so it never gives up: it waits for the network after a
  -- reboot and reports errors (a chest unloading, storage full) then retries.
  local interval = tonumber(a1) or 10
  local STOCK_EVERY = 60000
  local lastStock = -STOCK_EVERY
  local lastErr
  rates = Rates.new(nil, loadTable(RATES_FILE))
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
        -- The bay first, and again further down: a turtle standing there is
        -- a turtle not working.
        local _, loaded = locked(bayTurn)
        if loaded then print(loaded) end
        -- An order that fails (a wrong recipe, say) mustn't stop the rest.
        local orderOk, orderErr = pcall(locked, serviceOrders)
        if not orderOk then
          local o = Orders.head(Orders.read())
          if o then orderState(o, tostring(orderErr)) else report(orderErr) end
        end
        locked(serviceFurnaces)
        local given = locked(fuelStation)
        if given then print(given) end
        local compacted = locked(compact)
        if compacted then print(compacted) end
        local opened = locked(expand)
        if opened then print(opened) end
        if os.epoch("utc") - lastStock >= STOCK_EVERY then
          local stock = locked(scan)
          measure(counts(stock))
          print(stockLine(stock))
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
  print("Usage: factory stock|plan|tree|craft|get|order|orders|allow|flow|store|smelt|compact|run|birth|input|evacuate|recipes")
end
