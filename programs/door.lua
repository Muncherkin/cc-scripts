-- SECURE-OS vault terminal: opens the redstone door next to the computer for
-- the right passphrase. Made for a basic (monochrome) computer.
--
-- It runs in the foreground shell, where the keyboard goes; doorboot (the
-- agent autorun) types "door" into the shell at boot. Ctrl+T doesn't stop
-- it: "exit" does, after the passphrase.
--
-- At the prompt, a passphrase opens the door. A few words do other things:
-- help, hack, matrix, whoami, passwd, exit.
--
-- Config lives on the computer in /.door (never in the repo):
--   { pass = "...", side = "right", hold = 5 }
-- "right" is the computer's right, which is your left facing the screen.

local CONFIG = "/.door"
local MAX_TRIES = 3
local LOCKOUT = 30

local cfg = { side = "right", hold = 5 }
do
  local h = fs.open(CONFIG, "r")
  if h then
    for k, v in pairs(textutils.unserialise(h.readAll()) or {}) do cfg[k] = v end
    h.close()
  end
end

local function save()
  local h = fs.open(CONFIG, "w")
  h.write(textutils.serialise(cfg))
  h.close()
end

local W, H = term.getSize()

---------------------------------------------------------------------------
-- Screen helpers
---------------------------------------------------------------------------

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function at(x, y, text)
  term.setCursorPos(x, y)
  term.write(text)
end

local function center(y, text) at(math.max(1, math.floor((W - #text) / 2) + 1), y, text) end

-- Prints a line a few characters per tick, like an old terminal.
local function typeOut(text, speed)
  speed = speed or 4
  for i = 1, #text, speed do
    write(text:sub(i, i + speed - 1))
    sleep(0.05)
  end
  print()
end

local function box(y, text)
  local inner = (" "):rep(4) .. text .. (" "):rep(4)
  center(y, "+" .. ("-"):rep(#inner) .. "+")
  center(y + 1, "|" .. inner .. "|")
  center(y + 2, "+" .. ("-"):rep(#inner) .. "+")
end

-- Says something on the wall dashboard and in Claude OS.
local function report(text) os.queueEvent("bridge_send", { action = "event", text = text }) end

-- Sounds on a speaker beside the terminal, if there is one. They tell what
-- was entered (the right passphrase, a wrong one, a command), never the
-- keys pressed, so nobody can learn the passphrase by ear.
local speaker = peripheral and peripheral.find and peripheral.find("speaker")
local function beep(instrument, pitch, volume)
  if speaker then pcall(speaker.playNote, instrument, volume or 1, pitch) end
end
local function tune(notes, gap)
  for _, n in ipairs(notes) do
    beep(n[1], n[2], n[3])
    sleep(gap or 0.12)
  end
end
local SOUNDS = {
  granted = { { "bell", 12 }, { "bell", 16 }, { "bell", 19 }, { "chime", 24, 1.5 } },
  closing = { { "basedrum", 4, 1.5 }, { "basedrum", 0, 1.5 } },
  hello = { { "chime", 14 }, { "chime", 19 } },
  bye = { { "chime", 19 }, { "chime", 14 }, { "chime", 7 } },
}
-- Wrong: a falling buzz, deeper with each try.
local function denied(try)
  local top = math.max(2, 14 - try * 4)
  tune({ { "didgeridoo", top }, { "didgeridoo", top - 2 }, { "didgeridoo", top - 4 } }, 0.15)
end

local BANNER = {
  "  ____  _____ ____ _   _ ____  _____ ",
  " / ___|| ____/ ___| | | |  _ \\| ____|",
  " \\___ \\|  _|| |   | | | | |_) |  _|  ",
  "  ___) | |__| |___| |_| |  _ <| |___ ",
  " |____/|_____\\____|\\___/|_| \\_\\_____|",
}

local function header()
  clear()
  for i, line in ipairs(BANNER) do center(i, line) end
  center(7, "VAULT TERMINAL  v2.7  -  CLAUDE INDUSTRIES")
  center(8, ("="):rep(math.min(W - 2, 44)))
  term.setCursorPos(1, 10)
end

---------------------------------------------------------------------------
-- Touch keypad on an attached (advanced) monitor, if there is one
---------------------------------------------------------------------------

local KEYS = {
  { "1", "2", "3", "a" },
  { "4", "5", "6", "b" },
  { "7", "8", "9", "c" },
  { "d", "0", "e", "f" },
  { "CLR", "OK" },
}
local mon = peripheral and peripheral.find and peripheral.find("monitor")
local pad = {}

local function padColour(c, fallback) return (mon and mon.isColour and mon.isColour()) and c or fallback end
-- Text scale 1 if the keypad fits, else 0.5. Returns the size.
local function fit()
  mon.setTextScale(1)
  local w, h = mon.getSize()
  if w < 15 or h < 10 then mon.setTextScale(0.5) w, h = mon.getSize() end
  return w, h
end

-- The look: the base's dark plating and green. A title bar, the code as
-- dots in a recessed field, dark keys with green labels on a frame; red CLR,
-- green OK. colour is a name ("green"), so callers need no colours table
-- without a monitor. Remembers where each key is for touches.
local function fill(x0, y0, x1, y1, bg)
  mon.setBackgroundColour(bg)
  for y = y0, y1 do
    mon.setCursorPos(x0, y)
    mon.write((" "):rep(x1 - x0 + 1))
  end
end
local function text(x, y, t, fg, bg)
  mon.setCursorPos(x, y)
  if bg then mon.setBackgroundColour(bg) end
  mon.setTextColour(fg)
  mon.write(t)
end
local function centred(y, x0, x1, t, fg, bg)
  text(x0 + math.max(0, math.floor((x1 - x0 + 1 - #t) / 2)), y, t, fg, bg)
end

pad.lit = nil      -- a key flashing after a tap
pad.blink = true   -- the cursor in the field

function pad.draw(code, status, colour)
  if not mon then return end
  local w, h = fit()
  local FRAME = padColour(colours.grey, colours.black)
  local GREEN = padColour(colours.lime, colours.white)
  local DARK = padColour(colours.black, colours.black)
  mon.setBackgroundColour(FRAME)
  mon.clear()
  -- Title bar.
  fill(1, 1, w, 1, DARK)
  centred(1, 1, w, "ENTER CODE", GREEN, DARK)
  -- The field: dots for what's entered, a blinking cursor, or a status.
  local fy = 3
  local status_bg = colour and padColour(colours[colour], DARK) or DARK
  fill(2, fy - 1, w - 1, fy + 1, status_bg)
  if status then
    -- Too long for the field ("ACCESS GRANTED" on a one-block monitor): its last word.
    local shown = #status <= w - 2 and status or status:match("(%S+)$")
    centred(fy, 2, w - 1, shown, colour and padColour(colours.black, colours.white) or GREEN, status_bg)
  else
    local shown = ("\7 "):rep(#code) .. (pad.blink and "_" or " ")
    centred(fy, 2, w - 1, shown, GREEN, DARK)
  end
  -- Keys, a block apart on the frame.
  pad.at = {}
  local top = fy + 3
  local rows = #KEYS
  local rowH = math.max(1, math.floor((h - top + 1) / rows))
  -- Centred in what's left below the field.
  top = top + math.floor((h - top + 1 - rows * rowH) / 2)
  for r, row in ipairs(KEYS) do
    -- Keys an odd width (labels sit dead centre), a column apart, the row
    -- centred on the monitor.
    local n = #row
    local kw = math.floor((w - (n - 1)) / n)
    if kw % 2 == 0 and kw > 3 then kw = kw - 1 end
    local left = 1 + math.floor((w - (n * kw + n - 1)) / 2)
    for c, key in ipairs(row) do
      local x0, y0 = left + (c - 1) * (kw + 1), top + (r - 1) * rowH
      local x1, y1 = x0 + kw - 1, y0 + math.max(0, rowH - 2)
      local bg, fg = padColour(colours.black, colours.white), GREEN
      if key == "OK" then bg, fg = padColour(colours.green, colours.white), padColour(colours.black, colours.black) end
      if key == "CLR" then bg, fg = padColour(colours.red, colours.white), padColour(colours.white, colours.black) end
      if pad.lit == key then bg, fg = GREEN, padColour(colours.black, colours.black) end
      fill(x0, y0, x1, y1, bg)
      centred(y0 + math.floor((y1 - y0) / 2), x0, x1, key:upper(), fg, bg)
      pad.at[#pad.at + 1] = { x0 = x0, x1 = x1, y0 = y0, y1 = y1, key = key }
    end
  end
  mon.setBackgroundColour(colours.black)
end

-- A tapped key lights up for a moment.
function pad.flash(key, code)
  pad.lit = key
  pad.draw(code)
  sleep(0.1)
  pad.lit = nil
end

function pad.key(x, y)
  for _, k in ipairs(pad.at or {}) do
    if x >= k.x0 and x <= k.x1 and y >= k.y0 and y <= k.y1 then return k.key end
  end
end

-- Off-screen drawing: a stand-in monitor the size of the real one that
-- keeps every cell, so two screens can be slid past each other.
local function canvas(w, h)
  local c = { w = w, h = h, cx = 1, cy = 1, fg = colours.white, bg = colours.black, rows = {} }
  function c.clear()
    for y = 1, h do
      c.rows[y] = {}
      for x = 1, w do c.rows[y][x] = { " ", c.fg, c.bg } end
    end
  end
  c.setTextScale = function() end
  c.getSize = function() return w, h end
  c.isColour = function() return true end
  c.setCursorPos = function(x, y) c.cx, c.cy = x, y end
  c.setBackgroundColour = function(b) c.bg = b end
  c.setTextColour = function(f) c.fg = f end
  c.write = function(t)
    t = tostring(t)
    for i = 1, #t do
      local row = c.rows[c.cy]
      if row and row[c.cx] then row[c.cx] = { t:sub(i, i), c.fg, c.bg } end
      c.cx = c.cx + 1
    end
  end
  c.clear()
  return c
end
local function offscreen(draw)
  local w, h = fit()
  local real, c = mon, canvas(w, h)
  mon = c
  local ok, err = pcall(draw)
  mon = real
  if not ok then error(err, 0) end
  return c
end
local function blitColour(c)
  if colours.toBlit then return colours.toBlit(c) end
  local i = 0
  while c > 1 do c = c / 2 i = i + 1 end
  return ("0123456789abcdef"):sub(i + 1, i + 1)
end
-- Puts rows of cells on the monitor: by blit where it can, else in runs.
local function present(rows)
  for y, row in ipairs(rows) do
    if mon.blit then
      local t, f, b = {}, {}, {}
      for x, cell in ipairs(row) do t[x], f[x], b[x] = cell[1], blitColour(cell[2]), blitColour(cell[3]) end
      mon.setCursorPos(1, y)
      mon.blit(table.concat(t), table.concat(f), table.concat(b))
    else
      local x = 1
      while x <= #row do
        local first, run, x1 = row[x], {}, x
        while row[x1] and row[x1][2] == first[2] and row[x1][3] == first[3] do
          run[#run + 1] = row[x1][1]
          x1 = x1 + 1
        end
        text(x, y, table.concat(run), first[2], first[3])
        x = x1
      end
    end
  end
end

-- The screensaver: a ringed planet. The ring is a few dozen particles in
-- orbit, pulled by the planet's gravity (stepped a little at a time, so the
-- inner ones run faster, as Kepler says), seen tilted: the near side passes
-- in front of the planet, the far side behind it. Greys, a few faint stars.
-- A tap and planet and ring fly apart into the keypad's parts (title, field,
-- keys, labels); dozing off, the keypad falls back into a planet.
local SAVER_TICK = 0.15 -- seconds between frames
local LATE = 0.45       -- how much later the last part sets off than the first
local ASPECT = 1.5      -- a character is half again as tall as it's wide
local TILT = 0.35       -- how far the ring's plane is tipped towards us
local GM = 50           -- the planet's pull
local sky = {}

local function skySeed(w, h)
  sky = { w = w, h = h, ring = {}, stars = {} }
  local R = math.min(w / 2, h * ASPECT / 2)
  sky.planet = R * 0.4
  for i = 1, 40 do
    local r = R * (0.58 + 0.4 * math.random())
    local a = math.random() * 2 * math.pi
    local v = math.sqrt(GM / r) * (1 + (math.random() - 0.5) * 0.04)
    sky.ring[i] = { x = r * math.cos(a), z = r * math.sin(a), vx = -v * math.sin(a), vz = v * math.cos(a) }
  end
  for i = 1, 4 do sky.stars[i] = { math.random(1, w), math.random(1, h) } end
end

local function skyStep(w, h, dt)
  if sky.w ~= w or sky.h ~= h then skySeed(w, h) end
  for _ = 1, 4 do
    local d = dt / 4
    for _, m in ipairs(sky.ring) do
      local r = math.sqrt(m.x * m.x + m.z * m.z)
      local k = -GM / (r * r * r)
      m.vx, m.vz = m.vx + k * m.x * d, m.vz + k * m.z * d
      m.x, m.z = m.x + m.vx * d, m.z + m.vz * d
    end
  end
end

local function skyCanvas(w, h)
  local c = canvas(w, h)
  local LIT, DIM = padColour(colours.lightGrey, colours.white), padColour(colours.grey, colours.white)
  local cx, cy, P = w / 2, h * ASPECT / 2, sky.planet
  for _, st in ipairs(sky.stars) do c.rows[st[2]][st[1]] = { ".", DIM, colours.black } end
  -- The planet, lit from the left, with a band across it.
  local function onPlanet(col, row)
    local dx, dy = col - 0.5 - cx, (row - 0.5) * ASPECT - cy
    return dx * dx + dy * dy <= P * P, dx, dy
  end
  for row = 1, h do
    for col = 1, w do
      local on, dx, dy = onPlanet(col, row)
      if on then
        local shade = (dx > P * 0.45 or math.abs(dy) < 0.4) and DIM or LIT
        c.rows[row][col] = { " ", colours.white, shade }
      end
    end
  end
  -- The ring: the far side hidden behind the planet, the near side over it.
  for _, m in ipairs(sky.ring) do
    local col = math.floor(cx + m.x) + 1
    local row = math.floor((cy + m.z * TILT) / ASPECT) + 1
    if c.rows[row] and c.rows[row][col] then
      local front = m.z >= 0
      if onPlanet(col, row) then
        if front then c.rows[row][col] = { "\7", DIM, c.rows[row][col][3] } end
      else
        c.rows[row][col] = { front and "\7" or ".", front and LIT or DIM, colours.black }
      end
    end
  end
  return c
end

function pad.saver()
  if not mon then return end
  local w, h = fit()
  skyStep(w, h, SAVER_TICK)
  present(skyCanvas(w, h).rows)
end

-- The keypad's parts for this code: each cell that isn't bare frame, each
-- setting off from a bit of the planet or its ring at its own moment.
local function parts(code)
  local c = offscreen(function() pad.draw(code) end)
  local frame = padColour(colours.grey, colours.black)
  local list = {}
  for y = 1, c.h do
    for x = 1, c.w do
      local cell = c.rows[y][x]
      if cell[1] ~= " " or cell[3] ~= frame then list[#list + 1] = { x = x, y = y, cell = cell } end
    end
  end
  local live = {}
  if sky.w ~= c.w or sky.h ~= c.h then skySeed(c.w, c.h) end
  local now = skyCanvas(c.w, c.h)
  for y = 1, c.h do
    for x = 1, c.w do
      local cell = now.rows[y][x]
      if cell[1] ~= " " or cell[3] ~= colours.black then live[#live + 1] = { x, y } end
    end
  end
  if #live == 0 then live[1] = { math.floor((c.w + 1) / 2), math.floor((c.h + 1) / 2) } end
  local n = #list
  for i, m in ipairs(list) do
    local from = live[(i * 7) % #live + 1]
    m.sx, m.sy = from[1], from[2]
    m.late = LATE * ((i * 11) % n) / n
  end
  return list, c.w, c.h
end

-- One frame: e = 0 every part on the planet or ring, 1 every part home.
local function drawParts(list, w, h, e)
  local c = canvas(w, h)
  local LIT = padColour(colours.lightGrey, colours.white)
  local flying = {}
  for _, m in ipairs(list) do
    local k = math.max(0, math.min(1, (e - m.late) / (1 - LATE)))
    if k >= 1 then c.rows[m.y][m.x] = m.cell else flying[#flying + 1] = { m, k * k * (3 - 2 * k) } end
  end
  for _, f in ipairs(flying) do
    local m, k = f[1], f[2]
    local x = math.floor(m.sx + (m.x - m.sx) * k + 0.5)
    local y = math.floor(m.sy + (m.y - m.sy) * k + 0.5)
    if c.rows[y] and c.rows[y][x] then c.rows[y][x] = { " ", colours.white, LIT } end
  end
  present(c.rows)
end

-- The keypad assembling out of the planet (apart: falling back into one).
function pad.assemble(code, apart)
  if not mon then return end
  if apart then skySeed(fit()) end
  local list, w, h = parts(code)
  local N = 14
  for f = 1, N do
    drawParts(list, w, h, apart and 1 - f / N or f / N)
    if f % 2 == 0 then beep("hat", apart and 20 - f or 6 + f, 0.25) end
    sleep(0.05)
  end
  if apart then present(skyCanvas(w, h).rows) end
end

-- Reads a line from the keyboard and, for the passphrase, the keypad too:
-- whichever finishes it.
local SLEEP_AFTER = 20 -- seconds of nothing before the keypad dozes off
local function prompt(label, mask)
  write(label)
  -- A monitor put up while it runs is found at the next prompt.
  if mask and not mon and peripheral and peripheral.find then mon = peripheral.find("monitor") end
  if not (mask and mon) then return read(mask and "*" or nil) or "" end
  local code = ""
  local x, y = term.getCursorPos()
  local function show()
    term.setCursorPos(x, y)
    term.clearLine()
    term.setCursorPos(1, y)
    write(label .. ("*"):rep(#code))
    pad.draw(code)
  end
  -- Asleep (the planet) until someone taps or types; back to sleep after a
  -- while with nothing touched. (Anything that sleeps, like a key's flash,
  -- swallows the timer, so it's started afresh after every input.)
  local asleep, last = true, os.clock()
  local function wake()
    asleep, last = false, os.clock()
    pad.assemble(code)
    show()
  end
  pad.saver()
  local blinkTimer = os.startTimer and os.startTimer(SAVER_TICK)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "char" or ev == "key" or ev == "monitor_touch" then
      last = os.clock()
      if asleep and ev == "monitor_touch" then wake() ev = nil end
      if asleep and ev then wake() end
      blinkTimer = os.startTimer(0.5)
    end
    if ev == "char" then
      code = code .. a
      show()
    elseif ev == "key" and a == keys.backspace then
      code = code:sub(1, -2)
      show()
    elseif ev == "key" and (a == keys.enter or a == keys.numPadEnter) then
      print()
      return code
    elseif ev == "timer" and a == blinkTimer then
      if asleep then
        pad.saver()
        blinkTimer = os.startTimer(SAVER_TICK)
      else
        if os.clock() - last > SLEEP_AFTER then
          code, asleep = "", true
          term.setCursorPos(1, y)
          term.clearLine()
          write(label)
          pad.assemble("", true)
          blinkTimer = os.startTimer(SAVER_TICK)
        else
          pad.blink = not pad.blink
          pad.draw(code)
          blinkTimer = os.startTimer(0.5)
        end
      end
    elseif ev == "monitor_touch" then
      local key = pad.key(b, c)
      if key then beep("hat", 16, 0.5) pad.flash(key, code) end
      if key == "OK" then print() return code
      elseif key == "CLR" then code = ""
      elseif key then code = code .. key end
      show()
    end
  end
end

---------------------------------------------------------------------------
-- Effects
---------------------------------------------------------------------------

local function boot()
  clear()
  typeOut("SECURE-OS BIOS 4.11   (c) Claude Industries", 6)
  typeOut("Memory test ........ 640K OK")
  typeOut("Loading kernel modules .... [OK]")
  typeOut("Mounting /vault ........... [OK]")
  typeOut("Arming door actuator (" .. cfg.side .. ") ... [OK]")
  typeOut("Handshake with mainframe .. [OK]")
  sleep(0.4)
end

local function matrix(seconds)
  clear()
  local drops = {}
  for x = 1, W do drops[x] = math.random(-H, 0) end
  local glyphs = "01<>/\\|=+*#$%&@ABCDEF0123456789"
  for _ = 1, math.floor(seconds / 0.05) do
    for x = 1, W, 2 do
      local y = drops[x]
      if y >= 1 and y <= H then
        local i = math.random(#glyphs)
        at(x, y, glyphs:sub(i, i))
        if math.random(8) == 1 then beep("bit", math.random(0, 24), 0.4) end
      end
      if y - 6 >= 1 and y - 6 <= H then at(x, y - 6, " ") end
      drops[x] = y > H + 6 and math.random(-H, 0) or y + 1
    end
    sleep(0.05)
  end
end

-- Doorman's modes, set from the menu after the passphrase: sent to Doorman
-- through the bridge.
local MODES = {
  { "home", "Home" }, { "normal", "Normal" }, { "greeter", "Greeter" }, { "members", "Members" }, { "guard", "Guard" },
  { "sweep", "Sweep path" },
}
local IDLE = 30 -- seconds without a touch before the menu locks up again
local function tell(event, data)
  os.queueEvent("bridge_send", { action = "relay", to = "Doorman", event = event, data = data or {} })
end
-- Notes get lost while Doorman moves or scans: send until it answers (a
-- doorman_ack), for up to half a minute. True if it did.
local function tellHeard(event, data)
  for _ = 1, 20 do
    tell(event, data)
    local timer = os.startTimer(1.5)
    while true do
      local ev, a, b = os.pullEvent()
      if ev == "bridge_push" and a == "doorman_ack" then return true, b end
      if ev == "timer" and a == timer then break end
    end
  end
  return false
end

-- The menu on the monitor: a row for each mode (the chosen one lit), then
-- Register (the player at the vault door becomes a registered person) and
-- Save & exit. Returns where each button is.
local function drawMenu(chosen, note)
  local w, h = mon.getSize()
  local GREEN = padColour(colours.lime, colours.white)
  local DARK = padColour(colours.black, colours.black)
  mon.setBackgroundColour(padColour(colours.grey, colours.black))
  mon.clear()
  fill(1, 1, w, 1, DARK)
  centred(1, 1, w, note or "DOORMAN", GREEN, DARK)
  local buttons = {}
  -- A blank row before the buttons if there's room for it.
  local gap = h - 1 >= #MODES + 4 and 1 or 0
  local rows = #MODES + 2 + 2 * gap
  local top = 2 + math.max(0, math.floor((h - 1 - rows) / 2))
  for i, m in ipairs(MODES) do
    local y = top + i - 1
    local on = m[1] == chosen
    local bg = on and GREEN or DARK
    fill(2, y, w - 1, y, bg)
    text(3, y, (i .. " " .. m[2]):sub(1, w - 3), on and DARK or GREEN, bg)
    buttons[#buttons + 1] = { y = y, mode = m[1] }
  end
  local ry = top + #MODES + gap
  local sy = ry + 1 + gap
  fill(2, ry, w - 1, ry, padColour(colours.cyan, colours.white))
  centred(ry, 2, w - 1, w >= 16 and "REGISTER VISITOR" or "REGISTER", DARK, padColour(colours.cyan, colours.white))
  fill(2, sy, w - 1, sy, padColour(colours.green, colours.white))
  centred(sy, 2, w - 1, w >= 15 and "SAVE & EXIT" or "SAVE", DARK, padColour(colours.green, colours.white))
  buttons[#buttons + 1] = { y = ry, action = "register" }
  buttons[#buttons + 1] = { y = sy, action = "save" }
  return buttons
end

local function menu()
  local chosen = cfg.mode or "normal"
  local note
  local buttons = drawMenu(chosen)
  local idle = os.startTimer(IDLE)
  while true do
    local ev, a, b, c = os.pullEvent()
    local action
    if ev == "timer" and a == idle then return end
    if ev == "monitor_touch" then
      for _, btn in ipairs(buttons) do
        if c == btn.y and b >= 2 then action = btn.mode or btn.action end
      end
    elseif ev == "char" and tonumber(a) and MODES[tonumber(a)] then
      action = MODES[tonumber(a)][1]
    elseif ev == "key" and (a == keys.enter or a == keys.numPadEnter) then
      action = "save"
    end
    if action then
      beep("hat", 16, 0.5)
      idle = os.startTimer(IDLE)
      if action == "save" then
        cfg.mode = chosen
        save()
        drawMenu(chosen, "SENDING")
        local heard = tellHeard("doorman_mode", { mode = chosen })
        drawMenu(chosen, heard and "DOORMAN OK" or "NO ANSWER")
        if heard then tune(SOUNDS.hello) else denied(1) end
        sleep(1)
        return
      elseif action == "register" then
        drawMenu(chosen, "SENDING")
        local heard, reply = tellHeard("doorman_register")
        note = not heard and "NO ANSWER" or (reply and reply.registered) and "REGISTERED" or "NOBODY THERE"
      else
        chosen = action
        note = nil
      end
      buttons = drawMenu(chosen, note)
    end
  end
end

local function openDoor()
  header()
  box(10, "ACCESS  GRANTED")
  if mon then
    for _ = 1, 2 do pad.draw("", "ACCESS GRANTED", "lime") sleep(0.15) pad.draw("", "ACCESS GRANTED", "green") sleep(0.15) end
  end
  tune(SOUNDS.granted)
  report("Vault door opened")
  redstone.setOutput(cfg.side, true)
  if mon then
    -- The door stays open while the menu is up: Save & exit, or a while
    -- without a touch, shuts it.
    center(14, "Doorman's settings are on the monitor")
    menu()
  else
    local width = 30
    for left = cfg.hold, 1, -1 do
      local done = math.floor(width * (cfg.hold - left) / cfg.hold)
      center(14, "[" .. ("#"):rep(done) .. ("."):rep(width - done) .. "]")
      center(15, ("Door closes in %ds "):format(left))
      beep("hat", 12, 0.6)
      sleep(1)
    end
  end
  redstone.setOutput(cfg.side, false)
  tune(SOUNDS.closing, 0.2)
  center(15, "   DOOR SECURED    ")
  sleep(1)
end

local function intrusion()
  header()
  box(10, "INTRUSION  DETECTED")
  report(("Vault terminal: %d wrong passphrases, locked for %ds"):format(MAX_TRIES, LOCKOUT))
  term.setCursorPos(1, 14)
  for _ = 1, 3 do
    typeOut(("Tracing %d.%d.%d.%d ... "):format(math.random(10, 250), math.random(0, 255),
      math.random(0, 255), math.random(0, 255)) .. "ROUTED", 8)
  end
  for left = LOCKOUT, 1, -1 do
    center(H, ("TERMINAL LOCKED  %02ds"):format(left))
    pad.draw("", ("LOCKED %02d"):format(left), "red")
    -- An alarm, the whole lockout.
    beep("bell", left % 2 == 0 and 18 or 12, 2)
    sleep(1)
  end
end

---------------------------------------------------------------------------
-- hack: guess the password from a memory dump (it never opens the door)
---------------------------------------------------------------------------

local WORDS = {
  "PASSWD", "KERNEL", "BINARY", "CIPHER", "DAEMON", "ROUTER", "SOCKET", "BUFFER",
  "HACKER", "PACKET", "SERVER", "MEMORY", "CURSOR", "TOKENS", "SHELLS", "VECTOR",
  "MATRIX", "PORTAL", "ENIGMA", "GLITCH", "TURTLE", "COBBLE",
}
local JUNK = "!@#$%^&*()_+-=[]{};:'\",.<>/?|\\~"

local function likeness(a, b)
  local n = 0
  for i = 1, #a do if a:sub(i, i) == b:sub(i, i) then n = n + 1 end end
  return n
end

local function hack()
  local pool = {}
  for _, w in ipairs(WORDS) do pool[#pool + 1] = w end
  local words = {}
  for i = 1, 8 do words[i] = table.remove(pool, math.random(#pool)) end
  local answer = words[math.random(#words)]

  -- 24 dump lines in two columns; 8 of them hide a word.
  local hide = {}
  local cells = {}
  for i = 1, 24 do cells[i] = i end
  for i = 1, 8 do hide[table.remove(cells, math.random(#cells))] = words[i] end

  clear()
  at(1, 1, "ROBCO-ISH TERMLINK PROTOCOL")
  at(1, 2, "ENTER PASSWORD NOW")
  local addr = math.random(0x1000, 0xE000)
  for i = 1, 24 do
    local line = {}
    for j = 1, 16 do
      local k = math.random(#JUNK)
      line[j] = JUNK:sub(k, k)
    end
    line = table.concat(line)
    if hide[i] then
      local p = math.random(1, 16 - 6 + 1)
      line = line:sub(1, p - 1) .. hide[i] .. line:sub(p + 6)
    end
    local col, row = i <= 12 and 1 or 26, ((i - 1) % 12) + 4
    at(col, row, ("0x%04X %s"):format(addr + (i - 1) * 16, line))
    beep("hat", math.random(8, 20), 0.5)
  end

  for tries = 4, 1, -1 do
    at(1, 17, "ATTEMPTS LEFT: " .. ("# "):rep(tries) .. ("  "):rep(4 - tries))
    term.setCursorPos(1, 18)
    term.clearLine()
    local guess = prompt("> ", false):upper()
    term.setCursorPos(1, 19)
    term.clearLine()
    if guess == answer then
      tune({ { "pling", 12 }, { "pling", 17 }, { "pling", 21 } })
      write("> ROOT ACCESS GRANTED... just kidding. Nice hack!")
      sleep(3)
      return
    end
    write(("> %s: entry denied, likeness=%d"):format(guess, likeness(guess, answer)))
    beep("bass", 6)
  end
  at(1, 17, "TERMINAL LOCKED. PLEASE CONTACT AN ADMINISTRATOR")
  sleep(4)
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local function choosePassphrase()
  while true do
    header()
    print("No passphrase set. Choose one for the door.")
    print()
    local a = prompt("New passphrase:  ", true)
    local b = prompt("Repeat it:       ", true)
    if #a < 3 then
      print("Too short (3 characters at least).")
    elseif a ~= b then
      print("They don't match.")
    else
      cfg.pass = a
      save()
      print("Saved.")
      sleep(1)
      return
    end
    sleep(2)
  end
end

local HELP = {
  "help     this list",
  "hack     try your luck on the mainframe",
  "matrix   follow the white rabbit",
  "whoami   who you are",
  "passwd   change the passphrase",
  "exit     leave the terminal (needs it)",
}

local normalPull = os.pullEvent
os.pullEvent = os.pullEventRaw -- Ctrl+T must not drop to the shell

local ok, err = pcall(function()
  boot()
  if not cfg.pass then choosePassphrase() end
  local wrong = 0
  local note
  while true do
    header()
    if note then print(note) print() end
    note = nil
    local input = prompt("PASSPHRASE: ", true)
    local word = input:lower()
    if input == cfg.pass then
      wrong = 0
      openDoor()
    elseif word == "help" then
      tune(SOUNDS.hello)
      note = table.concat(HELP, "\n")
    elseif word == "hack" then
      hack()
    elseif word == "matrix" then
      matrix(6)
    elseif word == "whoami" then
      tune(SOUNDS.hello)
      note = "guest  (clearance: none, snacks: unauthorised)"
    elseif word == "passwd" then
      if prompt("Current passphrase: ", true) == cfg.pass then
        cfg.pass = nil
        choosePassphrase()
        note = "Passphrase changed."
      else
        note = "Nope."
      end
    elseif word == "exit" then
      if prompt("Passphrase to exit: ", true) == cfg.pass then tune(SOUNDS.bye) return end
      note = "Nope."
    elseif input ~= "" then
      wrong = wrong + 1
      header()
      box(10, "ACCESS  DENIED")
      center(14, ("Attempt %d of %d"):format(wrong, MAX_TRIES))
      if mon then
        for _ = 1, 3 do pad.draw("", "DENIED", "red") sleep(0.15) pad.draw("", "DENIED", "black") sleep(0.1) end
        pad.draw("", "DENIED", "red")
      end
      denied(wrong)
      sleep(2)
      if wrong >= MAX_TRIES then
        wrong = 0
        intrusion()
      end
    end
  end
end)

os.pullEvent = normalPull
redstone.setOutput(cfg.side, false)
clear()
if not ok then error(err, 0) end
