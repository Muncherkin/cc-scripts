-- Offline tests for programs/birth/startup.lua, the newborns' boot disk.
-- Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- A computer with the boot disk in a drive at /disk. `own` are its own files.
local function boot(own)
  local world = sim.newWorld(function() return nil end)
  local t = sim.newTurtle(world, { fuel = 0, inventory = { { "minecraft:charcoal", 4 } } })
  local computer = sim.newComputer()
  for path, content in pairs(own) do computer.files[path] = content end
  computer.files["/disk/startup.lua"] = "-- this disk"
  computer.files["/disk/job"] = '{program="geominer",args={}}'
  computer.files["/disk/agent-config"] = '{gistUrl="g",token="t"}'
  computer.files["/disk/files/geominer.lua"] = "-- geominer"
  local f = { t = t, computer = computer, ran = {}, settings = {}, downloads = 0 }
  computer.globals = {
    shell = {
      getRunningProgram = function() return "disk/startup.lua" end,
      run = function(path) f.ran[#f.ran + 1] = path return true end,
    },
    settings = { set = function(k, v) f.settings[k] = v end, save = function() end },
    http = { get = function()
      f.downloads = f.downloads + 1
      return { readAll = function() return "-- installer" end, close = function() end }
    end },
  }
  local log = {}
  f.ok, f.res = sim.run("programs/birth/startup.lua", t, computer, log)
  f.log = table.concat(log, "\n")
  return f
end

print("A newborn takes the job and installs the agent")
local f = boot({})
check(f.ok, "boots (" .. tostring(f.res) .. ")")
check((f.computer.files["/.agent/autorun"] or ""):find("geominer", 1, true) ~= nil, "job set as autorun")
check(f.computer.files["/geominer.lua"] == "-- geominer", "programs copied")
check(f.downloads == 1 and f.ran[1] == "/install.lua", "installer run")
check(f.settings["shell.allow_disk_startup"] == false, "never boots from a disk again")

print("A fleet member beside the drive keeps its own job")
f = boot({
  ["/.agent/agent.lua"] = "-- agent",
  ["/.agent/autorun"] = '{program="factory",args={"run"}}',
  ["/startup/00_agent.lua"] = "-- start the agent",
})
check(f.ok, "boots (" .. tostring(f.res) .. ")")
check(f.computer.files["/.agent/autorun"] == '{program="factory",args={"run"}}', "autorun untouched")
check(f.computer.files["/geominer.lua"] == nil, "no programs copied")
check(f.downloads == 0, "no installer")
check(#f.ran == 1 and f.ran[1] == "/startup/00_agent.lua", "runs its own startup (" .. table.concat(f.ran, ", ") .. ")")
check(f.t.fuel == 0, "leaves its fuel alone")
check(f.settings["shell.allow_disk_startup"] == false, "never boots from a disk again")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll birth tests passed")
