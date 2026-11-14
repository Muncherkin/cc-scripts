-- Offline tests for programs/lib/orders.lua's balancer. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local Orders = require("lib.orders")
local Rates = require("lib.rates")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local IRON = "minecraft:raw_iron"
local function jobs(auto)
  return {
    geominer = { unit = "chunky_mining_turtle", gathers = { [IRON] = 1.4 }, auto = auto },
    cobble = { unit = "mining_turtle" },
  }
end
local function flows(inn, out) return function() return inn, out end end
local NOW = 1700000000000

print("Balancer: a shortfall with a gatherer the factory can birth")
do
  local rows = { { item = IRON, n = 600 } }
  local advice, births = Orders.balance(Rates, rows, {}, flows(1.4, 1.4), jobs(true), { list = {} }, NOW)
  -- 600 over an hour is 10 a minute on top of the 1.4 used: 10 short, 8 miners.
  check(advice[1].action == "add" and advice[1].count == 8 and advice[1].job == "geominer",
    "advises 8 more miners (" .. tostring(advice[1].action) .. " " .. tostring(advice[1].count) .. ")")
  check(#births == 1 and births[1] == "geominer", "and queues one birth at a time")

  local q = { list = { { id = 1, birth = "geominer", at = NOW - 60000 } } }
  advice, births = Orders.balance(Rates, rows, {}, flows(1.4, 1.4), jobs(true), q, NOW)
  check(#births == 0, "not while one is still queued")
  q.list[1].done = true
  advice, births = Orders.balance(Rates, rows, {}, flows(1.4, 1.4), jobs(true), q, NOW)
  check(#births == 0, "nor right after one was born")
  q.list[1].at = NOW - 2 * Orders.BIRTH_GAP * 1000
  advice, births = Orders.balance(Rates, rows, {}, flows(1.4, 1.4), jobs(true), q, NOW)
  check(#births == 1, "again once the gap has passed")
end

print("Balancer: gatherers it can't birth itself, and none at all")
do
  local rows = { { item = IRON, n = 600 }, { item = "minecraft:sand", n = 60 } }
  local advice, births = Orders.balance(Rates, rows, {}, flows(0, 0), jobs(false), { list = {} }, NOW)
  check(#births == 0, "nothing is queued")
  local by = {}
  for _, a in ipairs(advice) do by[a.item] = a end
  check(by[IRON].action == "add" and by[IRON].job == "geominer", "iron: add miners, as advice")
  check(by["minecraft:sand"].action == "slow" and by["minecraft:sand"].job == nil, "sand: nothing gathers it")
end

print("Balancer: enough coming in")
do
  local advice, births = Orders.balance(Rates, { { item = IRON, n = 30 } }, {}, flows(3, 2), jobs(true), { list = {} }, NOW)
  check(advice[1].action == "ok" and #births == 0, "30 short at 3 a minute in is fine")
end

print("Pending orders for the planner")
do
  local q = { list = {
    { id = 1, item = "minecraft:torch", n = 64, left = 10 },
    { id = 2, item = "minecraft:stone", n = 500, keep = true },
    { id = 3, birth = "geominer" },
    { id = 4, item = "minecraft:chest", n = 1, left = 1, done = true },
  } }
  local p = Orders.pending(q, jobs(true))
  check(#p == 3 and p[1][2] == 10 and p[2][2] == 500 and p[3][1] == "chunky_mining_turtle",
    "what's left of each, births as their unit, done ones dropped")
  check(Orders.head(q).id == 1 and Orders.label(q.list[2]) == "500 stone in stock" and Orders.label(q.list[3]) == "birth geominer",
    "head and labels")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll orders tests passed")
