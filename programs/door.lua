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

-- colour is a name ("green"), so callers need no colours table without a
-- monitor. Lays the keys out over the whole monitor: a field for the code on top, a
-- grid of keys below. Remembers where each key is for touches.
function pad.draw(code, status, colour)
  if not mon then return end
  mon.setTextScale(1)
  local w, h = mon.getSize()
  if w < 15 or h < 8 then mon.setTextScale(0.5) w, h = mon.getSize() end
  mon.setBackgroundColour(colours.black)
  mon.clear()
  -- The field: stars for what's typed, or a status.
  mon.setCursorPos(1, 1)
  mon.setBackgroundColour(padColour(colours[colour or "grey"], colours.black))
  mon.setTextColour(colours.white)
  local text = status or ("*"):rep(#code)
  mon.write((" "):rep(w))
  mon.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), 1)
  mon.write(text)
  pad.at = {}
  local rows = #KEYS
  local rowH = math.max(1, math.floor((h - 1) / rows))
  for r, row in ipairs(KEYS) do
    local colW = math.floor(w / #row)
    for c, key in ipairs(row) do
      local x0, y0 = (c - 1) * colW + 1, 2 + (r - 1) * rowH
      local bg = key == "OK" and padColour(colours.green, colours.white) or key == "CLR" and padColour(colours.red, colours.white)
        or padColour(colours.lightGrey, colours.white)
      mon.setBackgroundColour(bg)
      mon.setTextColour(colours.black)
      for y = y0, y0 + rowH - 1 do
        mon.setCursorPos(x0, y)
        mon.write((" "):rep(colW - 1))
      end
      mon.setCursorPos(x0 + math.floor((colW - 1 - #key) / 2), y0 + math.floor((rowH - 1) / 2))
      mon.write(key)
      pad.at[#pad.at + 1] = { x0 = x0, x1 = x0 + colW - 2, y0 = y0, y1 = y0 + rowH - 1, key = key }
    end
  end
  mon.setBackgroundColour(colours.black)
end

function pad.key(x, y)
  for _, k in ipairs(pad.at or {}) do
    if x >= k.x0 and x <= k.x1 and y >= k.y0 and y <= k.y1 then return k.key end
  end
end

-- Reads a line from the keyboard and, for the passphrase, the keypad too:
-- whichever finishes it.
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
  show()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "char" then
      code = code .. a
      show()
    elseif ev == "key" and a == keys.backspace then
      code = code:sub(1, -2)
      show()
    elseif ev == "key" and (a == keys.enter or a == keys.numPadEnter) then
      print()
      return code
    elseif ev == "monitor_touch" then
      local key = pad.key(b, c)
      if key then beep("hat", 16, 0.5) end
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

local function openDoor()
  header()
  box(10, "ACCESS  GRANTED")
  pad.draw("", "GRANTED", "green")
  tune(SOUNDS.granted)
  report("Vault door opened")
  redstone.setOutput(cfg.side, true)
  local width = 30
  for left = cfg.hold, 1, -1 do
    local done = math.floor(width * (cfg.hold - left) / cfg.hold)
    center(14, "[" .. ("#"):rep(done) .. ("."):rep(width - done) .. "]")
    center(15, ("Door closes in %ds "):format(left))
    beep("hat", 12, 0.6)
    sleep(1)
  end
  redstone.setOutput(cfg.side, false)
  tune(SOUNDS.closing, 0.2)
  center(14, "[" .. ("#"):rep(width) .. "]")
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
      pad.draw("", "DENIED", "red")
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
