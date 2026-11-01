-- Where the factory is. Turtles that bring things to its input chest or fuel
-- up on its birth spot read it here, so moving the factory is a change to
-- `at` below (and a sync to those turtles), not to every program. Each
-- turtle keeps the factory's position from when it was born (state.origin)
-- for its own coordinates: lib/nav counts from the birth spot.
--
-- The factory turtle faces north wherever it is: input chest above it,
-- output chest below, birth spot (also the fuel station) one north.
-- World coordinates throughout; site = world less the lift's bottom.
--
-- The hall layout (docs/factory-move.md), in the Engine Hall's east strip,
-- seen from above (x east, z south), F = the factory turtle:
--
--   site x: 20 21 22 23 24
--   z  6     .  .  .  M  E    M  full wired modem: the spine, at F's height
--   z  7     .  .  D  M  E    E  barrel east of the spine; more barrels on
--   z  8     .  .  o  M  E       top of the spine, and under it but at
--   z  9     .  .  B  M  E       z 9 (cable + modem for the drive) and
--   z 10     <  i  F  M  E       z 13 (the 4th furnace)
--   z 11     .  v  f  M  E    B  birth spot, the disk drive under it
--   z 12     .  .  f  M  E    o  out lane: north off B, then up
--   z 13     .  .  f  M  E    D  ender drawer   f  furnace
--   i: one up, west of the input chest (on F): deliveries go in from there,
--   down the column at v and out by <. B is reached down the column above.
local home = {}

home.lift = { x = 3547, y = 0, z = 4754 }            -- the lift's bottom: site (0, 0, 0)
home.surface = { x = 3559, y = 74, z = 4763 }        -- on the surface, until the move
home.hall = { x = 3569, y = -13, z = 4764 }          -- site (22, -13, 10)

home.at = "surface"                                  -- "surface" or "hall"
home.factory = home[home.at]
home.inHall = home.at == "hall"

-- The service shaft: one wide, from the top (world y 77, open above) to the
-- top of the hall (y 8). Coming down has right of way. In the hall turtles
-- fly in at y 6 and out at y 7, above everything the Clockworks will build.
home.shaft = { x = 3550, z = 4754, top = 77, foot = 8 }
home.hallIn, home.hallOut = 6, 7

local function at(F, dx, dy, dz) return { x = F.x + dx, y = F.y + dy, z = F.z + dz } end

-- The hall factory's ways in and out, from its position F.
function home.places(F)
  F = F or home.hall
  return {
    station = at(F, 0, 0, -1),   -- in: down the column above it
    stationOut = at(F, 0, 0, -2), -- out: north, then up the column above it
    drop = at(F, -1, 1, 0),      -- deliveries go east from here into the input chest
    dropIn = at(F, -1, 1, 1),    -- in: down the column above it, then north
    dropOut = at(F, -2, 1, 0),   -- out: west, then up
  }
end

-- Every block of the hall factory, { x, y, z, what }: what the player
-- builds, and what turtles finding their way through the hall keep out of.
function home.layout(F)
  F = F or home.hall
  local cells = {}
  local function add(dx, dy, dz, what) cells[#cells + 1] = { x = F.x + dx, y = F.y + dy, z = F.z + dz, what = what } end
  add(0, 0, 0, "factory turtle")
  add(0, 1, 0, "input chest")
  add(0, -1, 0, "output chest")
  add(0, -1, -1, "disk drive")
  add(0, 0, -3, "ender drawer")
  for dz = -4, 3 do
    add(1, 0, dz, "wired modem")
    add(2, 0, dz, "barrel")
    add(1, 1, dz, "barrel")
    if dz == -1 then
      add(1, -1, dz, "cable + modem")
    elseif dz == 3 then
      add(1, -1, dz, "furnace")
    else
      add(1, -1, dz, "barrel")
    end
  end
  for dz = 1, 3 do add(0, 0, dz, "furnace") end
  return cells
end

-- Where a carrier drops loads into the hall factory's barrels, in order:
-- the row east of the spine (from above), then the row on top of it.
function home.dropCells(F)
  F = F or home.hall
  local cells = {}
  for dz = -4, 3 do cells[#cells + 1] = at(F, 2, 1, dz) end
  for dz = 3, -4, -1 do cells[#cells + 1] = at(F, 1, 2, dz) end
  return cells
end

function home.toSite(w) return { x = w.x - home.lift.x, y = w.y - home.lift.y, z = w.z - home.lift.z } end
function home.copy(p) return { x = p.x, y = p.y, z = p.z } end

return home
