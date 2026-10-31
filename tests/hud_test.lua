-- Offline tests for programs/hud.lua with a fake glasses overlay that keeps
-- what each object shows. Run with: npm test

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function newObject(props)
  local o = { props = props, enabled = true, content = props.text, color = props.color }
  local api = {}
  api.setGui = function(v) o.gui = v end
  api.setEnabled = function(v) o.enabled = v end
  api.setContent = function(v) o.content = v end
  api.setColor = function(v) o.color = v end
  api.setSizeX = function(v) o.sizeX = v end
  api.setSizeY = function(v) o.sizeY = v end
  o.api = api
  return o
end

-- Runs the HUD through these events; returns the visible lines and what it sent.
local function run(events)
  local texts, rects, sent = {}, {}, {}
  local overlay = {
    clear = function() end,
    createRectangle = function(p) local o = newObject(p) rects[#rects + 1] = o return o.api end,
    createText = function(p) local o = newObject(p) texts[#texts + 1] = o return o.api end,
    isAutoUpdating = function() return false end,
    update = function() end,
  }
  local glasses = { getModule = function(m) return m == "advancedperipherals:overlay" and overlay or nil end }
  local queue = {}
  for i, e in ipairs(events) do queue[i] = e end
  local env = setmetatable({
    peripheral = { find = function(t) return t == "smart_glasses" and glasses or nil end },
    bridge = { send = function(d) sent[#sent + 1] = d end },
    os = setmetatable({
      getComputerID = function() return 6 end,
      clock = function() return 0 end,
      startTimer = function() return 1 end,
      pullEvent = function()
        local e = table.remove(queue, 1)
        if not e then error("END_OF_EVENTS", 0) end
        return table.unpack(e)
      end,
    }, { __index = os }),
  }, { __index = _G })
  local f = assert(loadfile("programs/hud.lua", "t", env))
  local ok, err = pcall(f)
  local visible = {}
  for _, t in ipairs(texts) do
    if t.enabled and t.gui then visible[#visible + 1] = t.content end
  end
  return { ok = ok, err = err, lines = visible, sent = sent, bg = rects[1] }
end

local snapshot = {
  time = "16:20",
  computers = {
    { id = 1, label = "turtle-1", kind = "turtle", online = false, fuel = 198, jobs = {} },
    { id = 4, label = "turtle-4", kind = "turtle", online = true, fuel = 78,
      jobs = { { program = "factory", tail = { "Factory running: 4 chests, 4 furnaces",
        "Stock: 308 cobble, 259 stone, 31 charcoal, 13 logs, 55 glass" } } } },
    { id = 6, label = "computer-6", kind = "computer", online = true, jobs = { { program = "hud", tail = {} } } },
    { id = 7, label = "turtle-7", kind = "turtle", online = true, fuel = 133, jobs = { { program = "cobble", tail = {} } } },
  },
  events = { { time = "16:19", text = "computer-5: Vault door opened" } },
  messages = { { time = "16:00", text = "Cobble machine is live!" } },
}

print("Waiting for the bridge")
local r = run({})
check(r.err == "END_OF_EVENTS", "runs (" .. tostring(r.err) .. ")")
check(r.sent[1] and r.sent[1].action == "subscribe", "subscribes to the dashboard feed")
check(r.lines[1] and r.lines[1]:find("waiting", 1, true), "says it is waiting")

print("Full panel")
r = run({ { "bridge_push", "status", snapshot } })
local all = table.concat(r.lines, "\n")
check(all:find("308 cobble", 1, true) and all:find("55 glass", 1, true), "factory stock, all of it")
check(all:find("turtle-7", 1, true) and all:find("cobble", 1, true), "turtle-7 and its job")
check(all:find("computer-6", 1, true) == nil, "leaves itself out")
check(all:find("+1 offline", 1, true) ~= nil, "counts offline computers")
check(all:find("Vault door opened", 1, true) ~= nil, "latest event")
check(all:find("Cobble machine is live", 1, true) ~= nil, "latest message")
local long = 0
for _, l in ipairs(r.lines) do long = math.max(long, #l) end
check(long <= 40, "lines fit the panel (" .. long .. ")")
check(r.bg.sizeY and r.bg.sizeY >= #r.lines * 10, "background grows with the lines")

print("Hotkey cycles compact, hidden, full")
r = run({ { "bridge_push", "status", snapshot }, { "hotkey", "g", 0 } })
all = table.concat(r.lines, "\n")
check(#r.lines == 4 and all:find("308 cobble", 1, true) and all:find("Vault", 1, true), "compact: title, factory, event")
r = run({ { "bridge_push", "status", snapshot }, { "hotkey" }, { "hotkey" } })
check(#r.lines == 0 and r.bg.enabled == false, "hidden")
r = run({ { "bridge_push", "status", snapshot }, { "hotkey" }, { "hotkey" }, { "hotkey" } })
check(#r.lines > 4, "full again")

print("Factory offline")
local off = { time = "16:21", computers = { { id = 4, label = "turtle-4", online = false, jobs = {} } }, events = {}, messages = {} }
r = run({ { "bridge_push", "status", off } })
check(table.concat(r.lines, "\n"):find("Factory: offline", 1, true) ~= nil, "says so")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll hud tests passed")
