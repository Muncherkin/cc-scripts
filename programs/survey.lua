-- Maps one layer of the world round a factory-born turtle, without digging:
-- it walks every open cell it can reach at its own height inside a box and
-- notes what fills each blocked cell and what lies under each open one.
-- Writes /survey.txt ("x z what-is-here what-is-below", "." for air) and
-- comes back to where it started.
--
-- It keeps the turtle's own program's saved position (nav state) right, so
-- that program can carry on afterwards.
--
-- Usage: survey <state file> <x0> <x1> <z0> <z1> [y]   e.g. survey /.doorman 3542 3552 4744 4758 73
--        (with y it first moves up or down to that height, and back after)

local nav = require("lib.nav")
local saved = require("lib.state")

local file, x0, x1, z0, z1, ty = ...
x0, x1, z0, z1, ty = tonumber(x0), tonumber(x1), tonumber(z0), tonumber(z1), tonumber(ty)
if not (file and x0 and x1 and z0 and z1) then error("Usage: survey <state file> <x0> <x1> <z0> <z1>", 0) end

local state = saved.load(file)
if not state then error("No saved state in " .. file, 0) end
local function save() saved.save(file, state) end
nav.init(state, save)
nav.recover()

-- Factory-born turtles start on the birth spot facing north, by the factory
-- where it stood when they were born (older ones: on the surface).
local F = state.origin or require("lib.home").surface
local function world()
  local p = nav.pos()
  return { x = F.x + p.x, y = F.y + p.y, z = F.z - 1 - p.z }
end
local DIRS = { { "n", 0, 0, -1 }, { "e", 1, 1, 0 }, { "s", 2, 0, 1 }, { "w", 3, -1, 0 } }
local BACK = { n = 2, e = 3, s = 0, w = 1 }

local map, below = {}, {}
local function key(x, z) return x .. "," .. z end
local function name(ok, b) return ok and b.name or "." end

local origin = world()
while ty and world().y > ty do if not nav.move("down") then break end end
while ty and world().y < ty do if not nav.move("up") then break end end
local start = world()
local function visit()
  local w = world()
  below[key(w.x, w.z)] = name(turtle.inspectDown())
  for _, d in ipairs(DIRS) do
    local nx, nz = w.x + d[3], w.z + d[4]
    if nx >= x0 and nx <= x1 and nz >= z0 and nz <= z1 and map[key(nx, nz)] == nil then
      nav.face(d[2])
      local ok, b = turtle.inspect()
      if ok then
        map[key(nx, nz)] = b.name
      elseif nav.move("forward") then
        map[key(nx, nz)] = "."
        visit()
        nav.face(BACK[d[1]])
        nav.move("forward")
      else
        map[key(nx, nz)] = "?" -- something not a block (a mob, a player)
      end
    end
  end
end
map[key(start.x, start.z)] = "."
visit()

local lines = {}
for z = z0, z1 do
  for x = x0, x1 do
    local k = key(x, z)
    if map[k] then lines[#lines + 1] = ("%d %d %s %s"):format(x, z, map[k], below[k] or "") end
  end
end
while world().y < origin.y do if not nav.move("up") then break end end
while world().y > origin.y do if not nav.move("down") then break end end
local h = fs.open("/survey.txt", "w")
h.write(("layer y %d\n"):format(start.y) .. table.concat(lines, "\n") .. "\n")
h.close()
print(("Surveyed %d cells at y %d"):format(#lines, start.y))
