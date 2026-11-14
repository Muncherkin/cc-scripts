-- A builder's way to work: born on the factory's birth spot carrying two
-- chests, its blocks and coal (factory birth builder <blueprint> <route>
-- <face> [builder args] [item=n ...]), it walks the route to its home cell,
-- sets the supply chest under it and the staging chest over it, puts its
-- load in the supply chest, turns to face in and runs the builder there.
-- bridge/build.js plans the route through cells the Mover's map knows to be
-- air, and brings later what didn't fit in its pockets.
--
-- Usage: buildsite <blueprint> <route> <face> [plain] [z=a-b] [home=x,y,z,f]
--   route: steps in world directions from the birth spot, like n1u19w22d18
--   face:  n, e, s or w: the way in at the end
--   the rest goes to the builder as it is
-- It doesn't dig on the way, but for rock on the last step (a home cell in
-- a wall) and for the two chests' cells; a turtle in its path is waited
-- for. Resumes after reboots: where it is on the route is worked out from
-- its position.

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.buildsite"
local args = { ... }
local state = saved.load(STATE)
if not state then
  if not (args[1] and args[2] and args[3]) then error("Usage: buildsite <blueprint> <route> <face> [builder args]", 0) end
  state = { blueprint = args[1], route = args[2], face = args[3], extra = { table.unpack(args, 4) } }
end
local function save() saved.save(STATE, state) end

local function build()
  local fn, err = loadfile("/builder.lua", "t", _ENV)
  if not fn then error(err, 0) end
  return fn(state.blueprint, table.unpack(state.extra or {}))
end

if state.arrived then return build() end

-- Born facing north: nav's +z is north, +x east. dir: 0 n, 1 e, 2 s, 3 w.
nav.init(state, save)
nav.recover()
save()

local STEP = { n = { 0, 0, 1 }, s = { 0, 0, -1 }, e = { 1, 0, 0 }, w = { -1, 0, 0 }, u = { 0, 1, 0 }, d = { 0, -1, 0 } }
local DIR = { n = 0, e = 1, s = 2, w = 3 }
local ops = {}
for op, n in state.route:gmatch("([nsewud])(%d+)") do
  for _ = 1, tonumber(n) do ops[#ops + 1] = op end
end

-- Where it is on the route: the cell after i steps is its own on a
-- shortest path, so the position says how far it has come.
local at = { 0, 0, 0 }
local done = 0
do
  local p = nav.pos()
  local found = p.x == 0 and p.y == 0 and p.z == 0
  for i, op in ipairs(ops) do
    if found then break end
    local s = STEP[op]
    at = { at[1] + s[1], at[2] + s[2], at[3] + s[3] }
    if at[1] == p.x and at[2] == p.y and at[3] == p.z then found, done = true, i end
  end
  if not found then error(("Off my route at %d,%d,%d"):format(p.x, p.y, p.z), 0) end
end

local ROCK = { "stone", "deepslate", "tuff", "granite", "diorite", "andesite", "calcite", "dirt", "gravel", "cobble", "_ore", "clay", "torch" }
local function isRock(b)
  if not b or not b.name or b.name:find("redstone_block", 1, true) then return false end
  for _, w in ipairs(ROCK) do if b.name:find(w, 1, true) then return true end end
  return false
end

local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local NO_DIG = { canDig = function() return false end }
local LAST = { canDig = isRock }
for i = done + 1, #ops do
  local op = ops[i]
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIR[op]) end
  local waited = 0
  while true do
    local moved, why = nav.move(kind, i == #ops and LAST or NO_DIG)
    if moved then break end
    local ok, b = INSPECT[kind]()
    if ok and not b.name:find("^computercraft:turtle") then
      error(("Blocked on my route at step %d (%s): %s"):format(i, op, b.name), 0)
    end
    if turtle.getFuelLevel() == 0 then error("Out of fuel on my route", 0) end
    waited = waited + 1
    if waited % 30 == 0 then print(("Waiting at step %d of %d: %s"):format(i, #ops, tostring(ok and b.name or why))) end
    sleep(2)
  end
end
nav.face(DIR[state.face])

-- The chests, unless they stand already, and the load into the lower one.
local CHEST = "minecraft:chest"
local FUEL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }
local function slotOf(name)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then return s end
  end
end
local function setChest(inspect, dig, place, where)
  local ok, b = inspect()
  if ok and b.name == CHEST then return end
  if ok then
    if not isRock(b) then error(("%s is where my chest goes (%s)"):format(b.name, where), 0) end
    dig()
  end
  local s = slotOf(CHEST)
  if not s then return end -- stocked for it by someone else
  turtle.select(s)
  if not place() then error("Can't set the chest " .. where, 0) end
  turtle.select(1)
end
setChest(turtle.inspectDown, turtle.digDown, turtle.placeDown, "below")
-- What it dug up is junk; coal it keeps a little of, the rest and all the
-- blocks go into the supply chest.
if turtle.getFuelLevel() < 2000 then
  local s = slotOf("minecraft:coal") or slotOf("minecraft:charcoal")
  if s then
    turtle.select(s)
    turtle.refuel(16)
  end
end
for s = 1, 16 do
  local d = turtle.getItemDetail(s)
  if d and d.name ~= CHEST then
    turtle.select(s)
    if isRock(d) and not FUEL[d.name] then turtle.drop() else turtle.dropDown() end
  end
end
turtle.select(1)
setChest(turtle.inspectUp, turtle.digUp, turtle.placeUp, "above")

print(("At the %s site, facing in"):format(state.blueprint))
state.arrived, state.pos, state.dir, state.pending = true, nil, nil, nil
save()
return build()
