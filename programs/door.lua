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

local function prompt(label, mask)
  write(label)
  return read(mask and "*" or nil) or ""
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
