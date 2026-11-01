-- Prints what Keeper's touch keypad looks like on a monitor of a given size,
-- as text and as a map of background colours. Not a test: a look.
-- Usage: node tests/run.js tests/keypad_preview.lua [width height] [code]
local W, H = tonumber(arg[1]) or 18, tonumber(arg[2]) or 12
local CODE = arg[3] or "12a"

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
  sleep = function() end,
  colours = colours, keys = { backspace = 14, enter = 28 },
  redstone = { setOutput = function() end },
  peripheral = { find = function(t) if t == "monitor" then return mon end end },
  fs = { open = function(p, m) if m == "r" then return { readAll = function() return '{pass="x",side="right",hold=5}' end, close = function() end } end end },
  textutils = { unserialise = function(s) return load("return " .. s)() end, serialise = function() return "" end },
  os = setmetatable({
    startTimer = function() return 1 end,
    pullEvent = function()
      typed = typed + 1
      if typed <= #CODE then return "char", CODE:sub(typed, typed) end
      error("STOP", 0)
    end,
    queueEvent = function() end,
  }, { __index = os }),
}, { __index = _G })
env.os.pullEventRaw = env.os.pullEvent
pcall(assert(loadfile("programs/door.lua", "t", env)))
print(("%dx%d, code %q:"):format(W, H, CODE))
for y = 1, H do print("  " .. table.concat(grid[y]) .. "   " .. table.concat(bgs[y])) end
