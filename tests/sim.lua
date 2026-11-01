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
  ["minecraft:dirt"] = { drop = "minecraft:dirt", tags = { ["minecraft:dirt"] = true } },
  ["minecraft:snow_block"] = { drop = "minecraft:snowball" },
  ["regions_unexplored:pine_sapling"] = { drop = "regions_unexplored:pine_sapling" },
  ["regions_unexplored:pine_log"] = { drop = "regions_unexplored:pine_log", tags = { ["minecraft:logs"] = true } },
  ["regions_unexplored:pine_leaves"] = { drop = "regions_unexplored:pine_sapling" },
  ["regions_unexplored:pine_branch"] = { drop = "minecraft:stick" },
  ["minecraft:redstone_ore"] = { drop = "minecraft:redstone", tags = { ["c:ores"] = true } },
  ["minecraft:deepslate_gold_ore"] = { drop = "minecraft:raw_gold", tags = { ["c:ores"] = true } },
  ["minecraft:copper_ore"] = { drop = "minecraft:raw_copper", tags = { ["c:ores"] = true } },
  ["minecraft:cobblestone"] = { drop = "minecraft:cobblestone" },
  ["minecraft:oak_planks"] = { drop = "minecraft:oak_planks" },
  ["minecraft:gravel"] = { drop = "minecraft:gravel", falls = true },
  ["minecraft:bedrock"] = { unbreakable = true },
  ["minecraft:iron_ore"] = { drop = "minecraft:raw_iron", tags = { ["c:ores"] = true } },
  ["minecraft:coal_ore"] = { drop = "minecraft:coal", tags = { ["c:ores"] = true } },
  ["minecraft:diamond_ore"] = { drop = "minecraft:diamond", tags = { ["c:ores"] = true } },
  ["minecraft:lava"] = { fluid = true },
  ["minecraft:water"] = { fluid = true },
  ["minecraft:chest"] = { drop = "minecraft:chest", container = true },
  ["computercraft:turtle_normal"] = { drop = "computercraft:turtle_normal", container = true },
  ["computercraft:cable"] = { drop = "computercraft:cable" },
  ["minecraft:iron_bars"] = { drop = "minecraft:iron_bars" },
  ["waystones:waystone"] = { drop = "waystones:waystone" },
  ["computercraft:computer_normal"] = { drop = "computercraft:computer_normal" },
  ["minecraft:snow"] = { drop = "minecraft:snowball" },
  ["regions_unexplored:frozen_grass"] = {},
  ["minecraft:torch"] = {},
  ["forbidden_arcanus:stella_arcanum"] = { drop = "forbidden_arcanus:stella_arcanum" },
  ["minecraft:iron_door"] = { drop = "minecraft:iron_door" },
  ["factory_blocks:circuit"] = { drop = "factory_blocks:circuit" },
  ["functionalstorage:ender_drawer"] = { drop = "functionalstorage:ender_drawer", container = true, singleType = true },
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

local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800, ["minecraft:lava_bucket"] = 1000 }

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
    local b = world.get(x, y, z)
    -- A thin snow layer gives way: the turtle moves in and it's gone.
    if b and (b.name == "minecraft:snow" or b.name == "regions_unexplored:frozen_grass") then world.set(x, y, z, nil) b = nil end
    if isSolid(b) then return false, "Movement obstructed" end
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
    local fluid = ({ ["minecraft:lava_bucket"] = "minecraft:lava", ["minecraft:water_bucket"] = "minecraft:water" })[it.name]
    if fluid then
      if isSolid(b) then return false, "Cannot place item here" end
      world.set(x, y, z, { name = fluid, state = { level = 0 } })
      it.name = "minecraft:bucket"
      return true
    end
    -- Replaceable blocks (snow layers, grass) give way to a placed block.
    if (isSolid(b) and not sim.BLOCKS[b.name].replaceable) or not sim.BLOCKS[it.name] then
      return false, "Cannot place block here"
    end
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
      local items = world.containers[key(x, y, z)]
      -- Optional limit on stacks, set by tests: world.capacity["x,y,z"] = n
      local cap = world.capacity and world.capacity[key(x, y, z)]
      if cap and #items >= cap then return false, "No space for items" end
      -- Drawers hold one item type at a time.
      if sim.BLOCKS[b.name].singleType and items[1] and items[1].name ~= it.name then
        return false, "No space for items"
      end
      table.insert(items, { name = it.name, count = count })
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
  api.getItemSpace = function(s)
    local it = t.inv[s or t.selected]
    return it and sim.maxStack(it.name) - it.count or 64
  end
  -- Moves up to count items from the selected slot into slot `to`, if it is
  -- empty or holds the same item.
  api.transferTo = function(to, count)
    local from = t.inv[t.selected]
    if not from or to == t.selected then return false end
    local dest = t.inv[to]
    if dest and (dest.name ~= from.name or dest.nbt ~= from.nbt) then return false end
    local n = math.min(count or from.count, from.count, sim.maxStack(from.name) - (dest and dest.count or 0))
    if n <= 0 then return false end
    t.inv[to] = { name = from.name, count = (dest and dest.count or 0) + n, nbt = from.nbt }
    from.count = from.count - n
    if from.count == 0 then t.inv[t.selected] = nil end
    return true
  end
  api.getItemDetail = function(s, detailed)
    local it = t.inv[s or t.selected]
    if not it then return nil end
    local d = { name = it.name, count = it.count, nbt = it.nbt }
    if detailed then
      d.tags = sim.ITEM_TAGS[it.name] or {}
      d.maxCount = sim.maxStack(it.name)
    end
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
  -- Swaps the selected item with the upgrade on that side (either may be empty).
  local function equip(side)
    local it = t.inv[t.selected]
    if it and it.count > 1 then return false, "Not a valid upgrade" end
    local old = t[side]
    t[side] = it and it.name or nil
    t.inv[t.selected] = old and { name = old, count = 1 } or nil
    t.equips = (t.equips or 0) + 1
    return true
  end
  api.equipLeft = function() return equip("left") end
  api.equipRight = function() return equip("right") end

  -- Takes up to 64 items from the container on that side into the selected
  -- slot (or the next free one), like the real turtle.suck*.
  local function suck(side, count)
    local x, y, z = target(side)
    local items = world.containers[key(x, y, z)]
    if not items then return false, "No items to take" end
    -- Peripheral transfers leave empty entries behind (their slots stay put).
    while items[1] and items[1].count <= 0 do table.remove(items, 1) end
    if #items == 0 then return false, "No items to take" end
    local it = items[1]
    local slot = t.inv[t.selected] == nil and t.selected or nil
    for s = 1, 16 do if not slot and not t.inv[s] then slot = s end end
    if not slot then return false, "No space for items" end
    local n = math.min(count or 64, it.count, sim.maxStack(it.name))
    t.inv[slot] = { name = it.name, count = n, nbt = it.nbt }
    it.count = it.count - n
    if it.count == 0 then table.remove(items, 1) end
    return true
  end
  api.suck = function(n) return suck("front", n) end
  api.suckUp = function(n) return suck("up", n) end
  api.suckDown = function(n) return suck("down", n) end

  -- Crafts from the top-left 3x3 against sim.RECIPES (same format as
  -- programs/lib/recipes.lua). Every slot outside the grid must be empty.
  api.craft = function(limit)
    limit = limit or 64
    local grid = {}
    for s = 1, 16 do
      local r, c = math.floor((s - 1) / 4) + 1, (s - 1) % 4 + 1
      if t.inv[s] then
        if r > 3 or c > 3 then return false, "No matching recipes" end
        grid[#grid + 1] = { r = r, c = c, slot = s, item = t.inv[s] }
      end
    end
    if #grid == 0 then return false, "No matching recipes" end
    local r0, c0, r1, c1 = 9, 9, 0, 0
    for _, g in ipairs(grid) do
      r0, c0, r1, c1 = math.min(r0, g.r), math.min(c0, g.c), math.max(r1, g.r), math.max(c1, g.c)
    end
    local function fits(ing, item)
      if item.nbt then return false end
      if type(ing) == "string" then return ing == item.name end
      return (sim.ITEM_TAGS[item.name] or {})[ing.tag] == true
    end
    for _, recipe in ipairs(sim.RECIPES or {}) do
      local p = recipe.pattern
      local ok = #p == r1 - r0 + 1
      for i = 1, #p do ok = ok and #p[i] == c1 - c0 + 1 end
      local crafts = limit
      for i = 1, ok and #p or 0 do
        for j = 1, #p[i] do
          local ch = p[i]:sub(j, j)
          local item = t.inv[(r0 + i - 2) * 4 + c0 + j - 1]
          if ch == " " then
            ok = ok and item == nil
          else
            ok = ok and item ~= nil and fits(recipe.key[ch], item)
            if item then crafts = math.min(crafts, item.count) end
          end
        end
      end
      if ok then
        for _, g in ipairs(grid) do
          g.item.count = g.item.count - crafts
          if g.item.count == 0 then t.inv[g.slot] = nil end
        end
        local out = { name = recipe.output or recipe.name, count = crafts * recipe.count,
                      nbt = recipe.direct and "upgraded" or nil }
        local slot = t.inv[t.selected] == nil and t.selected or nil
        for s = 1, 16 do if not slot and not t.inv[s] then slot = s end end
        t.inv[slot] = out
        t.crafted = (t.crafted or 0) + crafts
        return true
      end
    end
    return false, "No matching recipes"
  end

  t.api = api
  t.addItem = addItem
  return t
end

---------------------------------------------------------------------------
-- Wired network: inventories (chests, furnaces, the turtle itself) behind a
-- modem, with the generic inventory API (list, pushItems, pullItems, ...)
---------------------------------------------------------------------------

sim.MAX_STACK = { ["minecraft:diamond_pickaxe"] = 1 }
function sim.maxStack(name) return sim.MAX_STACK[name] or 64 end

-- slots: { [slot] = { name, count, nbt? } }
function sim.newInventory(size, items, types)
  local inv = { size = size, slots = {}, types = types or { "minecraft:chest", "inventory" } }
  for s, item in pairs(items or {}) do inv.slots[s] = { name = item[1], count = item[2], nbt = item[3] } end
  return inv
end

-- Moves up to `limit` items from one inventory slot to another inventory,
-- into `toSlot` or merged/spread like a hopper. Returns how many moved.
local function transfer(from, fromSlot, to, limit, toSlot)
  local src = from.slots[fromSlot]
  if not src then return 0 end
  local left = math.min(limit or src.count, src.count)
  local moved = 0
  local function into(s)
    local dst = to.slots[s]
    local max = sim.maxStack(src.name)
    if dst and (dst.name ~= src.name or dst.nbt ~= src.nbt) then return end
    local n = math.min(left, max - (dst and dst.count or 0))
    if n <= 0 then return end
    to.slots[s] = { name = src.name, nbt = src.nbt, count = (dst and dst.count or 0) + n }
    left, moved = left - n, moved + n
  end
  if toSlot then
    into(toSlot)
  else
    for s = 1, to.size do if to.slots[s] then into(s) end end
    for s = 1, to.size do if left > 0 and not to.slots[s] then into(s) end end
  end
  src.count = src.count - moved
  if src.count == 0 then from.slots[fromSlot] = nil end
  return moved
end

-- Builds a `peripheral` API for a turtle whose wired modem sits on `side`.
-- `remotes` maps network names to inventories; the turtle joins the network
-- as `localName` (nil = modem switched off).
-- `locals` maps sides to extra directly attached peripherals: { api, types }.
-- A remote with an `api` field is a non-inventory peripheral (e.g. a drive).
function sim.newNetwork(turtle, remotes, localName, side, locals)
  locals = locals or {}
  side = side or "back"
  local all = {}
  for name, inv in pairs(remotes) do all[name] = inv end
  if localName then
    -- The turtle's own inventory, seen from the network.
    all[localName] = { size = 16, slots = turtle.inv, types = { "turtle", "inventory" } }
  end

  local function invApi(inv)
    local api = {}
    api.size = function() return inv.size end
    api.list = function()
      local l = {}
      for s, it in pairs(inv.slots) do l[s] = { name = it.name, count = it.count, nbt = it.nbt } end
      return l
    end
    api.getItemDetail = function(s)
      local it = inv.slots[s]
      if not it then return nil end
      return { name = it.name, count = it.count, nbt = it.nbt, maxCount = sim.maxStack(it.name),
               tags = sim.ITEM_TAGS[it.name] or {} }
    end
    api.pushItems = function(to, fromSlot, limit, toSlot)
      assert(all[to], "Target '" .. tostring(to) .. "' does not exist")
      return transfer(inv, fromSlot, all[to], limit, toSlot)
    end
    api.pullItems = function(from, fromSlot, limit, toSlot)
      assert(all[from], "Source '" .. tostring(from) .. "' does not exist")
      return transfer(all[from], fromSlot, inv, limit, toSlot)
    end
    return api
  end

  local modem = {
    isWireless = function() return false end,
    getNameLocal = function() return localName end,
    getNamesRemote = function()
      local names = {}
      for name in pairs(remotes) do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
  }

  local p = {}
  local function lookup(name)
    if name == side then return modem, { "modem" } end
    if locals[name] then return locals[name].api, locals[name].types end
    local inv = remotes[name]
    if inv and inv.api then return inv.api, inv.types end
    if inv then return invApi(inv), inv.types end
  end
  p.getNames = function()
    local names = { side }
    for n in pairs(locals) do names[#names + 1] = n end
    for _, n in ipairs(modem.getNamesRemote()) do names[#names + 1] = n end
    return names
  end
  p.wrap = function(name) return (lookup(name)) end
  p.hasType = function(name, ty)
    local _, types = lookup(name)
    for _, t in ipairs(types or {}) do if t == ty then return true end end
    return false
  end
  p.call = function(name, method, ...)
    local obj = lookup(name)
    assert(obj, "No peripheral " .. tostring(name))
    return obj[method](...)
  end
  -- Tests switch the modem on (a name) or off (nil) mid-run.
  p.setLocalName = function(name)
    if localName then all[localName] = nil end
    localName = name
    if name then all[name] = { size = 16, slots = turtle.inv, types = { "turtle", "inventory" } } end
  end
  return p
end

-- Finishes whatever each furnace is smelting (slot 1 -> slot 3, one fuel
-- item per 8 smelts).
function sim.smelt(furnace, outputs)
  local input, fuel = furnace.slots[1], furnace.slots[2]
  if not input or not fuel then return end
  local out = outputs[input.name]
  local n = math.min(input.count, fuel.count * 8)
  furnace.slots[3] = { name = out, count = (furnace.slots[3] and furnace.slots[3].count or 0) + n }
  input.count = input.count - n
  if input.count == 0 then furnace.slots[1] = nil end
  fuel.count = fuel.count - math.ceil(n / 8)
  if fuel.count == 0 then furnace.slots[2] = nil end
end

-- Inventories next to a turtle as peripherals named by side ("top",
-- "bottom", "front", "back", "left", "right"), backed by world containers.
-- Slots are the container's entries; pushItems leaves emptied entries in
-- place so slot numbers don't shift.
function sim.sidePeripherals(world, t)
  local function cell(side)
    local dx, dz = DX[t.dir], DZ[t.dir]
    if side == "top" then return t.x, t.y + 1, t.z end
    if side == "bottom" then return t.x, t.y - 1, t.z end
    if side == "front" then return t.x + dx, t.y, t.z + dz end
    if side == "back" then return t.x - dx, t.y, t.z - dz end
    local r = (t.dir + 1) % 4
    if side == "right" then return t.x + DX[r], t.y, t.z + DZ[r] end
    return t.x - DX[r], t.y, t.z - DZ[r]
  end
  local function items(side)
    local x, y, z = cell(side)
    return world.containers[key(x, y, z)]
  end
  local p = {}
  p.hasType = function(side, ty) return ty == "inventory" and items(side) ~= nil end
  p.call = function(side, method, ...)
    local inv = items(side)
    if not inv then error("No peripheral " .. side, 0) end
    if method == "list" then
      local l = {}
      for i, it in ipairs(inv) do if it.count > 0 then l[i] = { name = it.name, count = it.count } end end
      return l
    elseif method == "pushItems" then
      local to, slot, limit = ...
      local dst = items(to)
      if not dst then error("Target '" .. to .. "' does not exist", 0) end
      local src = inv[slot]
      if not src or src.count <= 0 then return 0 end
      local n = math.min(limit or src.count, src.count, sim.maxStack(src.name))
      dst[#dst + 1] = { name = src.name, count = n }
      src.count = src.count - n
      return n
    end
    error("No such method " .. tostring(method), 0)
  end
  return p
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
  local function norm(p) return "/" .. p:gsub("^/+", ""):gsub("/+$", "") end
  function fsapi.getDir(p) return (norm(p):match("^/(.*)/[^/]*$")) or "" end
  function fsapi.isDir(p)
    local prefix = norm(p) .. "/"
    for name in pairs(files) do if name:sub(1, #prefix) == prefix then return true end end
    return false
  end
  -- Folders exist too, as in CC.
  function fsapi.exists(p) return files[p] ~= nil or fsapi.isDir(p) end
  function fsapi.list(p)
    local prefix, seen, out = norm(p) == "/" and "/" or norm(p) .. "/", {}, {}
    for name in pairs(files) do
      if name:sub(1, #prefix) == prefix then
        local child = name:sub(#prefix + 1):match("^[^/]+")
        if child and not seen[child] then seen[child] = true out[#out + 1] = child end
      end
    end
    if #out == 0 and not fsapi.isDir(p) then error(p .. ": Not a directory", 2) end
    table.sort(out)
    return out
  end
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
  local clock = 1700000000000 -- a realistic epoch, so "long ago" checks work
  local timers = {}
  local env = setmetatable({
    turtle = turtle.api,
    fs = computer.fs,
    peripheral = computer.peripheral,
    os = setmetatable({
      epoch = function() clock = clock + 1 return clock end,
      reboot = function() error("SIMULATED_REBOOT", 0) end,
      clock = computer.clock or os.clock,
      -- Yielding to the event loop (queueEvent("yield") then
      -- pullEvent("yield")): nothing else runs in the simulator. Waiting for
      -- any other event would never end, so that stays an error.
      queueEvent = function() end,
      -- Timers fire at once, advancing the test's clock through its sleep;
      -- tests queue other events (bridge pushes) in computer.events.
      startTimer = function(t)
        timers[#timers + 1] = { id = #timers + 1000, t = t }
        return timers[#timers].id
      end,
      pullEvent = function(filter)
        if filter == "yield" then return filter end
        if computer.events and #computer.events > 0 and not filter then
          return table.unpack(table.remove(computer.events, 1))
        end
        local tm = table.remove(timers, 1)
        if tm and (not filter or filter == "timer") then
          if computer.sleep then computer.sleep(tm.t) end
          return "timer", tm.id
        end
        error("os.pullEvent(" .. tostring(filter) .. ") would wait for ever in the simulator", 2)
      end,
    }, { __index = os }),
    textutils = {
      serialise = function(v) return serialise(v) end,
      unserialise = function(s) local f = load("return " .. s) return f and f() end,
    },
    sleep = computer.sleep or function() end,
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      log[#log + 1] = table.concat(parts, "\t")
    end,
    printError = function(msg) log[#log + 1] = "ERROR: " .. tostring(msg) end,
  }, { __index = _G })
  -- Extra globals a test provides (shell, settings, http, ...).
  for k, v in pairs(computer.globals or {}) do env[k] = v end
  -- Like CC's require: modules from programs/ load into the program's own
  -- environment (so lib/nav sees the simulated turtle), once per run.
  local loaded = {}
  env.require = function(name)
    if loaded[name] == nil then
      local file = "programs/" .. name:gsub("%.", "/") .. ".lua"
      local mod = loadfile(file, "t", env)
      if not mod then return require(name) end
      loaded[name] = mod() or true
    end
    return loaded[name]
  end
  local f = assert(loadfile(path, "t", env))
  return pcall(f, ...)
end

return sim
