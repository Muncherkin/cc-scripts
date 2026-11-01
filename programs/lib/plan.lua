-- Crafting plans: what making n of an item takes, worked out on a copy of
-- the stock counts. The factory uses it to craft and to check births; the
-- `recipe` program asks for the whole tree, down to raw materials, smelts,
-- fuel and a time.
--
--   local planner = require("lib.plan").new(recipes, matches)
--   planner.plan(name, n, have)   -> steps, missing    crafts only; smelted
--                                                      items count as missing
--   planner.tree(name, n, have)   -> tree              crafts and smelts down
--                                                      to raw materials
--   plan.time(tree, setup)        -> seconds           smelting and crafting
--   plan.eta(tree, rates)         -> rows              minutes to gather each raw
--   planner.rank(orders, have, rates) -> rows          raw demand of many orders,
--                                                      biggest first
--
-- `have` maps item -> count and is never changed. `matches(ing, key)` says
-- whether a stored item fits an ingredient (the factory knows item tags);
-- without it an item fits a tag only if the tag's make list names it.

local M = {}

local MAX_DEPTH = 8
-- Rough costs for the time estimate. Tune them from job logs.
M.SMELT_S = 10        -- a vanilla furnace: 200 ticks an item
M.CALL_S = 0.05       -- one peripheral call on the wired network: about a tick
M.ITEMS_PER_FUEL = 8  -- charcoal or coal
M.CRAFT_BATCH = 64    -- crafts per turtle.craft call at most

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function defaultMatches(ing, key)
  if type(ing) == "string" then return key == ing end
  for _, make in ipairs(ing.make or {}) do
    if make == key then return true end
  end
  return false
end

local function cells(recipe)
  local n = 0
  for _, row in ipairs(recipe.pattern) do
    for _ in row:gmatch("%S") do n = n + 1 end
  end
  return n
end

-- ctx: { smelt = true } also plans smelts (tree mode), { loose = true }
-- takes a tag's first make item even when its raw materials are missing.
function M.new(recipes, matches)
  matches = matches or defaultMatches
  local smeltFrom = {}
  for _, job in ipairs(recipes.smelting or {}) do
    smeltFrom[job.output] = smeltFrom[job.output] or job
  end

  local need

  local function produce(recipe, n, have, steps, missing, depth, ctx)
    local crafts = math.ceil(n / recipe.count)
    local uses = {}
    for _, row in ipairs(recipe.pattern) do
      for ch in row:gmatch("%S") do uses[ch] = (uses[ch] or 0) + 1 end
    end
    -- Same order every run, so plans read the same.
    local keys = {}
    for ch in pairs(uses) do keys[#keys + 1] = ch end
    table.sort(keys)
    for _, ch in ipairs(keys) do need(recipe.key[ch], uses[ch] * crafts, have, steps, missing, depth + 1, ctx) end
    steps[#steps + 1] = { recipe = recipe, crafts = crafts }
    local surplus = crafts * recipe.count - n
    if surplus > 0 and not recipe.direct then have[recipe.name] = (have[recipe.name] or 0) + surplus end
  end

  -- Takes n of ing from `have`, adding the crafts that make any shortfall to
  -- `steps` and anything that can't be made to `missing`.
  need = function(ing, n, have, steps, missing, depth, ctx)
    if type(ing) == "string" then
      local got = math.min(have[ing] or 0, n)
      have[ing], n = (have[ing] or 0) - got, n - got
      if n == 0 then return end
      local recipe = recipes.get(ing)
      if recipe and depth < MAX_DEPTH then
        produce(recipe, n, have, steps, missing, depth, ctx)
      elseif ctx.smelt and smeltFrom[ing] and depth < MAX_DEPTH then
        local job = smeltFrom[ing]
        steps[#steps + 1] = { smelt = job, n = n }
        need(job.input, n, have, steps, missing, depth + 1, ctx)
      else
        missing[ing] = (missing[ing] or 0) + n
      end
      return
    end
    local keys = {}
    for key in pairs(have) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      if n == 0 then return end
      local c = have[key]
      if c > 0 and matches(ing, key) then
        local got = math.min(c, n)
        have[key], n = c - got, n - got
      end
    end
    if n == 0 then return end
    -- Planks from logs we actually have come first, then the usual list.
    local candidates = {}
    if ing.fromLogs and recipes.planksFor then
      for _, key in ipairs(keys) do
        local planks = have[key] > 0 and recipes.planksFor(key)
        if planks then candidates[#candidates + 1] = planks end
      end
    end
    for _, make in ipairs(ing.make or {}) do candidates[#candidates + 1] = make end
    for _, make in ipairs(candidates) do
      local h2, s2, m2 = copy(have), {}, {}
      need(make, n, h2, s2, m2, depth, ctx)
      if next(m2) == nil then
        for k in pairs(have) do have[k] = nil end
        for k, v in pairs(h2) do have[k] = v end
        for _, s in ipairs(s2) do steps[#steps + 1] = s end
        return
      end
    end
    if ctx.loose and candidates[1] then
      need(candidates[1], n, have, steps, missing, depth, ctx)
      return
    end
    local name = "#" .. (ing.tag or "?")
    missing[name] = (missing[name] or 0) + n
  end

  local function run(name, n, have, ctx)
    local steps, missing = {}, {}
    local recipe = recipes.get(name)
    have = copy(have or {})
    if recipe and recipe.direct then
      produce(recipe, n, have, steps, missing, 0, ctx)
    else
      need(recipes.resolve(name), n, have, steps, missing, 0, ctx)
    end
    return steps, missing, have
  end

  local planner = {}

  function planner.plan(name, n, have)
    local steps, missing = run(name, n, have, {})
    return steps, missing
  end

  -- The whole tree: crafts and smelts merged by item (deepest first, the
  -- order they run in), raw materials, and the fuel the smelts burn.
  function planner.tree(name, n, have)
    local steps, missing = run(name, n, have, { smelt = true, loose = true })
    local t = { item = recipes.resolve(name), n = n, steps = steps, raws = missing,
                crafts = {}, smelts = {}, smeltCount = 0 }
    local craftAt, smeltAt = {}, {}
    for _, s in ipairs(steps) do
      if s.recipe then
        local c = craftAt[s.recipe.name]
        if not c then
          c = { name = s.recipe.name, crafts = 0, makes = 0, cells = cells(s.recipe), calls = 0 }
          craftAt[s.recipe.name] = c
          t.crafts[#t.crafts + 1] = c
        end
        c.crafts = c.crafts + s.crafts
        c.makes = c.makes + s.crafts * s.recipe.count
        c.calls = c.calls + math.ceil(s.crafts / M.CRAFT_BATCH)
      else
        local out = s.smelt.output
        local m = smeltAt[out]
        if not m then
          m = { input = s.smelt.input, output = out, n = 0 }
          smeltAt[out] = m
          t.smelts[#t.smelts + 1] = m
        end
        m.n = m.n + s.n
        t.smeltCount = t.smeltCount + s.n
      end
    end
    -- Charcoal comes from logs and burns too: c = S/8 + c/8, so c = S/7.
    t.fuel = math.ceil(t.smeltCount / M.ITEMS_PER_FUEL)
    t.fuelLogs = math.ceil(t.smeltCount / (M.ITEMS_PER_FUEL - 1))
    return t
  end

  -- Raw demand of a list of orders ({ item, n } each), met from one shared
  -- `have`, biggest shortfall first. Fuel for the smelts counts as logs.
  -- With rates (items/min per raw), each row also says how long gathering
  -- it takes at that rate.
  function planner.rank(orders, have, rates, opts)
    opts = opts or {}
    local left = copy(have or {})
    local total, smelts = {}, 0
    for _, o in ipairs(orders) do
      local steps, missing, after = run(o[1], o[2], left, { smelt = true, loose = true })
      left = after
      for _, s in ipairs(steps) do
        if s.smelt then smelts = smelts + s.n end
      end
      for k, v in pairs(missing) do total[k] = (total[k] or 0) + v end
    end
    if opts.fuel ~= false and smelts > 0 then
      local logs = opts.fuelItem or "#minecraft:logs"
      total[logs] = (total[logs] or 0) + math.ceil(smelts / (M.ITEMS_PER_FUEL - 1))
    end
    local rows = {}
    for item, n in pairs(total) do
      local rate = rates and rates[item]
      rows[#rows + 1] = { item = item, n = n, rate = rate,
                          minutes = rate and rate > 0 and n / rate or math.huge }
    end
    table.sort(rows, function(a, b)
      if a.n ~= b.n then return a.n > b.n end
      return a.item < b.item
    end)
    return rows, smelts
  end

  return planner
end

-- Seconds a tree takes with everything gathered: the smelts run spread over
-- the furnaces, then the crafts run one batch at a time. Each batch scans
-- storage (a call per chest), fetches each cell and stores the results.
-- setup: { furnaces = 4, chests = 20, smeltS = 10 }
function M.time(tree, setup)
  setup = setup or {}
  local furnaces = math.max(1, setup.furnaces or 4)
  local chests = setup.chests or 20
  local smelt = math.ceil(tree.smeltCount / furnaces) * (setup.smeltS or M.SMELT_S)
  local craft = 0
  for _, c in ipairs(tree.crafts) do
    craft = craft + c.calls * (chests + c.cells + 8) * M.CALL_S
  end
  return { smelt = smelt, craft = craft, total = smelt + craft }
end

-- Minutes to gather each raw material at the given rates (items/min);
-- math.huge where nothing brings it in. Slowest first.
function M.eta(tree, rates)
  local rows = {}
  for item, n in pairs(tree.raws) do
    local rate = rates and rates[item]
    rows[#rows + 1] = { item = item, n = n, rate = rate,
                        minutes = rate and rate > 0 and n / rate or math.huge }
  end
  table.sort(rows, function(a, b)
    if a.minutes ~= b.minutes then return a.minutes > b.minutes end
    if a.n ~= b.n then return a.n > b.n end
    return a.item < b.item
  end)
  return rows
end

-- "1h05m", "4m10s", "30s"
function M.duration(s)
  if s == math.huge then return "never" end
  s = math.floor(s + 0.5)
  if s >= 3600 then return ("%dh%02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  if s >= 60 then return ("%dm%02ds"):format(math.floor(s / 60), s % 60) end
  return s .. "s"
end

-- Without the mod: "#minecraft:logs" -> "#logs".
local function short(name) return (name:gsub("^(#?)[^:]*:", "%1")) end

-- A tree as lines short enough for a pocket computer.
function M.lines(tree, setup, rates)
  local out = { ("%d %s"):format(tree.n, short(tree.item)) }
  local raws = M.eta(tree, rates)
  if #raws > 0 then
    out[#out + 1] = "Raw materials:"
    for _, r in ipairs(raws) do
      local when = rates and ("  " .. M.duration(r.minutes * 60)) or ""
      out[#out + 1] = ("  %d %s%s"):format(r.n, short(r.item), when)
    end
  end
  if #tree.smelts > 0 then
    out[#out + 1] = "Smelt:"
    for _, s in ipairs(tree.smelts) do
      local input = short(type(s.input) == "string" and s.input or ("#" .. s.input.tag))
      out[#out + 1] = ("  %d %s"):format(s.n, input)
    end
    out[#out + 1] = ("  fuel: %d charcoal"):format(tree.fuel)
  end
  if #tree.crafts > 0 then
    out[#out + 1] = "Craft:"
    for _, c in ipairs(tree.crafts) do out[#out + 1] = ("  %s x%d"):format(short(c.name), c.crafts) end
  end
  local t = M.time(tree, setup)
  setup = setup or {}
  out[#out + 1] = ("Time: %s (%d furnaces)"):format(M.duration(t.total), setup.furnaces or 4)
  return out
end

return M
