-- Turtle elevator for a vertical shaft. Needs an Advanced Peripherals
-- Environment Detector upgrade (scanEntities shows where players are
-- relative to the turtle) and some coal in its inventory.
--
-- Where it starts is the top. On its first run it goes down until it hits
-- something to find the bottom, then comes back up and waits.
--
-- Each ride is a whole trip, decided at either end:
--   top     waiting; someone steps on   -> down   (rides all the way down)
--   down    carrying them down          -> unload
--   unload  at an end, rider still on   -> bottom/top once they step off
--   bottom  waiting; someone steps on   -> up     (rides all the way up)
--   up      carrying them up            -> unload
-- While waiting at the top it steps aside for a player climbing up the
-- shaft from below, and returns once they're past.
--
-- Usage: elevator          (what autorun runs)
--        elevator reset    forget the shaft and measure it again from here

local nav = require("lib.nav")

local STATE = "/.elevator"
local POLL = 0.1       -- seconds between steps
local SCAN_EVERY = 2.05 -- the detector allows one scan every 2 seconds
local RANGE = 4        -- scan radius (small radii cost no fuel)
local CENTER = 0.7     -- how far off the shaft's middle a player may stand
local REFUEL_AT = 200

local detector
for _, side in ipairs({ "left", "right" }) do
  if peripheral.hasType(side, "environment_detector") or peripheral.hasType(side, "environmentDetector") then
    detector = side
  end
end
if not detector then error("I need an Environment Detector upgrade", 0) end

if ... == "reset" then fs.delete(STATE) end

local state
do
  local h = fs.open(STATE, "r")
  if h then
    state = textutils.unserialise(h.readAll())
    h.close()
  end
end
state = state or {}

local function save()
  local h = fs.open(STATE, "w")
  h.write(textutils.serialise(state))
  h.close()
end

nav.init(state, save)
nav.recover()
save()

local function refuel()
  if turtle.getFuelLevel() >= REFUEL_AT then return end
  for slot = 1, 16 do
    turtle.select(slot)
    if turtle.refuel(8) and turtle.getFuelLevel() >= REFUEL_AT then break end
  end
  turtle.select(1)
end

-- The last real scan. who: "top" (someone on us), "below" (someone in the
-- shaft under us) or nil; near: any player close by.
local view = { who = nil, near = false }
local lastScan = -math.huge

-- Scans when the detector's cooldown allows and returns true. In between it
-- keeps the last real result: a refused scan must never read as "nobody".
local function look()
  if os.clock() - lastScan < SCAN_EVERY then return false end
  local ok, list = pcall(peripheral.call, detector, "scanEntities", RANGE)
  if not ok or type(list) ~= "table" then return false end
  lastScan = os.clock()
  local who, near = nil, false
  for _, e in ipairs(list) do
    if e.name == "minecraft:player" then
      if math.abs(e.x) < 2 and math.abs(e.z) < 2 and math.abs(e.y) < 3 then near = true end
      if math.abs(e.x) < CENTER and math.abs(e.z) < CENTER then
        -- Standing on us reads about +1, but while we move a rider can
        -- briefly read level with us; only clearly underneath is "below".
        if e.y > -0.6 and e.y < 2.5 then
          who = "top"
        elseif e.y < -1.0 and e.y > -3.5 and who == nil then
          who = "below"
        end
      end
    end
  end
  view = { who = who, near = near }
  return true
end

local function y() return nav.pos().y end

-- One block up or down; never digs, never forces past a player.
local function step(kind)
  refuel()
  return nav.move(kind)
end

-- First run: measure the shaft.
if not state.bottom then
  print("Finding the bottom of the shaft")
  -- Only a block counts as the bottom; a player in the way is waited out.
  while true do
    if not step("down") then
      if turtle.detectDown() then break end
      print("Someone is below me, waiting")
      sleep(2)
    end
  end
  state.bottom = y()
  save()
  print(("Shaft is %d blocks deep"):format(-state.bottom))
end

-- Back into the shaft after a dodge (or a reboot during one).
local function returnToShaft()
  local p = nav.pos()
  if p.x == 0 and p.z == 0 then return true end
  nav.stepTo("x", 0)
  nav.stepTo("z", 0)
  local q = nav.pos()
  return q.x == 0 and q.z == 0
end

-- Steps aside into the first free block beside the shaft. Returns true if
-- it got out of the way.
local function dodge()
  for _ = 1, 4 do
    if not turtle.detect() and nav.move("forward", { tries = 1 }) then return true end
    nav.turn(true)
  end
  -- No room beside us: up instead, if there's shaft above.
  if y() < 0 then return step("up") end
  return false
end

-- The trip it is on survives reboots: a ride carries on where it was.
if not state.mode then
  state.mode = "up" -- after measuring the shaft we're at the bottom
  save()
end

local function setMode(mode)
  state.mode = mode
  save()
end

print(("Elevator ready: top 0, bottom %d"):format(state.bottom))
local said
local function say(msg)
  if msg ~= said then print(msg) end
  said = msg
end

while true do
  local fresh = look()
  local p = nav.pos()
  local mode = state.mode
  if p.x ~= 0 or p.z ~= 0 then
    -- Stepped aside for a climber: back once a real scan shows nobody near.
    if fresh and not view.near and returnToShaft() then say("Back in the shaft") end
  elseif mode == "down" then
    say("Going down")
    if y() <= state.bottom then setMode("unload") elseif not step("down") then sleep(0.5) end
  elseif mode == "up" then
    say("Going up")
    if y() >= 0 then setMode("unload") elseif not step("up") then sleep(0.5) end
  elseif mode == "unload" then
    say(y() >= 0 and "At the top, step off" or "At the bottom, step off")
    if fresh and view.who ~= "top" then setMode(y() >= 0 and "top" or "bottom") end
  elseif mode == "bottom" then
    say("Waiting at the bottom")
    if fresh and view.who == "top" then setMode("up") end
  else -- "top"
    say("Waiting at the top")
    if fresh and view.who == "top" then
      setMode("down")
    elseif fresh and view.who == "below" then
      say("Making way")
      dodge()
      view = { who = nil, near = true } -- seen from the old spot: wait for a new scan
    end
  end
  sleep(POLL)
end
