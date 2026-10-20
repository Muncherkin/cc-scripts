-- Runs programs/printlist.lua against a fake printer and speaker and checks
-- the printed pages. Run with: npx fengari tests/printlist_test.lua [--show] [name]

local show = arg and arg[1] == "--show"
local listName = arg and arg[2] or "monitors"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function newPrinter(paper, ink)
  local p = { pages = {}, paper = paper, ink = ink }
  local page, x, y
  local api = {}
  api.getPaperLevel = function() return p.paper end
  api.getInkLevel = function() return p.ink end
  api.newPage = function()
    if p.paper == 0 or p.ink == 0 then return false end
    page = { title = "", lines = {} }
    for i = 1, 21 do page.lines[i] = (" "):rep(25) end
    x, y = 1, 1
    return true
  end
  api.setPageTitle = function(t) page.title = t end
  api.setCursorPos = function(nx, ny) x, y = nx, ny end
  api.write = function(text)
    assert(page, "Page not started")
    text = tostring(text)
    local l = page.lines[y]
    if l then page.lines[y] = (l:sub(1, x - 1) .. text .. l:sub(x + #text)):sub(1, 25) end
    p.overflow = p.overflow or (x + #text - 1 > 25)
    x = x + #text
  end
  api.endPage = function()
    p.pages[#p.pages + 1] = page
    p.paper = p.paper - 1
    page = nil
    return true
  end
  p.api = api
  return p
end

local function readFile(path)
  return readfile("programs/" .. path) -- provided by tests/run.js
end

local function run(printer, notes, ...)
  local env
  env = setmetatable({
    peripheral = {
      find = function(t)
        if t == "printer" then return printer.api end
        if t == "speaker" then return { playNote = function(i, v, p) notes[#notes + 1] = i .. p end } end
      end,
    },
    fs = { exists = function(p) return readFile(p:gsub("^/", "")) ~= nil end,
      open = function(p) local s = readFile(p:gsub("^/", "")) return s and { readAll = function() return s end, close = function() end } end },
    sleep = function() end,
    print = function() end,
  }, { __index = _G })
  env.require = function(m)
    local f = assert(loadfile("programs/" .. m:gsub("%.", "/") .. ".lua", "t", env))
    return f()
  end
  local f = assert(loadfile("programs/printlist.lua", "t", env))
  return pcall(f, ...)
end

print("Printing '" .. listName .. "'")
local printer, notes = newPrinter(12, 1), {}
local ok, res = run(printer, notes, listName)
check(ok, "prints without errors (" .. tostring(res) .. ")")
check(#printer.pages >= 1, #printer.pages .. " page(s) printed")
check(not printer.overflow, "nothing written past the 25-column page edge")
check(#notes >= 3, "chimes after printing")
if show then
  for n, page in ipairs(printer.pages) do
    print(("\n  +%s+  %s"):format(("-"):rep(25), page.title))
    for _, l in ipairs(page.lines) do print("  |" .. l .. "|") end
    print("  +" .. ("-"):rep(25) .. "+")
  end
end

print("Refuses to print without ink")
printer, notes = newPrinter(12, 0), {}
ok, res = run(printer, notes, listName)
check(not ok and tostring(res):find("ink") and #printer.pages == 0, "clear 'no ink' error, no pages wasted")
check(#notes == 0, "no chime when nothing was printed")

print(failures == 0 and "\nAll tests passed" or ("\n" .. failures .. " check(s) failed"))
if failures > 0 then os.exit(1) end
