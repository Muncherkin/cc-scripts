-- Offline tests for programs/lib/rates.lua. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local Rates = require("lib.rates")
local Plan = require("lib.plan")
local recipes = require("lib.recipes")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end
local function near(a, b, eps) return a ~= nil and math.abs(a - b) <= (eps or 0.01) end

local COBBLE, STONE, LOGS = "minecraft:cobblestone", "minecraft:stone", "minecraft:spruce_log"

print("Net rate from snapshots")
do
  local r = Rates.new()
  check(r.net(COBBLE) == nil, "no history: no rate")
  for m = 0, 10 do r.snapshot(m * 60, { [COBBLE] = 1000 + 60 * m, [STONE] = 500 - 6 * m }) end
  check(near(r.net(COBBLE), 60), "cobble +60/min (" .. tostring(r.net(COBBLE)) .. ")")
  check(near(r.net(STONE), -6), "stone -6/min")
  check(near(r.net("minecraft:dirt"), 0), "an item never seen: 0")
  check(r.snapshot(10 * 60 + 5, { [COBBLE] = 0 }) == false, "a snapshot too soon is skipped")
end

print("A one-off withdrawal barely moves the trend")
do
  local r = Rates.new()
  for m = 0, 20 do
    local c = 2000 + 50 * m
    if m >= 10 then c = c - 64 end -- a stack crafted away at minute 10
    r.snapshot(m * 60, { [COBBLE] = c })
  end
  local net = r.net(COBBLE)
  check(net > 40 and net < 50, "still about +45/min, not -14 (" .. ("%.1f"):format(net) .. ")")
end

print("Old snapshots drop out of the window")
do
  local r = Rates.new({ window = 600 })
  for m = 0, 30 do
    local c = m <= 15 and 100 * m or 1500 -- grows, then stops
    r.snapshot(m * 60, { [LOGS] = c })
  end
  check(#r.state().snaps <= 12, "about 10 minutes kept (" .. #r.state().snaps .. ")")
  check(near(r.net(LOGS), 0), "the last 10 minutes are flat")
end

print("Flows tell in from out")
do
  local r = Rates.new()
  for s = 0, 600, 10 do
    r.flow(s, COBBLE, 10)        -- 60/min in
    r.flow(s, COBBLE, -10)       -- 60/min out to the furnaces
    if s % 60 == 0 then r.flow(s, STONE, 6) end
    r.snapshot(s, { [COBBLE] = 500, [STONE] = s / 10 })
  end
  check(near(r.net(COBBLE), 0), "snapshots see no change")
  check(near(r.inflow(COBBLE), 61, 1) and near(r.outflow(COBBLE), 61, 1), "flows see 60 in and 60 out (" ..
    ("%.1f"):format(r.inflow(COBBLE)) .. ")")
  local rows = r.report()
  local by = {}
  for _, row in ipairs(rows) do by[row.item] = row end
  check(by[COBBLE].have == 500 and by[COBBLE].runway == math.huge, "report: cobble steady")
  check(by[STONE].inn > 5, "report: stone in")
end

print("Runway: minutes left at the current trend")
do
  local r = Rates.new()
  for m = 0, 5 do r.snapshot(m * 60, { [LOGS] = 100 - 10 * m, [COBBLE] = 10 * m }) end
  local rows = r.report()
  check(rows[1].item == LOGS and near(rows[1].runway, 5), "logs run out in 5 min, listed first")
end

print("State survives a save")
do
  local r = Rates.new()
  for m = 0, 4 do r.snapshot(m * 60, { [COBBLE] = m * 30 }) r.flow(m * 60, COBBLE, 30) end
  local saved = r.state()
  local r2 = Rates.new(nil, saved)
  check(near(r2.net(COBBLE), 30) and near(r2.inflow(COBBLE), 37.5, 0.1), "same rates after a reload")
end

print("Uses -> inputs")
do
  local planner = Plan.new(recipes)
  -- The porter takes Factory Blocks at 64 a minute.
  local need = Rates.need(planner, { ["factory_blocks:factory"] = 64 })
  check(near(need.raws["minecraft:raw_iron"], 8) and near(need.raws[COBBLE], 8), "8 iron and 8 cobble a minute")
  check(near(need.smelts, 16) and near(need.furnaces, 16 * 10 / 60), "16 smelts/min keep 2.7 furnaces busy")
  check(near(need.fuelLogs, 16 / 7), "and burn 2.3 logs/min as charcoal")
  local short, total = Rates.furnacesShort(need.smelts, 2)
  check(total == 3 and short == 1, "2 furnaces: 1 short")
end

print("Advice: add, slow, cut, ok")
do
  local rows = {
    { item = "minecraft:raw_iron", have = 20, demand = 8, supply = 3 },
    { item = "#minecraft:logs", have = 40, demand = 3, supply = 2.9 },
    { item = COBBLE, have = 27000, demand = 8, supply = 60 },
    { item = "minecraft:diamond", have = 0, demand = 0.5, supply = 0.1 },
    { item = "minecraft:sand", have = 0, demand = 0, supply = 0 },
  }
  local a = Rates.advise(rows, {
    per = { ["minecraft:raw_iron"] = 2, [COBBLE] = 60, ["#minecraft:logs"] = 3 },
    cap = { [COBBLE] = 5000 },
    keep = { ["minecraft:sand"] = 0 },
  })
  local by = {}
  for _, x in ipairs(a) do by[x.item] = x end
  check(by["minecraft:raw_iron"].action == "add" and by["minecraft:raw_iron"].count == 3, "iron: 3 more gatherers")
  check(by["#minecraft:logs"].action == "ok", "logs within a tenth: ok")
  check(by[COBBLE].action == "cut" and by[COBBLE].count == 0, "cobble over cap: cut (one generator is less than a whole)")
  check(by["minecraft:diamond"].action == "slow" and near(by["minecraft:diamond"].factor, 0.2), "diamonds: no gatherer, users at a fifth")
  check(by["minecraft:sand"].action == "ok", "nothing used: ok")
  check(a[1].item == "minecraft:raw_iron", "adds first")
  local keep = Rates.advise({ { item = STONE, have = 100, demand = 0, supply = 0 } },
    { keep = { [STONE] = 1300 }, per = { [STONE] = 6 } })
  check(keep[1].action == "add" and keep[1].count == 4, "below keep: 1200 over an hour is 20/min, 4 furnaces' worth")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll rates tests passed")
