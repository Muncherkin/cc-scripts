-- Walking a planned route. A route is steps in world directions, like
-- "n1u20w22d18" (n e s w u d and how many). Routes are planned off the
-- turtle (bridge/crew.mjs) through cells known to be air, so the walker
-- never digs: a turtle in the way is waited for, anything else is an error.
--
--   local route = require("lib.route")
--   route.cells(text, from, north) -> the cells it passes, in nav coordinates
--   route.finish(text, from, north) -> where it ends
--   route.follow(nav, text, opts)   walks it; opts:
--     north  the nav direction that is world north (default 0: the turtle's
--            frame started facing north)
--     from   the nav position the route starts at (default: where it is now).
--            Given, the walk resumes after a reboot: how far it has come is
--            read off its position (a planned route never crosses itself)
--     say    function(text) for a line a minute while it waits (default print)
--
-- lib/nav's frame: dir 0 is +z, 1 is +x, 2 is -z, 3 is -x; turning right adds 1.

local route = {}

local WORLD = { n = 0, e = 1, s = 2, w = 3 }
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

-- The single steps of a route: { op = "n", ... } once per block.
function route.ops(text)
  local ops = {}
  for op, n in tostring(text):gmatch("([nsewud])(%d+)") do
    for _ = 1, tonumber(n) do ops[#ops + 1] = op end
  end
  return ops
end

local function delta(op, north)
  if op == "u" then return 0, 1, 0 end
  if op == "d" then return 0, -1, 0 end
  local dir = (north + WORLD[op]) % 4
  return DX[dir], 0, DZ[dir]
end

-- The nav direction to face for a world direction.
function route.dir(op, north) return ((north or 0) + WORLD[op]) % 4 end

function route.cells(text, from, north)
  north = north or 0
  local p = { x = from.x, y = from.y, z = from.z }
  local cells = {}
  for i, op in ipairs(route.ops(text)) do
    local dx, dy, dz = delta(op, north)
    p = { x = p.x + dx, y = p.y + dy, z = p.z + dz }
    cells[i] = p
  end
  return cells
end

function route.finish(text, from, north)
  local cells = route.cells(text, from, north)
  return cells[#cells] or { x = from.x, y = from.y, z = from.z }
end

-- The reverse walk: "n1u2" -> "d2s1".
local BACK = { n = "s", s = "n", e = "w", w = "e", u = "d", d = "u" }
function route.reverse(text)
  local parts = {}
  for op, n in tostring(text):gmatch("([nsewud])(%d+)") do table.insert(parts, 1, BACK[op] .. n) end
  return table.concat(parts)
end

local INSPECT = { forward = turtle and turtle.inspect, up = turtle and turtle.inspectUp, down = turtle and turtle.inspectDown }
local NO_DIG = { canDig = function() return false end, tries = 2 }

function route.follow(nav, text, opts)
  opts = opts or {}
  local north = opts.north or 0
  local say = opts.say or print
  local ops = route.ops(text)
  local here = nav.pos()
  local from = opts.from or { x = here.x, y = here.y, z = here.z }
  local cells = route.cells(text, from, north)
  -- How far along: at the start, or on one of its cells.
  local done
  if here.x == from.x and here.y == from.y and here.z == from.z then done = 0 end
  for i, c in ipairs(cells) do
    if done then break end
    if c.x == here.x and c.y == here.y and c.z == here.z then done = i end
  end
  if not done then
    error(("Off my route at %d,%d,%d"):format(here.x, here.y, here.z), 0)
  end
  for i = done + 1, #ops do
    local op = ops[i]
    local kind = (op == "u" and "up") or (op == "d" and "down") or "forward"
    if kind == "forward" then nav.face(route.dir(op, north)) end
    local waited = 0
    while true do
      if nav.move(kind, NO_DIG) then break end
      if turtle.getFuelLevel() == 0 then error("Out of fuel on my route", 0) end
      local there, b = INSPECT[kind]()
      if there and not b.name:find("^computercraft:turtle") then
        error(("Blocked on my route at step %d of %d (%s): %s"):format(i, #ops, op, b.name), 0)
      end
      waited = waited + 1
      if waited % 30 == 0 then say(("Waiting at step %d of %d for %s"):format(i, #ops, there and "a turtle" or "the way")) end
      sleep(2)
    end
  end
  return true
end

return route
