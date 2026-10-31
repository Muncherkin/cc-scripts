-- Offline tests for programs/door.lua: a scripted keyboard, a fake screen
-- and a redstone recorder. Run with: npm test

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

-- Runs the door with these typed lines. Returns the redstone log, events
-- sent to the bridge, the files and the screen text.
local function run(lines, files)
  files = files or {}
  local typed, redstoneLog, sent, screen = 1, {}, {}, {}
  local now = 0
  local fsapi = {
    open = function(p, mode)
      if mode == "r" then
        if not files[p] then return nil end
        return { readAll = function() return files[p] end, close = function() end }
      end
      local buf = ""
      return { write = function(s) buf = buf .. s end, close = function() files[p] = buf end }
    end,
  }
  local function out(s) screen[#screen + 1] = tostring(s) end
  local fakeOs = setmetatable({
    queueEvent = function(name, data) if name == "bridge_send" then sent[#sent + 1] = data end end,
    pullEventRaw = function() return "dummy" end,
  }, { __index = os })
  fakeOs.pullEvent = function() return "dummy" end
  local env = setmetatable({
    fs = fsapi,
    os = fakeOs,
    term = {
      getSize = function() return 51, 19 end,
      clear = function() end,
      clearLine = function() end,
      setCursorPos = function() end,
      write = out,
    },
    write = out,
    print = function(s) out(s or "") end,
    read = function()
      local line = lines[typed]
      typed = typed + 1
      if line == nil then error("END_OF_INPUT", 0) end
      return line
    end,
    sleep = function(s) now = now + (s or 0) end,
    redstone = { setOutput = function(side, on) redstoneLog[#redstoneLog + 1] = { side = side, on = on, t = now } end },
    textutils = {
      serialise = function(t)
        local parts = {}
        for k, v in pairs(t) do parts[#parts + 1] = ("[%q]=%q"):format(k, tostring(v)) end
        return "{" .. table.concat(parts, ",") .. "}"
      end,
      unserialise = function(s)
        local t = load("return " .. s)()
        if t.hold then t.hold = tonumber(t.hold) end
        return t
      end,
    },
  }, { __index = _G })
  local f = assert(loadfile("programs/door.lua", "t", env))
  local ok, err = pcall(f)
  return { ok = ok, err = err, redstone = redstoneLog, sent = sent, files = files, screen = table.concat(screen, "\n") }
end

local function opened(r)
  for i, e in ipairs(r.redstone) do
    if e.on then
      local off = r.redstone[i + 1]
      return off and not off.on and off.t - e.t, e.side
    end
  end
end

print("First start: choose a passphrase, then it opens the door")
local r = run({ "letmein", "letmein", "letmein" })
check(r.err == "END_OF_INPUT", "keeps running (" .. tostring(r.err) .. ")")
check((r.files["/.door"] or ""):find("letmein", 1, true) ~= nil, "passphrase saved on the computer")
local held, side = opened(r)
check(held == 5 and side == "right", "door on the right held open 5 s (" .. tostring(held) .. ", " .. tostring(side) .. ")")
check(r.screen:find("ACCESS  GRANTED", 1, true) ~= nil, "shows ACCESS GRANTED")

local saved = { ["/.door"] = '{pass="letmein",side="right",hold=5}' }

print("Wrong passphrases lock it and raise the alarm")
r = run({ "nope", "guess", "hunter2" }, { ["/.door"] = saved["/.door"] })
check(opened(r) == nil, "door stays shut")
check(r.screen:find("INTRUSION", 1, true) ~= nil, "intrusion screen")
check(#r.sent == 1 and r.sent[1].action == "event", "one alarm sent to the bridge")

print("Commands never open the door")
r = run({ "help", "whoami", "matrix", "exit", "nope" }, { ["/.door"] = saved["/.door"] })
check(opened(r) == nil, "door stays shut")
check(r.screen:find("follow the white rabbit", 1, true) ~= nil, "help lists the commands")
check(r.err == "END_OF_INPUT", "a wrong passphrase on exit keeps it running")

print("exit with the passphrase leaves the terminal")
r = run({ "exit", "letmein" }, { ["/.door"] = saved["/.door"] })
check(r.ok, "exits cleanly (" .. tostring(r.err) .. ")")
check(r.redstone[#r.redstone] and r.redstone[#r.redstone].on == false, "door output left off")

print("hack is just a game")
r = run({ "hack", "AAAAAA", "BBBBBB", "CCCCCC", "DDDDDD" }, { ["/.door"] = saved["/.door"] })
check(opened(r) == nil, "door stays shut")
check(r.screen:find("likeness", 1, true) ~= nil, "gives likeness hints")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll door tests passed")
