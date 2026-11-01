-- Offline tests for programs/lib/state.lua. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

print("Saves and loads")
do
  local c = sim.newComputer()
  local env = { fs = c.fs, textutils = { serialise = function(v) return "{n=" .. v.n .. "}" end,
    unserialise = function(s) local f = load("return " .. s) return f and f() end } }
  local mod = assert(loadfile("programs/lib/state.lua", "t", setmetatable(env, { __index = _G })))()
  mod.save("/.x", { n = 1 })
  check(mod.load("/.x").n == 1, "round trip")
  check(c.files["/.x.new"] == nil, "no leftover")
  check(mod.load("/.missing") == nil, "nothing saved: nil")

  print("A save cut off while writing keeps the old state")
  c.files["/.x.new"] = ""         -- the new file was opened, never written
  check(mod.load("/.x").n == 1, "old state loads")

  print("A save cut off between delete and move loads the new one")
  c.files["/.x.new"] = "{n=2}"
  c.files["/.x"] = nil
  check(mod.load("/.x").n == 2, "new state loads")

  print("An empty state file isn't taken for no state")
  c.files["/.x"] = ""
  c.files["/.x.new"] = "{n=3}"
  check(mod.load("/.x").n == 3, "falls back on the new file")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll state tests passed")
