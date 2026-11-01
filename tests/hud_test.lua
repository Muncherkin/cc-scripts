-- Offline tests for programs/hud.lua with a fake glasses overlay that keeps
-- what each object shows. Run with: npm test
-- Preview: node tests/run.js tests/hud_test.lua svg > logs/hud.svg
-- draws the full panel and the attention banner as an SVG (text widths from
-- lib.mcfont, so it shows whether everything fits).

package.path = "programs/?.lua;" .. package.path
local mcfont = require("lib.mcfont")
local SVG = arg and arg[1] == "svg"

local failures = 0
local function check(cond, msg)
  if SVG then return end
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function newObject(kind, props)
  -- width/height props are ignored by the real overlay, so they are here too
  local o = { kind = kind, enabled = true, x = props.x, y = props.y, w = 0, h = 0,
    content = props.text, color = props.color, opacity = 1, size = 1 }
  local api = {}
  api.setGui = function(v) o.gui = v end
  api.setEnabled = function(v) o.enabled = v end
  api.setContent = function(v) o.content = v end
  api.setColor = function(v) assert(type(v) == "number", "The value null is not valid for color") o.color = v end
  api.setX = function(v) o.x = v end
  api.setY = function(v) o.y = v end
  api.setSizeX = function(v) o.w = v end
  api.setSizeY = function(v) o.h = v end
  api.setOpacity = function(v) o.opacity = v end
  api.setFontSize = function(v) o.size = v end
  api.setShadow = function(v) o.shadow = v end
  o.api = api
  return o
end

-- Runs the HUD through these events; returns what is on screen and what it sent.
local function run(events)
  local texts, rects, sent = {}, {}, {}
  local overlay = {
    clear = function() end,
    createRectangle = function(p) local o = newObject("rect", p) rects[#rects + 1] = o return o.api end,
    createText = function(p) local o = newObject("text", p) texts[#texts + 1] = o return o.api end,
    getGuiSize = function() return 1920, 1080, 2 end,
    getEyePosition = function() return 3548.4, 79.5, 4749.5 end,
    isAutoUpdating = function() return false end,
    update = function() end,
  }
  local glasses = { getModule = function(m) return m == "advancedperipherals:overlay" and overlay or nil end }
  local queue = {}
  for i, e in ipairs(events) do queue[i] = e end
  local env = setmetatable({
    require = require,
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
  local r = { ok = ok, err = err, lines = {}, texts = {}, rects = {}, sent = sent }
  for _, t in ipairs(texts) do
    if t.enabled and t.gui and t.content ~= "" then
      r.lines[#r.lines + 1] = t.content
      r.texts[#r.texts + 1] = t
    end
  end
  -- A rectangle's x, y is its centre, like on the real overlay.
  for _, o in ipairs(rects) do
    if o.enabled and o.gui and o.w > 0 and o.h > 0 then
      r.rects[#r.rects + 1] = { x = o.x - o.w / 2, y = o.y - o.h / 2, w = o.w, h = o.h,
        color = o.color, opacity = o.opacity }
    end
  end
  return r
end

-- Every text sits inside some background rectangle (one at least 40 px
-- wide, so bars and dots don't count). Returns the first one that doesn't.
local function overflow(r)
  for _, t in ipairs(r.texts) do
    local w, h = mcfont.width(t.content, t.size), mcfont.HEIGHT * t.size
    local inside = false
    for _, b in ipairs(r.rects) do
      if b.w >= 40 and t.x >= b.x and t.y >= b.y and t.x + w <= b.x + b.w and t.y + h <= b.y + b.h then
        inside = true
      end
    end
    if not inside then return t.content end
  end
end

local function hex(c) return ("#%06x"):format(c) end
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function svg(r, w, h)
  local out = { ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" '
    .. 'style="background:#5b5f57;image-rendering:pixelated">'):format(w, h, w * 3, h * 3) }
  for _, b in ipairs(r.rects) do
    out[#out + 1] = ('<rect x="%g" y="%g" width="%g" height="%g" fill="%s" fill-opacity="%g"/>')
      :format(b.x, b.y, b.w, b.h, hex(b.color), b.opacity)
  end
  for _, t in ipairs(r.texts) do
    -- One glyph per character at its mcfont position, so widths match the game.
    local x = t.x
    for c in t.content:gmatch(".") do
      local s = t.size
      out[#out + 1] = ('<text x="%g" y="%g" font-family="monospace" font-size="%g" fill="%s">%s</text>')
        :format(x, t.y + 7 * s, 8 * s, hex(t.color), esc(c))
      x = x + (mcfont.widths[c] or 6) * s
    end
  end
  out[#out + 1] = "</svg>"
  return table.concat(out, "\n")
end

local snapshot = {
  time = "16:20",
  computers = {
    { id = 1, label = "Rusty", role = "old miner", kind = "turtle", online = false, fuel = 198, jobs = {},
      where = { world = { 120, 30, -400 }, dim = "allthemodium:mining", by = "start" } },
    { id = 4, label = "Forgemother", role = "factory", kind = "turtle", online = true, fuel = 78,
      where = { world = { 3559, 74, 4763 }, dim = "overworld", by = "start" },
      jobs = { { program = "factory", tail = { "Factory running: 4 chests, 4 furnaces",
        "Stock: 308 cobble, 259 stone, 31 charcoal, 13 logs, 55 glass, 12 sand, 7 iron ingot, 3 diamonds" } } } },
    { id = 6, label = "Monocle", role = "glasses", kind = "computer", online = true, jobs = { { program = "hud", tail = {} } } },
    { id = 7, label = "Pebbles", role = "cobble", kind = "turtle", online = true, fuel = 133, jobs = { { program = "cobble", tail = {} } },
      where = { world = { 3548, 79, 3500 }, dim = "overworld", by = "start" } },
    { id = 9, label = "Otis", role = "elevator", kind = "turtle", online = true, fuel = 4751, jobs = {},
      where = { world = { 3547, 71, 4754 }, dim = "overworld", by = "start" } },
    { id = 5, label = "Keeper", role = "vault door", kind = "computer", online = true, jobs = {} },
    { id = 12, label = "computer-12", kind = "pocket", online = true, jobs = {} },
  },
  events = { { time = "16:19", text = "Keeper: Vault door opened, and this event text is long enough to wrap onto a second line" } },
  messages = { { time = "16:00", text = "Cobble machine is live!" } },
}

local function withAttention(acked)
  local s = {}
  for k, v in pairs(snapshot) do s[k] = v end
  s.attention = { id = 3, time = "16:20", text = "Come to the factory: the birth spot needs a floppy disk before I can build the next turtle.", acked = acked }
  return s
end

if SVG then
  local r = run({ { "bridge_push", "status", withAttention() } })
  print(svg(r, 640, 160))
  return
end

print("Waiting for the bridge")
local r = run({})
check(r.err == "END_OF_EVENTS", "runs (" .. tostring(r.err) .. ")")
check(r.sent[1] and r.sent[1].action == "subscribe", "subscribes to the dashboard feed")
local all = table.concat(r.lines, "\n")
check(all:find("waiting", 1, true), "says it is waiting")
check(overflow(r) == nil, "text fits the panel")

print("Full panel")
r = run({ { "bridge_push", "status", snapshot } })
all = table.concat(r.lines, "\n")
check(all:find("308 cobble", 1, true) and all:find("3 diamonds", 1, true), "factory stock, all of it")
check(all:find("Pebbles", 1, true) and all:find("cobble", 1, true), "fleet names and roles")
local amber = 0
for _, b in ipairs(r.rects) do if b.w == 4 and b.color == 0xFFC23D then amber = amber + 1 end end
check(amber == 2, "idle units get an amber dot (" .. amber .. ")")
check(all:find("Rusty", 1, true) ~= nil, "offline units are listed")
check(all:find("Monocle", 1, true) == nil, "leaves itself out")
check(all:find("computer-12", 1, true) == nil, "leaves pockets out")
check(all:find("Vault door opened", 1, true) ~= nil, "latest event")
check(all:find("Cobble machine is live", 1, true) ~= nil, "latest message")
local bad = overflow(r)
check(bad == nil, "every line fits its background (" .. tostring(bad) .. ")")
check(r.rects[1].w <= 290 + 20, "panel stays compact (" .. r.rects[1].w .. ")")
check(all:find("3559 74 4763", 1, true) and all:find("3547 71 4754", 1, true), "plain world coordinates")
check(all:find("120 30 -400 mining", 1, true) ~= nil, "the dimension when it is not the overworld")
check(all:find("Keeper", 1, true) and all:find("?", 1, true), "units without a position say so")
check(all:find("you: 3548 79 4749", 1, true) ~= nil, "the player's own position")

print("Hotkey cycles compact, hidden, full")
r = run({ { "bridge_push", "status", snapshot }, { "glasses_key_pressed", "key.keyboard.g", 120 } })
all = table.concat(r.lines, "\n")
check(all:find("Forgemother", 1, true) and all:find("308 cobble", 1, true) and all:find("Vault", 1, true)
  and not all:find("Pebbles", 1, true), "compact: factory and event")
check(overflow(r) == nil, "compact fits")
r = run({ { "bridge_push", "status", snapshot }, { "glasses_key_pressed" }, { "glasses_key_pressed" } })
check(#r.lines == 0 and #r.rects == 0, "hidden")
r = run({ { "bridge_push", "status", snapshot }, { "glasses_key_pressed" }, { "glasses_key_pressed" }, { "glasses_key_pressed" } })
check(table.concat(r.lines, "\n"):find("Pebbles", 1, true) ~= nil, "full again")

print("Factory offline")
local off = { time = "16:21", computers = { { id = 4, label = "Forgemother", role = "factory", online = false, jobs = {} } }, events = {}, messages = {} }
r = run({ { "bridge_push", "status", off } })
check(table.concat(r.lines, "\n"):find("Factory offline", 1, true) ~= nil, "says so")

print("Attention banner")
r = run({ { "bridge_push", "status", withAttention() } })
all = table.concat(r.lines, "\n")
check(all:find("CLAUDE NEEDS YOU", 1, true) ~= nil, "banner title")
check(all:find("floppy", 1, true) ~= nil, "banner text")
bad = overflow(r)
check(bad == nil, "banner text fits (" .. tostring(bad) .. ")")
r = run({ { "bridge_push", "status", withAttention() }, { "glasses_key_pressed" } })
all = table.concat(r.lines, "\n")
check(all:find("CLAUDE NEEDS YOU", 1, true) == nil, "hotkey dismisses it")
check(all:find("Pebbles", 1, true) ~= nil, "without changing the panel mode")
local ack = r.sent[#r.sent]
check(ack.action == "ack" and ack.id == 3, "tells the bridge it was seen")
r = run({ { "bridge_push", "status", withAttention() }, { "glasses_key_pressed" }, { "bridge_push", "status", withAttention() } })
check(table.concat(r.lines, "\n"):find("CLAUDE NEEDS YOU", 1, true) == nil, "stays dismissed")
r = run({ { "bridge_push", "status", withAttention("16:22") } })
check(table.concat(r.lines, "\n"):find("CLAUDE NEEDS YOU", 1, true) == nil, "hidden once acked elsewhere")

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll hud tests passed")
