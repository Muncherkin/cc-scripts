-- Claude OS: a small pocket-computer interface linked to the dev bridge.
--
-- Apps: Files (docs Claude sends to /docs, with a reader, tickable
-- checklists and printing), Messages, Fleet, Theme, About, Shell.
-- Talks to the bridge through the agent: os.queueEvent("bridge_send", data)
-- out, "bridge_push" events in. Mouse and keyboard both work.

local doc = require("lib.doc")
local chimeOk, chime = pcall(require, "lib.chime")

local VERSION = "1.0"
local DOCS = "/docs"
local STATE_DIR = "/.os"

local W, H = term.getSize()
local color = term.isColour()

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

local function load(name, default)
  local h = fs.open(STATE_DIR .. "/" .. name, "r")
  if not h then return default end
  local v = textutils.unserialise(h.readAll())
  h.close()
  return v or default
end

local function store(name, value)
  local h = fs.open(STATE_DIR .. "/" .. name, "w")
  h.write(textutils.serialise(value))
  h.close()
end

local settings = load("settings", { theme = 1 })
local seenDocs = load("seen", {})     -- doc path -> modified time when last opened
local checks = load("checks", {})     -- doc path -> { [item key] = true }
local readMark = load("read", "")     -- newest message already seen

---------------------------------------------------------------------------
-- Colors and themes (blit codes)
---------------------------------------------------------------------------

local THEMES = {
  { name = "Claude", accent = "1", on = "f" },
  { name = "Ocean", accent = "9", on = "f" },
  { name = "Grape", accent = "a", on = "0" },
  { name = "Forest", accent = "d", on = "0" },
  { name = "Ember", accent = "e", on = "0" },
  { name = "Gold", accent = "4", on = "f" },
}

local C = {}
local function applyTheme()
  local th = THEMES[settings.theme] or THEMES[1]
  C = {
    bg = "f", panel = "7", text = "0", dim = "8", accent = th.accent, on = th.on,
    good = "5", bad = "e", warn = "4", art = "4", check = "5",
  }
  if not color then
    for k, v in pairs(C) do
      if v ~= "f" and v ~= "7" and v ~= "8" then C[k] = "0" end
    end
    C.on = "f"
  end
end
applyTheme()

---------------------------------------------------------------------------
-- Screen buffer
---------------------------------------------------------------------------

local buf, clicks = {}, {}

local function clear(bg)
  for y = 1, H do
    buf[y] = { t = {}, f = {}, b = {} }
    for x = 1, W do buf[y].t[x], buf[y].f[x], buf[y].b[x] = " ", C.text, bg or C.bg end
  end
  clicks = {}
end

local function put(x, y, s, fg, bg, maxW)
  if y < 1 or y > H then return end
  s = tostring(s)
  local last = math.min(W, maxW and (x + maxW - 1) or W)
  for i = 1, #s do
    local cx = x + i - 1
    if cx > last then break end
    if cx >= 1 then
      local l = buf[y]
      l.t[cx] = s:sub(i, i)
      if fg then l.f[cx] = fg end
      if bg then l.b[cx] = bg end
    end
  end
end

local function fill(x1, y1, x2, y2, bg)
  for y = math.max(1, y1), math.min(H, y2) do
    for x = math.max(1, x1), math.min(W, x2) do buf[y].t[x], buf[y].b[x] = " ", bg end
  end
end

local function flush()
  for y = 1, H do
    term.setCursorPos(1, y)
    term.blit(table.concat(buf[y].t), table.concat(buf[y].f), table.concat(buf[y].b))
  end
end

local function onClick(x1, y1, x2, y2, fn)
  clicks[#clicks + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn }
end

local function centered(y, s, fg, bg)
  put(math.max(1, math.floor((W - #s) / 2) + 1), y, s, fg, bg)
end

---------------------------------------------------------------------------
-- Big 3x5 pixel font
---------------------------------------------------------------------------

local FONT = {
  ["0"] = { "###", "#.#", "#.#", "#.#", "###" }, ["1"] = { ".#.", "##.", ".#.", ".#.", "###" },
  ["2"] = { "###", "..#", "###", "#..", "###" }, ["3"] = { "###", "..#", "###", "..#", "###" },
  ["4"] = { "#.#", "#.#", "###", "..#", "..#" }, ["5"] = { "###", "#..", "###", "..#", "###" },
  ["6"] = { "###", "#..", "###", "#.#", "###" }, ["7"] = { "###", "..#", "..#", "..#", "..#" },
  ["8"] = { "###", "#.#", "###", "#.#", "###" }, ["9"] = { "###", "#.#", "###", "..#", "###" },
  [":"] = { ".", "#", ".", "#", "." },
  C = { "###", "#..", "#..", "#..", "###" }, L = { "#..", "#..", "#..", "#..", "###" },
  A = { "###", "#.#", "###", "#.#", "#.#" }, U = { "#.#", "#.#", "#.#", "#.#", "###" },
  D = { "##.", "#.#", "#.#", "#.#", "##." }, E = { "###", "#..", "##.", "#..", "###" },
}

local function bigWidth(s)
  local w = 0
  for i = 1, #s do w = w + #(FONT[s:sub(i, i)] or FONT["0"])[1] + 1 end
  return w - 1
end

local function drawBig(x, y, s, bg, upTo)
  for i = 1, #s do
    if upTo and i > upTo then break end
    local g = FONT[s:sub(i, i)]
    if g then
      for r = 1, 5 do
        for c = 1, #g[r] do
          if g[r]:sub(c, c) == "#" then fill(x + c - 1, y + r - 1, x + c - 1, y + r - 1, bg) end
        end
      end
      x = x + #g[1] + 1
    end
  end
end

---------------------------------------------------------------------------
-- Data from the bridge
---------------------------------------------------------------------------

local data            -- latest status snapshot
local lastPush        -- os.clock() of the last push
local toasts = {}     -- { text, untilClock }

local function bridgeSend(t) os.queueEvent("bridge_send", t) end

local function toast(text, sound)
  toasts[#toasts + 1] = { text = text, untilClock = os.clock() + 4 }
  if sound and chimeOk and peripheral.find("speaker") then
    -- play without blocking the UI for long
    pcall(chime.play, "done", 1)
  end
end

local function msgKey(m) return m and (m.time .. "|" .. m.text) or "" end

local function unreadCount()
  if not data or not data.messages then return 0 end
  local n = 0
  for _, m in ipairs(data.messages) do
    if msgKey(m) == readMark then break end
    n = n + 1
  end
  return n
end

---------------------------------------------------------------------------
-- Docs on disk
---------------------------------------------------------------------------

local titleCache = {}

local function docInfo(path)
  local attr = fs.attributes(path)
  local cached = titleCache[path]
  if cached and cached.modified == attr.modified then return cached end
  local h = fs.open(path, "r")
  local head = h and h.read(400) or ""
  if h then h.close() end
  local info = { modified = attr.modified, title = doc.title(head) or fs.getName(path):gsub("%.txt$", "") }
  titleCache[path] = info
  return info
end

local function isNew(path)
  return seenDocs[path] == nil or docInfo(path).modified > seenDocs[path]
end

local function countNew(dir)
  dir = dir or DOCS
  if not fs.isDir(dir) then return 0 end
  local n = 0
  for _, name in ipairs(fs.list(dir)) do
    local p = fs.combine(dir, name)
    if fs.isDir(p) then n = n + countNew(p) elseif isNew("/" .. p) then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------------------
-- Screens
---------------------------------------------------------------------------

local stack = {}
local function current() return stack[#stack] end
local function push(screen) stack[#stack + 1] = screen end
local function pop() if #stack > 1 then stack[#stack] = nil end end

local screens = {}

local function statusBar(title)
  fill(1, 1, W, 1, C.accent)
  put(2, 1, title or "CLAUDE OS", C.on, C.accent)
  local linked = lastPush and os.clock() - lastPush < 90
  local clock = textutils.formatTime(os.time(), true)
  put(W - #clock - 2, 1, clock, C.on, C.accent)
  put(W, 1, linked and "*" or "x", linked and C.on or C.bad, C.accent)
end

-- Notifications cover row 2 for a few seconds, on top of everything else.
local function drawToast()
  while toasts[1] and toasts[1].untilClock < os.clock() do table.remove(toasts, 1) end
  if toasts[1] then
    fill(1, 2, W, 2, C.accent)
    put(2, 2, toasts[1].text, C.on, C.accent, W - 2)
  end
end

local function backBar(title, right, rightFn)
  fill(1, 2, W, 2, C.panel)
  put(1, 2, " < ", C.on, C.accent)
  onClick(1, 2, 3, 2, function() pop() end)
  put(5, 2, title, C.text, C.panel, W - 5 - (right and #right + 1 or 0))
  if right then
    put(W - #right + 1, 2, right, C.on, C.accent)
    onClick(W - #right + 1, 2, W, 2, rightFn)
  end
end

local function list(sc, count, rowsTop, rowsBottom)
  -- keeps sc.sel visible within the rows and returns the first visible index
  local rows = rowsBottom - rowsTop + 1
  sc.sel = math.max(1, math.min(sc.sel or 1, math.max(1, count)))
  sc.scroll = sc.scroll or 0
  if sc.sel <= sc.scroll then sc.scroll = sc.sel - 1 end
  if sc.sel > sc.scroll + rows then sc.scroll = sc.sel - rows end
  sc.scroll = math.max(0, math.min(sc.scroll, math.max(0, count - rows)))
  return sc.scroll + 1, rows
end

local function scrollbar(top, bottom, first, rows, count)
  if count <= rows then return end
  local h = bottom - top + 1
  local size = math.max(1, math.floor(h * rows / count))
  local pos = top + math.floor((h - size) * (first - 1) / math.max(1, count - rows))
  fill(W, top, W, bottom, C.panel)
  fill(W, pos, W, pos + size - 1, C.accent)
end

-- HOME ------------------------------------------------------------------

local TILES = {
  { name = "FILES", open = function() push({ kind = "files", dir = DOCS }) end,
    badge = function() local n = countNew() return n > 0 and (n .. " new") end },
  { name = "MESSAGES", open = function() push({ kind = "messages" }) end,
    badge = function() local n = unreadCount() return n > 0 and tostring(n) end },
  { name = "FLEET", open = function() push({ kind = "fleet" }) end,
    badge = function()
      if not data then return nil end
      local n = 0
      for _, c in ipairs(data.computers) do if c.online then n = n + 1 end end
      return n .. " on"
    end },
  { name = "THEME", open = function() push({ kind = "theme", sel = settings.theme }) end },
  { name = "ABOUT", open = function() push({ kind = "about" }) end },
  { name = "SHELL", open = function() return "exit" end },
}

screens.home = {
  draw = function(sc)
    statusBar()
    local t = textutils.formatTime(os.time(), true)
    if #t == 4 then t = "0" .. t end
    drawBig(math.floor((W - bigWidth(t)) / 2) + 1, 3, t, C.accent)
    local online = 0
    for _, c in ipairs(data and data.computers or {}) do if c.online then online = online + 1 end end
    centered(9, ("Day %d  -  %s"):format(os.day(), data and (online .. " online") or "connecting..."), C.dim)
    sc.sel = sc.sel or 1
    for i, tile in ipairs(TILES) do
      local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
      local x, y = 2 + col * 13, 11 + row * 3
      local selected = i == sc.sel
      local bg = selected and C.accent or C.panel
      local fg = selected and C.on or C.text
      fill(x, y, x + 11, y + 1, bg)
      put(x + 1, y, tile.name, fg, bg)
      local badge = tile.badge and tile.badge()
      if badge then put(x + 11 - #badge, y + 1, badge, selected and C.on or C.accent, bg) end
      onClick(x, y, x + 11, y + 1, function() sc.sel = i return tile.open() end)
    end
    put(2, H, "arrows + enter, or tap", C.dim)
  end,
  key = function(sc, k)
    if k == keys.left then sc.sel = math.max(1, sc.sel - 1)
    elseif k == keys.right then sc.sel = math.min(#TILES, sc.sel + 1)
    elseif k == keys.up then sc.sel = math.max(1, sc.sel - 2)
    elseif k == keys.down then sc.sel = math.min(#TILES, sc.sel + 2)
    elseif k == keys.enter then return TILES[sc.sel].open() end
  end,
}

-- FILES -----------------------------------------------------------------

local function entries(dir)
  if not fs.isDir(dir) then return {} end
  local dirs, files = {}, {}
  for _, name in ipairs(fs.list(dir)) do
    local p = "/" .. fs.combine(dir, name)
    if fs.isDir(p) then
      dirs[#dirs + 1] = { path = p, label = name .. "/", dir = true, new = countNew(p) > 0 }
    else
      files[#files + 1] = { path = p, label = docInfo(p).title, new = isNew(p) }
    end
  end
  table.sort(dirs, function(a, b) return a.label < b.label end)
  table.sort(files, function(a, b) return a.label:lower() < b.label:lower() end)
  for _, f in ipairs(files) do dirs[#dirs + 1] = f end
  return dirs
end

local function openEntry(e)
  if e.dir then push({ kind = "files", dir = e.path }) else push({ kind = "reader", path = e.path }) end
end

screens.files = {
  draw = function(sc)
    statusBar()
    local shown = sc.dir:gsub("^" .. DOCS, "")
    backBar("Files" .. (shown ~= "" and shown or ""))
    sc.items = entries(sc.dir)
    local top, bottom = 3, H - 1
    local first, rows = list(sc, #sc.items, top, bottom)
    if #sc.items == 0 then
      put(2, 4, "No documents yet.", C.dim)
      put(2, 5, "Claude can send some.", C.dim)
    end
    for i = first, math.min(#sc.items, first + rows - 1) do
      local e, y = sc.items[i], top + i - first
      local selected = i == sc.sel
      local bg = selected and C.panel or C.bg
      fill(1, y, W - 1, y, bg)
      put(2, y, e.dir and "+" or "-", e.dir and C.accent or C.dim, bg)
      put(4, y, e.label, e.dir and C.accent or C.text, bg, W - 9)
      if e.new then put(W - 4, y, "NEW", C.on, C.accent) end
      onClick(1, y, W - 1, y, function() sc.sel = i openEntry(e) end)
    end
    scrollbar(top, bottom, first, rows, #sc.items)
    put(2, H, #sc.items .. " items", C.dim)
  end,
  key = function(sc, k)
    if k == keys.up then sc.sel = sc.sel - 1
    elseif k == keys.down then sc.sel = sc.sel + 1
    elseif k == keys.enter and sc.items[sc.sel] then openEntry(sc.items[sc.sel])
    elseif k == keys.backspace then pop() end
  end,
  scroll = function(sc, dir) sc.sel = (sc.sel or 1) + dir end,
}

-- READER ----------------------------------------------------------------

local function layoutDoc(path, width)
  local h = fs.open(path, "r")
  local src = h and h.readAll() or ""
  if h then h.close() end
  local blocks = doc.parse(src)
  local rows, items, title = {}, {}, nil
  local function row(text, fg, bg, item) rows[#rows + 1] = { text = text, fg = fg, bg = bg, item = item } end
  local mine = checks[path] or {}
  for _, b in ipairs(blocks) do
    if b.t == "title" then
      title = b.text
      for _, l in ipairs(doc.wrap(b.text, width)) do row(l, C.accent) end
    elseif b.t == "subtitle" then
      for _, l in ipairs(doc.wrap(b.text, width)) do row(l, C.dim) end
      row(("-"):rep(width), C.panel)
    elseif b.t == "heading" then
      if rows[#rows] and rows[#rows].text ~= "" then row("") end
      row(" " .. b.text:upper(), C.text, C.panel)
    elseif b.t == "item" then
      items[#items + 1] = b
      local done = mine[b.key]
      local label = (b.count and (b.count .. "x ") or "") .. b.name
      local lines = doc.wrap((done and "[x] " or "[ ] ") .. label, width, "    ")
      for i, l in ipairs(lines) do row(l, done and C.dim or C.text, nil, b) end
      rows[#rows - #lines + 1].box = done and C.check or C.accent
      if b.note then
        for _, l in ipairs(doc.wrap(b.note, width - 4)) do row("    " .. l, C.dim, nil, b) end
      end
    elseif b.t == "art" then
      row(b.text:sub(1, width), C.art)
    elseif b.t == "text" then
      for _, l in ipairs(doc.wrap(b.text, width)) do row(l, C.text) end
    elseif b.t == "blank" then
      row("")
    elseif b.t == "break" then
      row(("."):rep(width), C.panel)
    end
  end
  return rows, items, title
end

local function toggle(path, item)
  checks[path] = checks[path] or {}
  checks[path][item.key] = not checks[path][item.key] or nil
  store("checks", checks)
end

screens.reader = {
  open = function(sc)
    seenDocs[sc.path] = docInfo(sc.path).modified
    store("seen", seenDocs)
  end,
  draw = function(sc)
    statusBar()
    local rows, items, title = layoutDoc(sc.path, W - 2)
    sc.rows = rows
    backBar(title or fs.getName(sc.path), "PRINT", function()
      bridgeSend({ action = "print", path = sc.path:gsub("^" .. DOCS .. "/", "") })
      toast("Sending to the printer...")
    end)
    local top, bottom = 3, #items > 0 and H - 1 or H
    local first, n = list(sc, #rows, top, bottom)
    for i = first, math.min(#rows, first + n - 1) do
      local r, y = rows[i], top + i - first
      local selected = i == sc.sel and sc.keyboard
      local bg = r.bg or (selected and C.panel or C.bg)
      if r.bg or selected then fill(1, y, W - 1, y, bg) end
      put(2, y, r.text, r.fg, bg, W - 2)
      if r.box then put(2, y, r.text:sub(1, 3), r.box, bg) end
      if r.item then onClick(1, y, W - 1, y, function() sc.sel = i toggle(sc.path, r.item) end) end
    end
    scrollbar(top, bottom, first, n, #rows)
    if #items > 0 then
      local done = 0
      for _, it in ipairs(items) do if (checks[sc.path] or {})[it.key] then done = done + 1 end end
      local label = (" %d/%d"):format(done, #items)
      local barW = W - #label - 2
      fill(2, H, 1 + barW, H, C.panel)
      local filled = math.floor(barW * done / #items + 0.5)
      if filled > 0 then fill(2, H, 1 + filled, H, done == #items and C.good or C.accent) end
      put(2 + barW, H, label, done == #items and C.good or C.text)
    end
  end,
  key = function(sc, k)
    sc.keyboard = true
    if k == keys.up then sc.sel = sc.sel - 1
    elseif k == keys.down then sc.sel = sc.sel + 1
    elseif k == keys.pageUp then sc.sel = sc.sel - (H - 4)
    elseif k == keys.pageDown then sc.sel = sc.sel + (H - 4)
    elseif (k == keys.enter or k == keys.space) and sc.rows[sc.sel] and sc.rows[sc.sel].item then
      toggle(sc.path, sc.rows[sc.sel].item)
    elseif k == keys.p then
      bridgeSend({ action = "print", path = sc.path:gsub("^" .. DOCS .. "/", "") })
      toast("Sending to the printer...")
    elseif k == keys.backspace then pop() end
  end,
  scroll = function(sc, dir)
    -- scroll the view, keeping the cursor in it
    sc.scroll = (sc.scroll or 0) + dir * 3
    sc.sel = math.max(sc.scroll + 1, math.min(sc.sel or 1, sc.scroll + H - 3))
  end,
}

-- MESSAGES --------------------------------------------------------------

screens.messages = {
  open = function()
    if data and data.messages and data.messages[1] then
      readMark = msgKey(data.messages[1])
      store("read", readMark)
    end
  end,
  draw = function(sc)
    statusBar()
    backBar("Messages from Claude")
    local rows = {}
    for _, m in ipairs(data and data.messages or {}) do
      rows[#rows + 1] = { text = m.time, fg = C.accent }
      for _, l in ipairs(doc.wrap(m.text, W - 3)) do rows[#rows + 1] = { text = l, fg = C.text } end
      rows[#rows + 1] = { text = "" }
    end
    if #rows == 0 then rows[1] = { text = data and "No messages yet" or "Waiting for the bridge...", fg = C.dim } end
    local top = 3
    sc.scroll = math.max(0, math.min(sc.scroll or 0, #rows - (H - top + 1)))
    for i = sc.scroll + 1, math.min(#rows, sc.scroll + H - top + 1) do
      put(2, top + i - sc.scroll - 1, rows[i].text, rows[i].fg, nil, W - 2)
    end
    scrollbar(top, H, sc.scroll + 1, H - top + 1, #rows)
  end,
  key = function(sc, k)
    if k == keys.up then sc.scroll = (sc.scroll or 0) - 1
    elseif k == keys.down then sc.scroll = (sc.scroll or 0) + 1
    elseif k == keys.backspace then pop() end
  end,
  scroll = function(sc, dir) sc.scroll = (sc.scroll or 0) + dir * 2 end,
}

-- FLEET -----------------------------------------------------------------

screens.fleet = {
  draw = function(sc)
    statusBar()
    backBar("Fleet")
    local comps = data and data.computers or {}
    if #comps == 0 then put(2, 4, data and "No computers yet" or "Waiting for the bridge...", C.dim) end
    local top, per = 3, 5
    local visible = math.floor((H - top + 1) / per)
    sc.scroll = math.max(0, math.min(sc.scroll or 0, #comps - visible))
    for i = sc.scroll + 1, math.min(#comps, sc.scroll + visible) do
      local c, y = comps[i], top + (i - sc.scroll - 1) * per
      put(2, y, " ", nil, c.online and C.good or C.bad)
      put(4, y, c.label, C.text, nil, W - 12)
      put(W - #c.kind, y, c.kind, C.dim)
      if c.fuel and type(c.fuel) == "number" then
        local barW = W - 12
        local filled = math.floor(barW * math.min(1, c.fuel / 5000) + 0.5)
        fill(4, y + 1, 3 + barW, y + 1, C.panel)
        if filled > 0 then fill(4, y + 1, 3 + filled, y + 1, c.fuel < 300 and C.bad or c.fuel < 1500 and C.warn or C.good) end
        put(5 + barW, y + 1, tostring(c.fuel), C.dim)
      end
      if c.pos then
        local where = ("@ %d,%d,%d"):format(c.pos.x, c.pos.y, c.pos.z) .. (c.pos.frame == "world" and "" or " (start)")
        put(4, y + 4, where, c.pos.frame == "world" and C.good or C.dim, nil, W - 4)
      end
      local job = c.jobs and c.jobs[1]
      if not c.online then
        put(4, y + 2, "offline since " .. c.lastSeen, C.bad)
      elseif job then
        put(4, y + 2, "> " .. job.program, C.accent, nil, W - 4)
        if job.tail and job.tail[#job.tail] then put(4, y + 3, job.tail[#job.tail], C.dim, nil, W - 4) end
      else
        put(4, y + 2, c.dashboard and "dashboard" or "idle", C.dim)
      end
    end
    scrollbar(top, H, sc.scroll + 1, visible, #comps)
  end,
  key = function(sc, k)
    if k == keys.up then sc.scroll = (sc.scroll or 0) - 1
    elseif k == keys.down then sc.scroll = (sc.scroll or 0) + 1
    elseif k == keys.backspace then pop() end
  end,
  scroll = function(sc, dir) sc.scroll = (sc.scroll or 0) + dir end,
}

-- THEME -----------------------------------------------------------------

screens.theme = {
  draw = function(sc)
    statusBar()
    backBar("Theme")
    for i, th in ipairs(THEMES) do
      local y = 2 + i * 2
      local selected = i == sc.sel
      fill(2, y, 3, y, th.accent)
      put(5, y, th.name, selected and C.accent or C.text)
      if i == settings.theme then put(W - 8, y, "active", C.dim) end
      onClick(1, y, W, y, function() sc.sel = i settings.theme = i store("settings", settings) applyTheme() end)
    end
    put(2, H, "tap or enter to apply", C.dim)
  end,
  key = function(sc, k)
    if k == keys.up then sc.sel = math.max(1, sc.sel - 1)
    elseif k == keys.down then sc.sel = math.min(#THEMES, sc.sel + 1)
    elseif k == keys.enter then settings.theme = sc.sel store("settings", settings) applyTheme()
    elseif k == keys.backspace then pop() end
  end,
}

-- ABOUT -----------------------------------------------------------------

screens.about = {
  draw = function()
    statusBar()
    backBar("About")
    drawBig(math.floor((W - bigWidth("CLAUDE")) / 2) + 1, 4, "CLAUDE", C.accent)
    centered(10, "O S   v" .. VERSION, C.text)
    centered(12, "computer #" .. os.getComputerID() .. (pocket and " (pocket)" or ""), C.dim)
    centered(13, (lastPush and "linked to the bridge" or "not linked yet"), lastPush and C.good or C.bad)
    centered(15, "Claude adds docs to /docs", C.dim)
    centered(16, "tick checklists by tapping", C.dim)
    centered(17, "P in a doc prints it", C.dim)
    centered(19, "made by Claude & you", C.accent)
  end,
  key = function(_, k) if k == keys.backspace then pop() end end,
}

---------------------------------------------------------------------------
-- Boot animation
---------------------------------------------------------------------------

local function boot()
  local word = "CLAUDE"
  local x = math.floor((W - bigWidth(word)) / 2) + 1
  for step = 0, #word + 6 do
    clear()
    drawBig(x, 5, word, C.accent, step)
    if step > #word then centered(12, "O S", C.text) end
    local barW = W - 8
    fill(5, 15, 4 + barW, 15, C.panel)
    fill(5, 15, 4 + math.floor(barW * step / (#word + 6)), 15, C.accent)
    centered(17, step > #word + 3 and "linking to Claude..." or "starting...", C.dim)
    flush()
    local t = os.startTimer(0.08)
    while true do
      local ev, a = os.pullEvent()
      if ev == "timer" and a == t then break end
      if ev == "key" or ev == "mouse_click" then return end
    end
  end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

local function redraw()
  clear()
  local sc = current()
  screens[sc.kind].draw(sc)
  drawToast()
  flush()
end

local function run()
  fs.makeDir(STATE_DIR)
  boot()
  push({ kind = "home" })
  bridgeSend({ action = "subscribe" })
  local lastSubscribe = os.clock()
  local tick = os.startTimer(1)
  local lastMessage = nil
  redraw()

  while true do
    local ev, a, b, c = os.pullEvent()
    local before = #stack
    local result
    local sc = current()
    if ev == "key" then
      if screens[sc.kind].key then result = screens[sc.kind].key(sc, a) end
    elseif ev == "mouse_click" or ev == "monitor_touch" then
      local x, y = b, c
      for i = #clicks, 1, -1 do
        local r = clicks[i]
        if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then result = r.fn() break end
      end
    elseif ev == "mouse_scroll" then
      if screens[sc.kind].scroll then screens[sc.kind].scroll(sc, a) end
    elseif ev == "bridge_push" then
      lastPush = os.clock()
      if a == "status" then
        data = b
        local newest = data.messages and data.messages[1]
        if newest and lastMessage ~= nil and msgKey(newest) ~= lastMessage and msgKey(newest) ~= readMark then
          toast("New message from Claude", true)
        end
        lastMessage = msgKey(newest)
        if current().kind == "messages" then screens.messages.open() end
      elseif a == "docs" then
        local n = b and b.files and #b.files or 0
        toast(("Claude sent %d doc%s"):format(n, n == 1 and "" or "s"), true)
      elseif a == "toast" then
        toast(b.text, true)
      end
    elseif ev == "bridge_connected" then
      bridgeSend({ action = "subscribe" })
      lastSubscribe = os.clock()
    elseif ev == "timer" and a == tick then
      if (not lastPush or os.clock() - lastPush > 70) and os.clock() - lastSubscribe > 30 then
        bridgeSend({ action = "subscribe" })
        lastSubscribe = os.clock()
      end
      tick = os.startTimer(1)
    elseif ev == "term_resize" then
      W, H = term.getSize()
    end
    if result == "exit" then break end
    if #stack > before and screens[current().kind].open then screens[current().kind].open(current()) end
    redraw()
  end
end

local ok, err = pcall(run)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
print("Claude OS closed. Type 'claudeos' to come back.")
