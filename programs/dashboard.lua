-- Claude's control screen: shows every computer on the bridge, messages from
-- Claude and recent events on an (advanced) monitor, with touch controls.
-- Data is pushed by the bridge (see bridge/dashboard.js); run it through the
-- agent so the `bridge` API exists.
--
-- Usage: dashboard [monitor name]

local monName = ...
local mon = monName and peripheral.wrap(monName) or peripheral.find("monitor")
if not mon then error("No monitor attached", 0) end
if not bridge then error("Run this through the agent (it needs the bridge API)", 0) end

mon.setTextScale(0.5)
local W, H = mon.getSize()
local color = mon.isColour()

-- Palette (blit hex codes).
local C = {
  bg = "f", panel = "7", text = "0", dim = "8", accent = "1", head = "b",
  good = "5", warn = "4", bad = "e", dark = "f", white = "0",
}
if not color then
  for k, v in pairs(C) do C[k] = (v == "f" or v == "7") and v or "0" end
end

local data            -- last status snapshot from the bridge
local detail          -- detail view data, or nil for the overview
local lastPush = nil  -- os.clock() of the last push
local confirmUntil = 0
local buttons = {}

---------------------------------------------------------------------------
-- Drawing into a buffer, then blitting it line by line
---------------------------------------------------------------------------

local buf = {}

local function clear()
  for y = 1, H do
    buf[y] = { text = {}, fg = {}, bg = {} }
    for x = 1, W do buf[y].text[x], buf[y].fg[x], buf[y].bg[x] = " ", C.text, C.bg end
  end
  buttons = {}
end

local function put(x, y, text, fg, bg, maxWidth)
  if y < 1 or y > H then return end
  text = tostring(text)
  local limit = math.min(W, maxWidth and x + maxWidth - 1 or W)
  for i = 1, #text do
    local cx = x + i - 1
    if cx > limit then break end
    if cx >= 1 then
      local line = buf[y]
      line.text[cx] = text:sub(i, i)
      if fg then line.fg[cx] = fg end
      if bg then line.bg[cx] = bg end
    end
  end
end

local function fill(x1, y1, x2, y2, bg)
  for y = math.max(1, y1), math.min(H, y2) do
    for x = math.max(1, x1), math.min(W, x2) do
      buf[y].text[x], buf[y].bg[x] = " ", bg
    end
  end
end

local function flush()
  for y = 1, H do
    local l = buf[y]
    mon.setCursorPos(1, y)
    mon.blit(table.concat(l.text), table.concat(l.fg), table.concat(l.bg))
  end
end

local function button(x, y, label, fg, bg, action)
  local text = " " .. label .. " "
  put(x, y, text, fg, bg)
  buttons[#buttons + 1] = { x1 = x, x2 = x + #text - 1, y1 = y, y2 = y, action = action }
  return x + #text + 1
end

local function wrap(text, width)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    while #word > width do
      if #line > 0 then lines[#lines + 1] = line line = "" end
      lines[#lines + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if #line == 0 then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1] = line line = word end
  end
  if #line > 0 then lines[#lines + 1] = line end
  return lines
end

---------------------------------------------------------------------------
-- Screens
---------------------------------------------------------------------------

local function linkStatus()
  if not lastPush then return "WAITING", C.warn end
  local age = os.clock() - lastPush
  if age > 90 then return "NO LINK", C.bad end
  return "LINK OK", C.good
end

local function header(subtitle)
  fill(1, 1, W, 1, C.head)
  put(1, 1, " CLAUDE ", C.dark, C.accent)
  put(10, 1, "cc-scripts control", C.white, C.head)
  local link, linkColor = linkStatus()
  local right = (data and data.time or "--:--") .. "  "
  put(W - #right - #link - 2, 1, right, C.white, C.head)
  put(W - #link - 1, 1, " " .. link .. " ", C.dark, linkColor)
  put(2, 2, subtitle or "", C.dim, C.bg, W - 2)
end

local function fuelBar(x, y, width, fuel)
  if fuel == nil then
    put(x, y, "no fuel needed", C.dim)
    return
  end
  if fuel == "unlimited" then put(x, y, "fuel: unlimited", C.dim) return end
  local frac = math.min(1, fuel / 5000)
  local barColor = fuel < 300 and C.bad or fuel < 1500 and C.warn or C.good
  local filled = math.floor(frac * width + 0.5)
  fill(x, y, x + width - 1, y, C.panel)
  if filled > 0 then fill(x, y, x + filled - 1, y, barColor) end
  put(x + width + 1, y, tostring(fuel), C.text)
end

local function drawCard(c, x, y, width)
  local dot = c.online and C.good or C.bad
  put(x, y, " ", nil, dot)
  put(x + 2, y, c.label, C.white, nil, width - 16)
  local tag = c.dashboard and "this screen" or c.kind
  put(x + width - #tag - 1, y, tag, C.dim)
  if c.kind == "turtle" then
    put(x + 2, y + 1, "fuel", C.dim)
    fuelBar(x + 7, y + 1, math.min(20, width - 16), c.fuel)
  else
    put(x + 2, y + 1, c.online and "online" or ("offline since " .. c.lastSeen), C.dim)
  end
  if not c.online then
    put(x + 2, y + 2, "OFFLINE  last seen " .. c.lastSeen, C.bad, nil, width - 2)
  elseif #c.jobs == 0 then
    put(x + 2, y + 2, c.dashboard and "showing this dashboard" or "idle", C.dim, nil, width - 2)
  else
    local j = c.jobs[1]
    put(x + 2, y + 2, "> " .. j.program .. (#c.jobs > 1 and ("  (+" .. (#c.jobs - 1) .. " more)") or ""), C.accent, nil, width - 2)
    local last = j.tail[#j.tail]
    if last then
      for i, l in ipairs(wrap(last, width - 4)) do
        if i > 2 then break end
        put(x + 4, y + 2 + i, l, C.text)
      end
    end
  end
  buttons[#buttons + 1] = {
    x1 = x, x2 = x + width - 1, y1 = y, y2 = y + 4,
    action = function() detail = { id = c.id, label = c.label, loading = true } bridge.send({ action = "detail", computer = c.id }) end,
  }
end

local function drawOverview()
  local comps = data and data.computers or {}
  local online, running = 0, 0
  for _, c in ipairs(comps) do
    if c.online then online = online + 1 end
    running = running + #c.jobs
  end
  header(("%d of %d online  -  %d programs running  -  tap a card for details"):format(online, #comps, running))

  local twoCol = W >= 70
  local leftW = twoCol and math.floor(W * 0.56) or W - 2
  local top, bottom = 4, H - 2

  -- Fleet
  put(2, top, "FLEET", C.accent)
  local y = top + 2
  for _, c in ipairs(comps) do
    if y + 4 > bottom then put(2, bottom, "... more computers than fit", C.dim) break end
    drawCard(c, 2, y, leftW - 1)
    y = y + 6
  end
  if #comps == 0 then put(2, y, data and "No computers yet" or "Waiting for the bridge...", C.dim) end

  -- Messages and events (right column, or below the fleet on narrow screens)
  local rx, rw = twoCol and leftW + 3 or 2, twoCol and W - leftW - 4 or W - 2
  local ry = twoCol and top or y + 1
  if twoCol then
    for yy = top, bottom do put(leftW + 1, yy, " ", nil, C.panel) end
  end
  put(rx, ry, "FROM CLAUDE", C.accent)
  ry = ry + 2
  local msgBottom = twoCol and math.floor((top + bottom) / 2) or bottom - 6
  for _, m in ipairs(data and data.messages or {}) do
    local lines = wrap(m.text, rw - 6)
    if ry + #lines > msgBottom then break end
    put(rx, ry, m.time, C.dim)
    for i, l in ipairs(lines) do put(rx + 6, ry + i - 1, l, C.white) end
    ry = ry + #lines + 1
  end
  if not data or #data.messages == 0 then put(rx, ry, "No messages yet", C.dim) end

  ry = msgBottom + 1
  put(rx, ry, "EVENTS", C.accent)
  ry = ry + 2
  for _, e in ipairs(data and data.events or {}) do
    if ry > bottom then break end
    put(rx, ry, e.time, C.dim)
    local bad = e.text:find("error") or e.text:find("lost") or e.text:find("offline") or e.text:find("STOP")
    put(rx + 6, ry, e.text, bad and C.bad or C.text, nil, rw - 6)
    ry = ry + 1
  end

  -- Controls (basic monitors can't be touched)
  if not color then
    put(2, H, "Basic monitor: touch controls need advanced monitors", C.dim)
    return
  end
  local bx = 2
  if os.clock() < confirmUntil then
    bx = button(bx, H, "TAP AGAIN TO STOP EVERYTHING", C.white, C.bad, function()
      confirmUntil = 0
      bridge.send({ action = "stop_all" })
    end)
  else
    bx = button(bx, H, "STOP ALL", C.white, C.bad, function() confirmUntil = os.clock() + 5 end)
  end
  button(bx, H, "REFRESH", C.dark, C.dim, function() bridge.send({ action = "subscribe" }) end)
end

local function drawDetail()
  header((detail.label or "") .. (detail.program and ("  -  " .. detail.program .. " (" .. tostring(detail.state) .. ")") or ""))
  local lines = detail.lines or {}
  if detail.loading then
    put(2, 4, "Loading...", C.dim)
  elseif #lines == 0 then
    put(2, 4, "No output from this computer yet", C.dim)
  end
  local rows = H - 5
  local first = math.max(1, #lines - rows + 1)
  for i = first, #lines do
    put(2, 4 + i - first, lines[i], (lines[i]:find("rror") or lines[i]:find("FAIL")) and C.bad or C.text, nil, W - 2)
  end
  local bx = button(2, H, "BACK", C.dark, C.dim, function() detail = nil end)
  button(bx, H, "RELOAD", C.dark, C.dim, function() bridge.send({ action = "detail", computer = detail.id }) end)
end

local function redraw()
  clear()
  if detail then drawDetail() else drawOverview() end
  flush()
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

print("Dashboard on " .. peripheral.getName(mon) .. " (" .. W .. "x" .. H .. ")")
bridge.send({ action = "subscribe" })
redraw()
local tick = os.startTimer(1)
local lastSubscribe = os.clock()

while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "bridge_push" then
    lastPush = os.clock()
    if a == "status" then
      data = b
    elseif a == "detail" and detail and b.id == detail.id then
      detail = b
    end
    redraw()
  elseif ev == "monitor_touch" and a == peripheral.getName(mon) then
    for _, btn in ipairs(buttons) do
      if b >= btn.x1 and b <= btn.x2 and c >= btn.y1 and c <= btn.y2 then
        btn.action()
        break
      end
    end
    redraw()
  elseif ev == "monitor_resize" then
    W, H = mon.getSize()
    redraw()
  elseif ev == "timer" and a == tick then
    -- The bridge pushes at least once a minute; if it goes quiet it has
    -- probably restarted and forgotten us, so subscribe again.
    if (not lastPush or os.clock() - lastPush > 70) and os.clock() - lastSubscribe > 30 then
      bridge.send({ action = "subscribe" })
      lastSubscribe = os.clock()
    end
    redraw()
    tick = os.startTimer(1)
  end
end
