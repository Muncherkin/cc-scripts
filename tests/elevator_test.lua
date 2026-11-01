-- Offline tests for programs/elevator.lua: a 5-deep shaft with an alcove
-- beside the top, and a scripted player. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- Stone everywhere except the shaft (x=0,z=0, y=-5..0), the open air above
-- it and an alcove beside the top at (1,0,0).
local world = sim.newWorld(function(x, y, z)
  if y >= 1 then return nil end
  if x == 0 and z == 0 and y >= -5 then return nil end
  if x == 1 and z == 0 and y == 0 then return nil end
  return { name = "minecraft:stone" }
end)
local t = sim.newTurtle(world, { fuel = 500, left = "advancedperipherals:environment_detector",
  inventory = { { "minecraft:coal", 16 } } })
local computer = sim.newComputer()

local now = 0
local player -- absolute feet position, or nil
local seen = {}
local function script()
  -- What the player does over time.
  if now < 10 then
    player = nil                                    -- waits at the top
  elseif now < 25 then
    player = { x = t.x, y = t.y + 1, z = t.z, riding = true } -- rides down
  elseif now < 30 then
    player = nil                                    -- stepped off at the bottom
  elseif now < 45 then
    player = { x = t.x, y = t.y + 1, z = t.z, riding = true } -- rides back up
  elseif now < 48 then
    player = nil                                    -- stepped off at the top
  elseif now < 56 then
    player = { x = 0, y = -2, z = 0 }               -- climbing up the shaft from below
  elseif now < 70 then
    player = nil                                    -- (meanwhile the floor is raised)
  elseif now < 85 then
    player = { x = t.x, y = t.y + 1, z = t.z, riding = true } -- rides down again
  else
    player = nil
  end
end

computer.clock = function() return now end
local lastOk, refused = -math.huge, 0
computer.peripheral = {
  hasType = function(side, ty) return side == "left" and ty == "environment_detector" end,
  call = function(side, method)
    assert(side == "left" and method == "scanEntities")
    -- Like the real detector: one scan every 2 seconds.
    if now - lastOk < 2 then
      refused = refused + 1
      return nil, "scanEntities is on cooldown"
    end
    lastOk = now
    script()
    if not player then return {} end
    -- A rider being pushed along reads level with the turtle at times.
    local dy = player.y - t.y
    if player.riding and math.floor(now) % 3 == 0 then dy = 0.05 end
    return { { name = "minecraft:player", x = player.x - t.x, y = dy, z = player.z - t.z } }
  end,
}
computer.sleep = function(s)
  now = now + (s or 0)
  if now >= 60 and not world.get(0, -4, 0) then
    world.set(0, -5, 0, { name = "minecraft:stone" })
    world.set(0, -4, 0, { name = "minecraft:stone" })
  end
  for _, mark in ipairs({ 10, 25, 29, 45, 52, 66, 85 }) do
    if not seen[mark] and now >= mark then seen[mark] = { x = t.x, y = t.y, z = t.z } end
  end
  if now >= 90 then error("STOP_TEST", 0) end
end

local log = {}
local ok, res = sim.run("programs/elevator.lua", t, computer, log)
local out = table.concat(log, "\n")
check(res == "STOP_TEST", "runs (" .. tostring(res) .. ")\n" .. out)
check(out:find("Down to the floor and back", 1, true) ~= nil, "went straight down on its first start")
check(seen[10] and seen[10].y == 0, "and back up to where it started")
check(seen[25] and seen[25].y == -5, "rode the player to the bottom")
check(seen[29] and seen[29].y == -5, "stays at the bottom after they step off")
check(seen[45] and seen[45].y == 0, "rode the player back up")
check(seen[52] and seen[52].x == 1 and seen[52].y == 0, "stepped into the alcove for the climber")
check(seen[66] and seen[66].x == 0 and seen[66].y == 0 and seen[66].z == 0, "back in the shaft afterwards")
check(seen[85] and seen[85].y == -3, "the floor raised: stops on it (" .. tostring(seen[85] and seen[85].y) .. ")")
check(world.get(1, 0, 0) == nil and world.get(0, -6, 0) ~= nil and world.get(0, -4, 0) ~= nil, "dug nothing")
check(refused == 0, "never scans during the cooldown (" .. refused .. " refused)")

print("Placed somewhere new: forgets the old shaft, starts as the top")
do
  -- Its old state says it was 5 down on its way up; now it stands on a
  -- block (the shaft blocked below it).
  local w2 = sim.newWorld(function(x, y, z)
    if x == 0 and z == 0 and y >= 0 then return nil end
    return { name = "minecraft:stone" }
  end)
  local t2 = sim.newTurtle(w2, { fuel = 500, left = "advancedperipherals:environment_detector" })
  local c2 = sim.newComputer()
  local clock2 = 0
  c2.clock = function() return clock2 end
  c2.peripheral = {
    hasType = function(side, ty) return side == "left" and ty == "environment_detector" end,
    call = function() return {} end,
  }
  c2.files["/.elevator"] = '{ mode = "up", bottom = -60, pos = { x = 0, y = -5, z = 0 }, dir = 0 }'
  c2.sleep = function(s) clock2 = clock2 + (s or 0) if clock2 > 30 then error("STOP_TEST", 0) end end
  local log2 = {}
  sim.run("programs/elevator.lua", t2, c2, log2)
  local out2 = table.concat(log2, "\n")
  check(t2.y == 0, "stayed where it was placed (" .. t2.y .. ")")
  check(out2:find("Waiting at the top", 1, true) ~= nil, "waits there as the top")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll elevator tests passed")
