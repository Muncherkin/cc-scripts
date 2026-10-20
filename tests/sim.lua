-- Minimal CC: Tweaked turtle simulator for testing programs offline.
-- Provides turtle, fs, textutils, sleep, os.epoch and print capture on top of
-- a voxel world. Not complete: only what our programs use.

local sim = {}

local function key(x, y, z) return x .. "," .. y .. "," .. z end

---------------------------------------------------------------------------
-- Blocks and items
---------------------------------------------------------------------------

sim.BLOCKS = {
  ["minecraft:stone"] = { drop = "minecraft:cobblestone" },
  ["minecraft:deepslate"] = { drop = "minecraft:cobbled_deepslate" },
  ["minecraft:dirt"] = { drop = "minecraft:dirt" },
  ["minecraft:gravel"] = { drop = "minecraft:gravel", falls = true },
  ["minecraft:bedrock"] = { unbreakable = true },
  ["minecraft:iron_ore"] = { drop = "minecraft:raw_iron", tags = { ["c:ores"] = true } },
  ["minecraft:coal_ore"] = { drop = "minecraft:coal", tags = { ["c:ores"] = true } },
  ["minecraft:diamond_ore"] = { drop = "minecraft:diamond", tags = { ["c:ores"] = true } },
  ["minecraft:lava"] = { fluid = true },
  ["minecraft:water"] = { fluid = true },
  ["minecraft:chest"] = { drop = "minecraft:chest", container = true },
}
-- Generated mod ores, each with its own drop, to fill inventories quickly.
for i = 1, 40 do
  sim.BLOCKS["mod:ore" .. i] = { drop = "mod:raw" .. i, tags = { ["c:ores"] = true } }
end

sim.ITEM_TAGS = {
  ["minecraft:cobblestone"] = { ["c:cobblestones"] = true, ["minecraft:stone_crafting_materials"] = true },
  ["minecraft:cobbled_deepslate"] = { ["c:cobblestones"] = true },
  ["minecraft:dirt"] = { ["minecraft:dirt"] = true },
  ["minecraft:gravel"] = { ["c:gravels"] = true },
  ["minecraft:chest"] = { ["c:chests"] = true },
}

local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:lava_bucket"] = 1000 }

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------

function sim.newWorld(generate)
  local w = { blocks = {}, containers = {}, generate = generate, spilled = {} }
  function w.get(x, y, z)
    local b = w.blocks[key(x, y, z)]
    if b == nil then
      b = generate(x, y, z) or false
      w.blocks[key(x, y, z)] = b
    end
    return b or nil
  end
  function w.set(x, y, z, b) w.blocks[key(x, y, z)] = b or false end
  return w
end

local function isSolid(b) return b ~= nil and not sim.BLOCKS[b.name].fluid end

---------------------------------------------------------------------------
-- Turtle
---------------------------------------------------------------------------

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

function sim.newTurtle(world, opts)
  local t = {
    x = 0, y = 0, z = 0, dir = 0, fuel = opts.fuel or 100, limit = 20000,
    inv = {}, selected = 1, left = opts.left, right = opts.right,
    moves = 0, crashAt = opts.crashAt,
  }
  for s, item in pairs(opts.inventory or {}) do t.inv[s] = { name = item[1], count = item[2] } end

  local function target(side)
    if side == "up" then return t.x, t.y + 1, t.z end
    if side == "down" then return t.x, t.y - 1, t.z end
    if side == "back" then return t.x - DX[t.dir], t.y, t.z - DZ[t.dir] end
    return t.x + DX[t.dir], t.y, t.z + DZ[t.dir]
  end

  local function addItem(name, count)
    for s = 1, 16 do
      local it = t.inv[s]
      if it and it.name == name and it.count < 64 then
        local n = math.min(count, 64 - it.count)
        it.count, count = it.count + n, count - n
      end
      if count == 0 then return end
    end
    for s = 1, 16 do
      if not t.inv[s] then
        t.inv[s] = { name = name, count = count }
        return
      end
    end
    world.spilled[name] = (world.spilled[name] or 0) + count
  end

  -- Gravel above a freshly emptied cell falls into it.
  local function settle(x, y, z)
    while true do
      local above = world.get(x, y + 1, z)
      if not (above and sim.BLOCKS[above.name].falls) or world.get(x, y, z) then return end
      world.set(x, y, z, above)
      world.set(x, y + 1, z, nil)
      y = y + 1
    end
  end

  local api = {}

  local function move(side)
    if t.fuel <= 0 then return false, "Out of fuel" end
    local x, y, z = target(side)
    if isSolid(world.get(x, y, z)) then return false, "Movement obstructed" end
    t.x, t.y, t.z = x, y, z
    t.fuel = t.fuel - 1
    t.moves = t.moves + 1
    if t.crashAt and t.moves == t.crashAt then
      t.crashAt = nil
      error("SIMULATED_REBOOT", 0) -- the move happened, the program never learns
    end
    return true
  end

  local function detect(side) return isSolid(world.get(target(side))) end

  local function inspect(side)
    local b = world.get(target(side))
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = b.state or {}, tags = sim.BLOCKS[b.name].tags or {} }
  end

  local function dig(side)
    local x, y, z = target(side)
    local b = world.get(x, y, z)
    if not isSolid(b) then return false, "Nothing to dig here" end
    local def = sim.BLOCKS[b.name]
    if def.unbreakable then return false, "Cannot break unbreakable block" end
    world.set(x, y, z, nil)
    if def.drop then addItem(def.drop, 1) end
    if def.container then
      for _, it in pairs(world.containers[key(x, y, z)] or {}) do addItem(it.name, it.count) end
    end
    settle(x, y, z)
    return true
  end

  local function place(side)
    local it = t.inv[t.selected]
    if not it then return false, "No items to place" end
    local x, y, z = target(side)
    local b = world.get(x, y, z)
    if it.name == "minecraft:bucket" then
      if b and b.name == "minecraft:lava" and (b.state or {}).level == 0 then
        world.set(x, y, z, nil)
        it.name = "minecraft:lava_bucket"
        return true
      end
      return false, "Cannot place item here"
    end
    if isSolid(b) or not sim.BLOCKS[it.name] then return false, "Cannot place block here" end
    world.set(x, y, z, { name = it.name })
    if sim.BLOCKS[it.name].container then world.containers[key(x, y, z)] = {} end
    it.count = it.count - 1
    if it.count == 0 then t.inv[t.selected] = nil end
    return true
  end

  local function drop(side, count)
    local it = t.inv[t.selected]
    if not it then return false, "No items to drop" end
    count = math.min(count or it.count, it.count)
    local x, y, z = target(side)
    local b = world.get(x, y, z)
    if b and sim.BLOCKS[b.name].container then
      table.insert(world.containers[key(x, y, z)], { name = it.name, count = count })
    else
      world.spilled[it.name] = (world.spilled[it.name] or 0) + count
    end
    it.count = it.count - count
    if it.count == 0 then t.inv[t.selected] = nil end
    return true
  end

  for _, side in ipairs({ "", "Up", "Down" }) do
    local s = side == "" and "front" or side:lower()
    api["detect" .. side] = function() return detect(s) end
    api["inspect" .. side] = function() return inspect(s) end
    api["dig" .. side] = function() return dig(s) end
    api["place" .. side] = function() return place(s) end
    api["drop" .. side] = function(n) return drop(s, n) end
    api["attack" .. side] = function() return false, "Nothing to attack here" end
  end
  api.forward = function() return move("front") end
  api.back = function() return move("back") end
  api.up = function() return move("up") end
  api.down = function() return move("down") end
  api.turnLeft = function() t.dir = (t.dir + 3) % 4 return true end
  api.turnRight = function() t.dir = (t.dir + 1) % 4 return true end
  api.select = function(s) t.selected = s return true end
  api.getSelectedSlot = function() return t.selected end
  api.getItemCount = function(s) return t.inv[s or t.selected] and t.inv[s or t.selected].count or 0 end
  api.getItemDetail = function(s, detailed)
    local it = t.inv[s or t.selected]
    if not it then return nil end
    local d = { name = it.name, count = it.count }
    if detailed then d.tags = sim.ITEM_TAGS[it.name] or {} end
    return d
  end
  api.getFuelLevel = function() return t.fuel end
  api.getFuelLimit = function() return t.limit end
  api.refuel = function(n)
    local it = t.inv[t.selected]
    if not it or not FUEL[it.name] then return false, "Items not combustible" end
    n = math.min(n or it.count, it.count)
    if it.name == "minecraft:lava_bucket" then
      t.fuel = t.fuel + 1000
      it.name = "minecraft:bucket"
      return true
    end
    t.fuel = t.fuel + FUEL[it.name] * n
    it.count = it.count - n
    if it.count == 0 then t.inv[t.selected] = nil end
    return true
  end
  api.getEquippedLeft = function() return t.left and { name = t.left } end
  api.getEquippedRight = function() return t.right and { name = t.right } end

  t.api = api
  t.addItem = addItem
  return t
end

---------------------------------------------------------------------------
-- Computer environment (fs, textutils, ...)
---------------------------------------------------------------------------

local function serialise(v, indent)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local ks = type(k) == "string" and ("[%q]"):format(k) or "[" .. tostring(k) .. "]"
      parts[#parts + 1] = ks .. "=" .. serialise(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return ("%q"):format(v)
  end
  return tostring(v)
end

function sim.newComputer()
  local files = {}
  local fsapi = {}
  function fsapi.exists(p) return files[p] ~= nil end
  function fsapi.delete(p) files[p] = nil end
  function fsapi.move(a, b) files[b] = files[a] files[a] = nil end
  function fsapi.getSize(p) return #(files[p] or "") end
  function fsapi.open(p, mode)
    if mode == "r" then
      if not files[p] then return nil end
      local content = files[p]
      return { readAll = function() return content end, close = function() end }
    end
    local buf = mode == "a" and (files[p] or "") or ""
    return {
      write = function(s) buf = buf .. s end,
      writeLine = function(s) buf = buf .. s .. "\n" end,
      close = function() files[p] = buf end,
    }
  end
  return { files = files, fs = fsapi }
end

-- Runs a program file in a fresh environment wired to the given turtle,
-- computer and output log. Returns ok, result-or-error.
function sim.run(path, turtle, computer, log, ...)
  local env = setmetatable({
    turtle = turtle.api,
    fs = computer.fs,
    textutils = {
      serialise = function(v) return serialise(v) end,
      unserialise = function(s) local f = load("return " .. s) return f and f() end,
    },
    sleep = function() end,
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      log[#log + 1] = table.concat(parts, "\t")
    end,
    printError = function(msg) log[#log + 1] = "ERROR: " .. tostring(msg) end,
  }, { __index = _G })
  local f = assert(loadfile(path, "t", env))
  return pcall(f, ...)
end

return sim
