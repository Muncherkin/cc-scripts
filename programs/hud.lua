-- Claude HUD for Advanced Peripherals smart glasses: a panel in the top-left
-- corner of the player's screen with the fleet, the factory's stock and the
-- latest news, plus a flashing banner when Claude needs the player
-- (node bridge/cli.js attention "<text>").
--
-- Data comes from the bridge's dashboard feed (the same one the wall
-- dashboard uses), so it runs as the agent autorun on the glasses:
--   node bridge/cli.js autorun hud --start --c <glasses id>
-- To restart it, `stop --c <id>` (no job id) first: the HUD never prints,
-- so after a bridge restart its job is not in `jobs`, and a second HUD
-- would fight the first over the same overlay objects.
-- The glasses hotkey dismisses the banner, otherwise it cycles the panel:
-- full -> compact -> hidden.
--
-- Everything is laid out in GUI pixels with lib.mcfont's text widths, so
-- the panels always fit their text. On the overlay a text's x, y is its
-- top-left corner but a rectangle's is its centre, and rectangles ignore the
-- width/height they are created with (setSizeX/Y work).

local mcfont = require("lib.mcfont")

local glasses = peripheral.find("smart_glasses")
if not glasses then error("No smart glasses here", 0) end
local overlay = glasses.getModule("advancedperipherals:overlay")
if not overlay then error("The glasses need the overlay module", 0) end

-- The Clockworks palette: Factory Block greys with a green accent.
local C = {
  panel = 0x14161A, head = 0x1F2328, edge = 0x2E3A30, accent = 0x5CE65C,
  text = 0xE8ECE8, dim = 0x8C948E, faint = 0x5A625C, good = 0x5CE65C,
  warn = 0xFFC23D, bad = 0xFF5F57, track = 0x2A2E33,
}
local X, Y = 4, 4       -- panel corner
local PAD, LINE = 5, 10 -- padding, line height
local MAX_W = 290       -- widest the panel gets
local MODES = { "full", "compact", "hidden" }
local mode = 1
local me = os.getComputerID()
local data -- last snapshot from the bridge
local dismissed = {} -- attention ids the player has seen
local flash = false

local function guiWidth()
  local w, _, s = overlay.getGuiSize()
  return math.floor((w or 640) / ((s and s > 0) and s or 1))
end

---------------------------------------------------------------------------
-- Drawing: each render builds a list of shapes, then a pool of overlay
-- objects is updated to match, touching only what changed.

local shapes
local function rect(x, y, w, h, color, opacity)
  shapes[#shapes + 1] = { kind = "rect", x = x, y = y, w = w, h = h, color = color, opacity = opacity or 1 }
end
-- Returns the text's width.
local function text(x, y, s, color, size)
  s = tostring(s)
  shapes[#shapes + 1] = { kind = "text", x = x, y = y, s = s, color = color or C.text, size = size or 1 }
  return mcfont.width(s, size)
end

local pool = { rect = {}, text = {} }

local function set(o, key, value, setter, ...)
  if o.state[key] ~= value then
    o.state[key] = value
    o.api[setter](...)
  end
end

local function apply()
  local used = { rect = 0, text = 0 }
  for _, s in ipairs(shapes) do
    used[s.kind] = used[s.kind] + 1
    local list = pool[s.kind]
    local o = list[used[s.kind]]
    if not o then
      local api
      if s.kind == "rect" then
        api = overlay.createRectangle({ x = 0, y = 0, color = 0 })
      else
        api = overlay.createText({ text = "", x = 0, y = 0, color = 0 })
        api.setShadow(true)
      end
      api.setGui(true)
      o = { api = api, state = {} }
      list[#list + 1] = o
    end
    set(o, "enabled", true, "setEnabled", true)
    set(o, "color", s.color, "setColor", s.color)
    if s.kind == "rect" then
      local cx, cy = s.x + s.w / 2, s.y + s.h / 2
      set(o, "x", cx, "setX", cx)
      set(o, "y", cy, "setY", cy)
      set(o, "w", s.w, "setSizeX", s.w)
      set(o, "h", s.h, "setSizeY", s.h)
      set(o, "opacity", s.opacity, "setOpacity", s.opacity)
    else
      set(o, "x", s.x, "setX", s.x)
      set(o, "y", s.y, "setY", s.y)
      set(o, "s", s.s, "setContent", s.s)
      set(o, "size", s.size, "setFontSize", s.size)
    end
  end
  for kind, list in pairs(pool) do
    for i = used[kind] + 1, #list do set(list[i], "enabled", false, "setEnabled", false) end
  end
  if not overlay.isAutoUpdating() then overlay.update() end
end

---------------------------------------------------------------------------
-- Content

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

-- Where the player is: the glasses know the wearer's eye position.
local function eye()
  local ok, x, y, z = pcall(overlay.getEyePosition)
  if ok and type(x) == "number" then return { x, y, z } end
end

-- A unit's world position as "x y z" (worked out by the bridge from where
-- its program started), plus the dimension when it is not the overworld.
local function coords(w)
  local dim = w and w.dim and w.dim ~= "overworld" and (w.dim:match(":(.*)") or w.dim)
  if not w or not w.world then return dim or "?" end
  local xyz = ("%d %d %d"):format(table.unpack(w.world))
  return dim and (xyz .. " " .. dim) or xyz
end

local function fuelColor(f) return f < 300 and C.bad or f < 1500 and C.warn or C.good end

-- The attention request to show, if any.
local function attention()
  local a = data and data.attention
  if a and not a.acked and not dismissed[a.id] then return a end
end

-- Rows are lists of cells laid out in columns; a cell is
-- { s = text, color = c } or { bar = fraction, color = c, w = width }.
local function panel()
  local rows, heads = {}, {}
  local function row(cells, opts) rows[#rows + 1] = { cells = cells, opts = opts or {} } end

  local now = data and data.time or "--:--"
  if not data then
    row({ { s = "waiting for the bridge", color = C.dim } }, { span = true })
    return rows, now
  end

  local comps = {}
  for _, c in ipairs(data.computers or {}) do
    if c.id ~= me and c.kind ~= "pocket" then comps[#comps + 1] = c end
  end
  table.sort(comps, function(a, b)
    if a.online ~= b.online then return a.online end
    return a.id < b.id
  end)

  local factory
  for _, c in ipairs(comps) do
    local stock = factoryStock(c)
    if stock then factory = { c = c, stock = stock } end
  end

  local full = MODES[mode] == "full"
  for _, c in ipairs(comps) do
    local job = c.jobs and c.jobs[1]
    local isFactory = factory and factory.c == c
    if full or isFactory then
      local dot = not c.online and C.bad or job and C.good or C.warn -- amber: online but idle
      local what = c.role or (job and job.program) or c.kind
      local cells = {
        { dot = dot },
        { s = c.label, color = c.online and C.text or C.dim },
        { s = what, color = c.online and C.dim or C.faint },
      }
      if c.fuel and type(c.fuel) == "number" then
        cells[4] = { bar = math.min(1, c.fuel / 5000), color = c.online and fuelColor(c.fuel) or C.faint, w = 20 }
        cells[5] = { s = tostring(c.fuel), color = c.online and C.dim or C.faint, right = true }
      else
        cells[4], cells[5] = { s = "", color = C.dim }, { s = "", color = C.dim }
      end
      if full then cells[6] = { s = coords(c.where), color = c.online and C.good or C.faint } end
      row(cells)
      if isFactory and c.online and factory.stock ~= "running" then
        row({ { s = factory.stock, color = C.good, wrap = 4, sep = ", " } }, { span = true, indent = 8 })
      end
    end
  end
  if not factory then row({ { s = "Factory offline", color = C.bad } }, { span = true }) end
  local me3 = full and eye()
  if me3 then
    row({ { s = ("you: %d %d %d"):format(math.floor(me3[1]), math.floor(me3[2]), math.floor(me3[3])), color = C.dim } },
      { span = true })
  end

  local a = attention()
  local ev = data.events and data.events[1]
  if ev then row({ { s = ev.time .. "  " .. ev.text, color = C.warn, wrap = full and 2 or 1 } }, { span = true, rule = true }) end
  local msg = data.messages and data.messages[1]
  if full and msg and not (a and msg.text == a.text) then
    row({ { s = "Claude: " .. msg.text, color = C.text, wrap = 3 } }, { span = true, rule = not ev })
  end
  return rows, now
end

local function drawPanel()
  local rows, now = panel()
  -- Column widths from the widest cell in each column.
  local cols, GAP = {}, 6
  for _, r in ipairs(rows) do
    if not r.opts.span then
      for i, cell in ipairs(r.cells) do
        local w = cell.dot and 4 or cell.bar and cell.w or mcfont.width(cell.s)
        cols[i] = math.max(cols[i] or 0, w)
      end
    end
  end
  local tableW = 0
  for i, w in ipairs(cols) do tableW = tableW + w + (i > 1 and GAP or 0) end
  if cols[1] then tableW = tableW - GAP + 4 end -- the dot sits closer
  -- Too wide: the third column (role, or coordinates) gives way.
  if cols[3] and tableW > MAX_W then
    cols[3] = math.max(30, cols[3] - (tableW - MAX_W))
    tableW = MAX_W
  end

  local title = "CLOCKWORKS"
  local headW = mcfont.width(title) + 12 + mcfont.width(now)
  local inner = math.min(MAX_W, math.max(headW, tableW, 120))
  -- Spanning rows wrap to the inner width; work out the lines now.
  for _, r in ipairs(rows) do
    if r.opts.span then
      local cell = r.cells[1]
      r.lines = mcfont.wrap(cell.s, inner - (r.opts.indent or 0), cell.wrap or 1, 1, cell.sep)
    end
  end

  local x0, y0 = X + PAD + 2, Y + 3
  local height = 0
  for _, r in ipairs(rows) do height = height + (r.lines and #r.lines or 1) * LINE + (r.opts.rule and 4 or 0) end
  local W, H = inner + PAD * 2 + 2, 14 + height + PAD

  -- Frame: body, header strip, green accent down the left edge.
  rect(X, Y, W, H, C.panel, 0.82)
  rect(X, Y, W, 13, C.head, 0.95)
  rect(X, Y, 2, H, C.accent, 1)
  rect(X + 2, Y + 13, W - 2, 1, C.edge, 1)
  text(x0, y0, title, C.accent)
  text(X + W - PAD - mcfont.width(now), y0, now, C.dim)

  local y = Y + 13 + 4
  for _, r in ipairs(rows) do
    if r.opts.rule then
      rect(x0, y, inner, 1, C.edge, 1)
      y = y + 4
    end
    if r.lines then
      for _, l in ipairs(r.lines) do
        text(x0 + (r.opts.indent or 0), y, l, r.cells[1].color)
        y = y + LINE
      end
    else
      local x = x0
      for i, cell in ipairs(r.cells) do
        if cell.dot then
          rect(x, y + 2, 4, 4, cell.dot, 1)
          x = x + 4 + 4
        else
          if cell.bar then
            rect(x, y + 3, cell.w, 3, C.track, 1)
            local fw = math.floor(cell.w * cell.bar + 0.5)
            if fw > 0 then rect(x, y + 3, fw, 3, cell.color, 1) end
          elseif cell.right then
            text(x + cols[i] - mcfont.width(cell.s), y, cell.s, cell.color)
          else
            text(x, y, mcfont.fit(cell.s, cols[i]), cell.color)
          end
          x = x + cols[i] + GAP
        end
      end
      y = y + LINE
    end
  end
end

-- The banner: centred near the top of the screen, flashing border.
local function drawBanner(a)
  local title = "CLAUDE NEEDS YOU"
  local foot = a.time .. "  -  hotkey to dismiss"
  local bodyW = math.min(260, math.max(mcfont.width(title, 2), mcfont.width(a.text), mcfont.width(foot)))
  local lines = mcfont.wrap(a.text, bodyW, 4)
  local W = bodyW + 16
  local H = 8 + 18 + #lines * LINE + 4 + LINE + 6
  local bx, by = math.floor((guiWidth() - W) / 2), 34 -- below the block tooltip
  local edge = flash and C.warn or C.accent
  rect(bx, by, W, H, C.panel, 0.9)
  rect(bx, by, W, 2, edge, 1)
  rect(bx, by + H - 2, W, 2, edge, 1)
  rect(bx, by, 2, H, edge, 1)
  rect(bx + W - 2, by, 2, H, edge, 1)
  local tw = mcfont.width(title, 2)
  text(bx + math.floor((W - tw) / 2), by + 8, title, flash and C.warn or C.accent, 2)
  local y = by + 8 + 18
  for _, l in ipairs(lines) do
    text(bx + math.floor((W - mcfont.width(l)) / 2), y, l, C.text)
    y = y + LINE
  end
  text(bx + math.floor((W - mcfont.width(foot)) / 2), y + 4, foot, C.dim)
end

local function render()
  shapes = {}
  if MODES[mode] ~= "hidden" then drawPanel() end
  local a = attention()
  if a then drawBanner(a) end
  apply()
end

---------------------------------------------------------------------------

overlay.clear()
-- The overlay draws the first text created after its first rectangle
-- underneath that rectangle, so spend that slot on an empty, zero-size pair.
overlay.createRectangle({ x = 0, y = 0, color = 0 }).setGui(true)
overlay.createText({ text = "", x = 0, y = 0, color = 0 }).setGui(true)
bridge.send({ action = "subscribe" })
render()
local tick = os.startTimer(5)
local flasher -- timer while the banner is up
local lastPush, lastSubscribe = nil, os.clock()

local function startFlashing()
  if attention() and not flasher then flasher = os.startTimer(0.5) end
end

while true do
  local ev, a, b = os.pullEvent()
  if ev == "bridge_push" and a == "status" then
    data, lastPush = b, os.clock()
    render()
    startFlashing()
  elseif ev == "glasses_key_pressed" then -- the hotkey module: key name, ms held
    local att = attention()
    if att then
      dismissed[att.id] = true
      bridge.send({ action = "ack", id = att.id })
    else
      mode = mode % #MODES + 1
    end
    render()
  elseif ev == "bridge_connected" then
    bridge.send({ action = "subscribe" })
    lastSubscribe = os.clock()
  elseif ev == "timer" and a == flasher then
    flasher = nil
    if attention() then
      flash = not flash
      render()
      flasher = os.startTimer(0.5)
    end
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
