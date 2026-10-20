-- Renders programs/dashboard.lua on a fake 5x4 advanced monitor (100x52 at
-- text scale 0.5) and prints the screen, then checks touch handling.
-- Run with: npx fengari tests/dashboard_test.lua [--show]

local show = arg and arg[1] == "--show"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function newMonitor(w, h)
  local m = { lines = {}, fgs = {}, bgs = {}, x = 1, y = 1, scale = 1, w = w, h = h }
  for y = 1, h do m.lines[y] = (" "):rep(w) m.fgs[y] = ("0"):rep(w) m.bgs[y] = ("f"):rep(w) end
  local api = {}
  api.setTextScale = function(s) m.scale = s end
  api.getSize = function() return m.w, m.h end
  api.isColour = function() return true end
  api.setCursorPos = function(x, y) m.x, m.y = x, y end
  api.blit = function(text, fg, bg)
    assert(#text == #fg and #fg == #bg, "blit arguments differ in length")
    assert(#text == m.w, ("line %d is %d wide, monitor is %d"):format(m.y, #text, m.w))
    m.lines[m.y], m.fgs[m.y], m.bgs[m.y] = text, fg, bg
  end
  m.api = api
  return m
end

local timers = 0
local function run(events, sent)
  timers = 0
  local mon = newMonitor(100, 52)
  local queue = {}
  for i, e in ipairs(events) do queue[i] = e end
  local env = setmetatable({
    peripheral = {
      find = function(t) return t == "monitor" and mon.api or nil end,
      wrap = function() return mon.api end,
      getName = function() return "monitor_0" end,
    },
    bridge = { send = function(d) sent[#sent + 1] = d end, connected = function() return true end },
    os = {
      clock = function() return 100 end,
      startTimer = function() timers = timers + 1 return timers end,
      pullEvent = function()
        local e = table.remove(queue, 1)
        if not e then error("END_OF_EVENTS", 0) end
        return table.unpack(e)
      end,
    },
    print = function() end,
  }, { __index = _G })
  local f = assert(loadfile("programs/dashboard.lua", "t", env))
  local ok, err = pcall(f)
  return mon, ok or err == "END_OF_EVENTS", err
end

local snapshot = {
  time = "21:42",
  computers = {
    { id = 1, label = "turtle-1", kind = "turtle", online = true, fuel = 876, lastSeen = "21:41", dashboard = false,
      jobs = { { program = "miner", tail = { "Branch 4 | pos 0,0,12 | fuel 876 | ores 85 (deepslate_fluorite_ore 42, deepslate_zinc_ore 15, deepslate_gold_ore 7, xychorium 6) | lava 0 | chests 0 placed, 4 left" } } } },
    { id = 2, label = "turtle-2", kind = "turtle", online = true, fuel = 76, lastSeen = "21:41", dashboard = false,
      jobs = { { program = "farm", tail = { "Pass: growing=4, bread=0" } } } },
    { id = 3, label = "computer-3", kind = "computer", online = true, lastSeen = "21:42", dashboard = true, jobs = {} },
    { id = 4, label = "old-turtle", kind = "turtle", online = false, fuel = 20, lastSeen = "18:03", dashboard = false, jobs = {} },
  },
  messages = {
    { time = "21:40", text = "Miner is at branch 4 with 7 gold so far. Fuel is getting low, it will come home on its own before it runs out." },
    { time = "21:12", text = "Dashboard is live!" },
  },
  events = {
    { time = "21:41", text = "computer-3 connected" },
    { time = "21:30", text = "turtle-1: setupfarm error: Can't equip the digging tool" },
    { time = "21:02", text = "turtle-2 went offline" },
  },
}

print("Overview screen")
local sent = {}
local mon, ok, err = run({ { "bridge_push", "status", snapshot } }, sent)
check(ok, "renders without errors (" .. tostring(err) .. ")")
check(sent[1] and sent[1].action == "subscribe", "subscribes to the bridge on start")
local screen = table.concat(mon.lines, "\n")
check(screen:find("CLAUDE") ~= nil, "shows the header")
check(screen:find("turtle%-1") and screen:find("turtle%-2") and screen:find("old%-turtle"), "lists all computers")
check(screen:find("OFFLINE") ~= nil, "marks offline computers")
check(screen:find("Branch 4") ~= nil, "shows the miner's latest report")
check(screen:find("Dashboard is live") ~= nil, "shows messages from Claude")
check(screen:find("STOP ALL") ~= nil, "has a STOP ALL button")
if show then print(screen) end

print("Tunnel cam animation")
do
  -- timer ids: 1 = 5s refresh, 2 = first animation tick, then 3, 4, ...
  local evs = { { "bridge_push", "status", snapshot } }
  for i = 2, 41 do evs[#evs + 1] = { "timer", i } end
  local m = run(evs, {})
  local function camText(mm)
    local t = {}
    for y = 45, 50 do t[#t + 1] = mm.lines[y] end
    return table.concat(t, "\n")
  end
  local before = camText(run({ { "bridge_push", "status", snapshot } }, {}))
  local after = camText(m)
  check(after:find("%[o_o%]") ~= nil, "draws the turtle")
  check(before ~= after, "the turtle moves after a few frames")
  if show then print(after) end
end

print("Touch handling")
sent = {}
-- tap the first card (turtle-1 starts at row 6), then STOP ALL twice
mon, ok, err = run({
  { "bridge_push", "status", snapshot },
  { "monitor_touch", "monitor_0", 10, 7 },
}, sent)
check(ok and sent[2] and sent[2].action == "detail" and sent[2].computer == 1, "tapping a card requests its details")
local detailScreen = table.concat(mon.lines, "\n")
check(detailScreen:find("BACK") ~= nil, "detail view has a BACK button")

sent = {}
mon, ok = run({
  { "bridge_push", "status", snapshot },
  { "monitor_touch", "monitor_0", 3, 52 },
  { "monitor_touch", "monitor_0", 3, 52 },
}, sent)
local stops = 0
for _, s in ipairs(sent) do if s.action == "stop_all" then stops = stops + 1 end end
check(stops == 1, "STOP ALL needs two taps and sends one stop")
sent = {}
mon, ok = run({ { "bridge_push", "status", snapshot }, { "monitor_touch", "monitor_0", 3, 52 } }, sent)
stops = 0
for _, s in ipairs(sent) do if s.action == "stop_all" then stops = stops + 1 end end
check(stops == 0, "one tap on STOP ALL only asks for confirmation")

print(failures == 0 and "\nAll tests passed" or ("\n" .. failures .. " check(s) failed"))
if failures > 0 then os.exit(1) end
