-- A builder's way to work: born on the factory's birth spot (factory birth
-- builder <blueprint> <route> <face> [plain]), it walks the route to the
-- blueprint's home cell, turns to face in and runs the builder there. The
-- supply chest below home and the staging chest above it are already
-- standing and stocked (bridge/build.js has the Mover do that first, and
-- plans the route through cells its map knows to be air).
--
-- Usage: buildsite <blueprint> <route> <face> [plain]
--   route: steps in world directions from the birth spot, like n1u19w22d18
--   face:  n, e, s or w: the way in at the end
-- It never digs on the way; a turtle in its path is waited for. Resumes
-- after reboots: where it is on the route is worked out from its position.

local nav = require("lib.nav")
local saved = require("lib.state")

local STATE = "/.buildsite"
local blueprint, route, face, mode = ...
local state = saved.load(STATE)
if not state then
  if not (blueprint and route and face) then error("Usage: buildsite <blueprint> <route> <face> [plain]", 0) end
  state = { blueprint = blueprint, route = route, face = face, mode = mode }
end
local function save() saved.save(STATE, state) end

local function build()
  local fn, err = loadfile("/builder.lua", "t", _ENV)
  if not fn then error(err, 0) end
  return fn(state.blueprint, state.mode)
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

local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local NO_DIG = { canDig = function() return false end }
for i = done + 1, #ops do
  local op = ops[i]
  local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
  if kind == "forward" then nav.face(DIR[op]) end
  local waited = 0
  while true do
    local moved, why = nav.move(kind, NO_DIG)
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
print(("At the %s site, facing in"):format(state.blueprint))
state.arrived, state.pos, state.dir, state.pending = true, nil, nil, nil
save()
return build()
