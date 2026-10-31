-- Claude HUD for Advanced Peripherals smart glasses: a small panel in the
-- top-left corner of the player's screen with the factory's stock, what the
-- fleet is doing and the latest news from the bridge.
--
-- Data comes from the bridge's dashboard feed (the same one the wall
-- dashboard uses), so it runs as the agent autorun on the glasses:
--   node bridge/cli.js autorun hud --start --c <glasses id>
-- The glasses hotkey cycles the panel: full -> compact -> hidden.

local glasses = peripheral.find("smart_glasses")
if not glasses then error("No smart glasses here", 0) end
local overlay = glasses.getModule("advancedperipherals:overlay")
if not overlay then error("The glasses need the overlay module", 0) end

local X, Y, LINE, PAD = 4, 4, 10, 4
local WIDTH, CHARS = 236, 40 -- the Minecraft font is about 6 px a character
local MAX_LINES = 12
local C = {
  title = 0x55FF55, text = 0xFFFFFF, dim = 0x9A9A9A,
  good = 0x7CFC9A, warn = 0xFFD24A, bad = 0xFF6B6B, bg = 0x101010,
}
local MODES = { "full", "compact", "hidden" }
local mode = 1
local me = os.getComputerID()
local data -- last snapshot from the bridge

overlay.clear()
local bg = overlay.createRectangle({ x = X, y = Y, width = WIDTH, height = LINE, color = C.bg, opacity = 0.55 })
bg.setGui(true)
bg.setSizeX(WIDTH)
local texts = {}
for i = 1, MAX_LINES do
  texts[i] = overlay.createText({ text = "", x = X + PAD, y = Y + PAD + (i - 1) * LINE, color = C.text })
  texts[i].setGui(true)
end

local function fit(s)
  s = tostring(s)
  return #s > CHARS and s:sub(1, CHARS - 2) .. ".." or s
end

-- The last "Stock: ..." line the factory printed, if any.
local function factoryStock(c)
  for _, job in ipairs(c.jobs or {}) do
    if job.program == "factory" then
      for i = #(job.tail or {}), 1, -1 do
        local stock = job.tail[i]:match("^Stock: (.*)")
        if stock then return stock end
      end
      return "running"
    end
  end
end

-- The lines to show, as { text, color } pairs.
local function lines()
  local out = {}
  local function add(text, color) out[#out + 1] = { fit(text), color or C.text } end
  add("CLAUDE  " .. (data and data.time or "--:--") .. (data and "" or "  waiting for the bridge"), C.title)
  if not data then return out end

  local factory, offline = nil, 0
  for _, c in ipairs(data.computers or {}) do
    local stock = factoryStock(c)
    if stock then factory = { c = c, stock = stock } end
    if not c.online then offline = offline + 1 end
  end
  if factory and factory.c.online then
    -- "308 cobble, 259 stone, ..." wrapped onto as many lines as it takes.
    local line = "Factory "
    for part in factory.stock:gmatch("[^,]+") do
      part = part:gsub("^%s+", "")
      if #line + #part + 2 > CHARS then
        add(line, C.good)
        line = "       "
      end
      line = line .. " " .. part
    end
    add(line, C.good)
  else
    add("Factory: offline", C.bad)
  end

  if MODES[mode] == "full" then
    for _, c in ipairs(data.computers or {}) do
      if c.online and c.id ~= me then
        local job = c.jobs and c.jobs[1]
        local what = job and job.program or "idle"
        local fuel = c.fuel and ("  fuel " .. c.fuel) or ""
        add(("%-11s %-11s%s"):format(c.label, what, fuel), job and C.text or C.dim)
      end
    end
    if offline > 0 then add(("+%d offline"):format(offline), C.dim) end
  end

  local ev = data.events and data.events[1]
  if ev then add("! " .. ev.time .. " " .. ev.text, C.warn) end
  if MODES[mode] == "full" then
    local msg = data.messages and data.messages[1]
    if msg then add("> " .. msg.text, C.text) end
  end
  return out
end

local function render()
  local show = MODES[mode] ~= "hidden" and lines() or {}
  for i, t in ipairs(texts) do
    local l = show[i]
    t.setEnabled(l ~= nil)
    if l then
      t.setContent(l[1])
      t.setColor(l[2])
    end
  end
  bg.setEnabled(#show > 0)
  bg.setSizeY(math.max(LINE, #show * LINE + PAD * 2 - 2))
  if not overlay.isAutoUpdating() then overlay.update() end
end

bridge.send({ action = "subscribe" })
render()
local tick = os.startTimer(5)
local lastPush, lastSubscribe = nil, os.clock()

while true do
  local ev, a, b = os.pullEvent()
  if ev == "bridge_push" and a == "status" then
    data, lastPush = b, os.clock()
    render()
  elseif ev == "hotkey" then
    mode = mode % #MODES + 1
    render()
  elseif ev == "bridge_connected" then
    bridge.send({ action = "subscribe" })
    lastSubscribe = os.clock()
  elseif ev == "timer" and a == tick then
    -- The bridge pushes at least once a minute; if it goes quiet it has
    -- probably restarted and forgotten us, so subscribe again.
    if (not lastPush or os.clock() - lastPush > 70) and os.clock() - lastSubscribe > 30 then
      bridge.send({ action = "subscribe" })
      lastSubscribe = os.clock()
    end
    tick = os.startTimer(5)
  end
end
