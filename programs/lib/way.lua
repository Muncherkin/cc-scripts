-- The way between the surface and the factory in the Engine Hall (see
-- lib/home.lua), for turtles that live on the surface or ferry things down.
--
-- The program hands over how it moves, as `go`:
--   go.step(op)  op n e s w u d (world directions): one step; returns true,
--                or false and "turtle" when a turtle stays in the way (the
--                program waits a little first), or false and what else
--   go.pos()     its world position { x, y, z }
--   go.face(op)  turn to face n e s w
--
-- Down the service shaft and in at y 6; out at y 7 and up the shaft. The
-- shaft is one wide and coming down has right of way: a turtle going up that
-- meets one drops back out of the shaft, waits and tries again. Flying in
-- goes along z first, flying out along x first, so they never meet head on.

local home = require("lib.home")

local way = {}

local function fail(msg) error(msg, 0) end
local function key(p) return ("%d %d %d"):format(p.x, p.y, p.z) end

-- Waits out turtles in the way, up to `patience` seconds (default half an hour).
local function stepWaiting(go, op, patience)
  local waited = 0
  while true do
    local ok, why = go.step(op)
    if ok then return true end
    if why ~= "turtle" then return false, why end
    if waited >= (patience or 1800) then return false, why end
    sleep(5)
    waited = waited + 5
  end
end

-- Straight up or down to height y.
function way.vertical(go, y, patience)
  while go.pos().y ~= y do
    local op = go.pos().y < y and "u" or "d"
    local ok, why = stepWaiting(go, op, patience)
    if not ok then return false, why end
  end
  return true
end

-- Across at its height to column (x, z), along `order` ("xz" or "zx"). On
-- the surface, over anything in the way.
function way.across(go, x, z, order)
  for i = 1, 2 do
    local axis = (order or "xz"):sub(i, i)
    while go.pos()[axis] ~= (axis == "x" and x or z) do
      local p = go.pos()
      local op = axis == "x" and (p.x < x and "e" or "w") or (p.z < z and "s" or "n")
      local ok, why = stepWaiting(go, op)
      if not ok then
        if why == "turtle" then fail("A turtle has been in my way for half an hour at " .. key(p)) end
        if not go.step("u") then fail(("Boxed in at %s (%s)"):format(key(p), tostring(why))) end
      end
    end
  end
end

-- From the surface into the hall: over to the shaft at height cruise, down
-- it, and out at the flying-in height.
function way.toHall(go, cruise)
  local S = home.shaft
  local p = go.pos()
  if p.x ~= S.x or p.z ~= S.z then
    local ok, why = way.vertical(go, math.max(p.y, cruise))
    if not ok then fail(("Can't rise to %d at %s: %s"):format(cruise, key(p), tostring(why))) end
    way.across(go, S.x, S.z, "xz")
  end
  local ok, why = way.vertical(go, home.hallIn)
  if not ok then fail(("Can't get down the shaft at %s: %s"):format(key(go.pos()), tostring(why))) end
end

-- From the hall up to height cruise over the shaft.
function way.toSurface(go, cruise)
  local S = home.shaft
  local ok, why = way.vertical(go, home.hallOut)
  if not ok then fail(("Can't rise to %d at %s: %s"):format(home.hallOut, key(go.pos()), tostring(why))) end
  local p = go.pos()
  if p.x ~= S.x or p.z ~= S.z then
    way.across(go, S.x + 1, S.z, "xz")
    if not stepWaiting(go, "w") then fail("Can't get into the shaft at " .. key(go.pos())) end
  end
  while true do
    ok, why = way.vertical(go, cruise, 10)
    if ok then return end
    if why ~= "turtle" then fail(("Can't get up the shaft at %s: %s"):format(key(go.pos()), tostring(why))) end
    -- One coming down: back down out of its way, wait, try again.
    print("Giving way in the shaft")
    ok, why = way.vertical(go, home.hallOut)
    if not ok then fail(("Can't get back down the shaft at %s: %s"):format(key(go.pos()), tostring(why))) end
    stepWaiting(go, "e")
    sleep(15 + math.random(15))
    stepWaiting(go, "w")
  end
end

-- In the hall: onto the factory's birth spot (the fuel station), down the
-- column above it. A turtle on it leaves the other way, so this one waits.
function way.toStation(go, F)
  local P = home.places(F)
  way.vertical(go, home.hallIn)
  way.across(go, P.station.x, P.station.z, "zx")
  local ok, why = way.vertical(go, P.station.y)
  if not ok then fail(("Can't get down to the fuel station from %s: %s"):format(key(go.pos()), tostring(why))) end
end

-- Off the birth spot northwards, then up to the flying-out height.
function way.leaveStation(go, F)
  local P = home.places(F)
  if not stepWaiting(go, "n") then fail("Can't leave the fuel station at " .. key(go.pos())) end
  local ok, why = way.vertical(go, home.hallOut)
  if not ok then fail(("Can't rise from %s: %s"):format(key(go.pos()), tostring(why))) end
  return P
end

-- In the hall: to the cell west of the input chest, facing it.
function way.toDrop(go, F)
  local P = home.places(F)
  way.vertical(go, home.hallIn)
  way.across(go, P.dropIn.x, P.dropIn.z, "zx")
  local ok, why = way.vertical(go, P.dropIn.y)
  if ok then ok, why = stepWaiting(go, "n") end
  if not ok then fail(("Can't get to the input chest from %s: %s"):format(key(go.pos()), tostring(why))) end
  go.face("e")
end

-- Out from the input chest: west, then up.
function way.leaveDrop(go)
  if not stepWaiting(go, "w") then fail("Can't leave the input chest at " .. key(go.pos())) end
  local ok, why = way.vertical(go, home.hallOut)
  if not ok then fail(("Can't rise from %s: %s"):format(key(go.pos()), tostring(why))) end
end

return way
