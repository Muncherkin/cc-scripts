-- Prints what Keeper's touch keypad looks like on a monitor of a given size,
-- as text and as a map of background colours. Not a test: a look.
-- Usage: node tests/run.js tests/keypad_preview.lua [width height] [code] [menu|saver t|slide frame]
--        (with menu, the code is the passphrase: it shows the mode menu after;
--        with saver, the screensaver at in-game time t)
local W, H = tonumber(arg[1]) or 18, tonumber(arg[2]) or 12
local CODE = arg[3] or "12a"
local MENU = arg[4] == "menu"
local SAVER = arg[4] == "saver" and (tonumber(arg[5]) or 2)
local SLIDE = arg[4] == "slide" and (tonumber(arg[5]) or 4) -- the frame of the wake slide to show
if SLIDE then SAVER, CODE = 12.5, "" end
local slept, touched = 0, false
if SAVER then CODE = "" end
local clock = 0

local grid, bgs = {}, {}
for y = 1, H do grid[y], bgs[y] = {}, {} for x = 1, W do grid[y][x], bgs[y][x] = " ", "." end end
local LETTER = { black = ".", grey = "g", gray = "g", lightGrey = "l", lime = "L", green = "G", red = "R", white = "w" }
local cx, cy, bg = 1, 1, "."
local colours = setmetatable({}, { __index = function(_, k) return k end })
local mon = {
  setTextScale = function() end, setTextColour = function() end,
  setBackgroundColour = function(c) bg = LETTER[c] or "?" end,
  clear = function() for y = 1, H do for x = 1, W do grid[y][x], bgs[y][x] = " ", bg end end end,
  setCursorPos = function(x, y) cx, cy = x, y end,
  getSize = function() return W, H end,
  isColour = function() return true end,
  write = function(t)
    for i = 1, #t do
      if grid[cy] and cx >= 1 and cx <= W then grid[cy][cx], bgs[cy][cx] = t:sub(i, i), bg end
      cx = cx + 1
    end
  end,
}
local typed = 0
local env = setmetatable({
  term = { getSize = function() return 51, 19 end, clear = function() end, clearLine = function() end,
    setCursorPos = function() end, getCursorPos = function() return 1, 10 end, write = function() end },
  write = function() end, print = function() end,
  read = function() error("STOP", 0) end,
  sleep = function()
    slept = slept + 1
    if SLIDE and touched and slept == SLIDE then error("STOP", 0) end
  end,
  colours = colours, keys = { backspace = 14, enter = 28 },
  redstone = { setOutput = function() end },
  peripheral = { find = function(t) if t == "monitor" then return mon end end },
  fs = { open = function(p, m)
    if m == "r" then return { readAll = function() return '{pass="' .. (MENU and CODE or "x") .. '",side="right",hold=5}' end, close = function() end } end
    return { write = function() end, close = function() end }
  end },
  textutils = { unserialise = function(s) return load("return " .. s)() end, serialise = function() return "" end },
  os = setmetatable({
    startTimer = function() return 1 end,
    clock = function() return clock end,
    time = function() return SAVER or 13.5 end,
    day = function() return 42 end,
    pullEvent = function()
      if SAVER and clock == 0 then clock = SAVER return "timer", 1 end
      if SLIDE then slept = 0 touched = true return "monitor_touch", "top", 1, 1 end
      if SAVER then error("STOP", 0) end
      typed = typed + 1
      if typed <= #CODE then return "char", CODE:sub(typed, typed) end
      if MENU and typed == #CODE + 1 then return "key", 28 end
      error("STOP", 0)
    end,
    queueEvent = function() end,
  }, { __index = os }),
}, { __index = _G })
env.os.pullEventRaw = env.os.pullEvent
pcall(assert(loadfile("programs/door.lua", "t", env)))
print(("%dx%d, code %q:"):format(W, H, CODE))
for y = 1, H do print("  " .. table.concat(grid[y]) .. "   " .. table.concat(bgs[y])) end
