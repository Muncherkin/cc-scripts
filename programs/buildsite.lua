-- A builder's first minutes. Born on the factory's birth spot, which is the
-- loading bay (lib/bay.lua): it stands there until the factory has loaded
-- it, burns some of its coal, walks its `out` route to the home cell of
-- what it's to build, turns to face in and runs the builder, which from
-- then on goes back to the bay by itself when it runs out. No chests.
--
-- Usage: buildsite <blueprint> <out> <back> <face> [plain] [z=a-b] [home=x,y,z,f]
--   out, back: routes in world directions (lib/route.lua) from the bay to
--              the home cell and from there to the bay, planned by
--              bridge/crew.mjs along the hall's one-way lanes
--   face:      n, e, s or w: the way in at home
--   the rest goes to the builder as it is
-- Resumes after reboots at whatever it was doing.

local nav = require("lib.nav")
local saved = require("lib.state")
local route = require("lib.route")

local STATE = "/.buildsite"
local args = { ... }
local state = saved.load(STATE)
if not state then
  if not (args[1] and args[2] and args[3] and args[4]) then
    error("Usage: buildsite <blueprint> <out> <back> <face> [builder args]", 0)
  end
  state = { blueprint = args[1], out = args[2], back = args[3], face = args[4],
            extra = { table.unpack(args, 5) }, phase = "load" }
end
local function save() saved.save(STATE, state) end

local function build()
  local fn, err = loadfile("/builder.lua", "t", _ENV)
  if not fn then error(err, 0) end
  local flags = { "out=" .. state.out, "back=" .. state.back }
  for _, a in ipairs(state.extra or {}) do flags[#flags + 1] = a end
  return fn(state.blueprint, table.unpack(flags))
end

if state.phase == "build" then return build() end

-- Born facing north: nav's +z is north, +x east.
nav.init(state, save)
nav.recover()
save()

local FUEL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }
local function held()
  local n = 0
  for s = 1, 16 do n = n + turtle.getItemCount(s) end
  return n
end
local function refuel(to)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and FUEL[d.name] then
      turtle.select(s)
      while turtle.getFuelLevel() < to and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

if state.phase == "load" then
  -- Until the bay has loaded it: something has come, nothing more does,
  -- and there's fuel for the walk.
  local need = #route.ops(state.out) + #route.ops(state.back) + 200
  local last, still, waited = held(), 0, 0
  while true do
    sleep(2)
    waited = waited + 2
    local now = held()
    if now ~= last then last, still = now, 0 else still = still + 2 end
    if now > 0 and still >= 12 then
      refuel(math.max(need, 4000))
      if turtle.getFuelLevel() >= need then break end
    end
    if waited % 60 == 0 then print(("In the bay, waiting to be loaded (holding %d, fuel %d)"):format(now, turtle.getFuelLevel())) end
  end
  state.phase = "walk"
  save()
end

route.follow(nav, state.out, { from = { x = 0, y = 0, z = 0 } })
nav.face(route.dir(state.face, 0))
print(("At the %s site, facing in"):format(state.blueprint))
state.phase, state.pos, state.dir, state.pending = "build", nil, nil, nil
save()
return build()
