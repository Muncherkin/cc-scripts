-- Runs programs/claudeos.lua on a fake 26x20 advanced pocket computer with
-- the real docs, clicks through it and checks the screens.
-- Run with: node tests/run.js tests/claudeos_test.lua [--show]

local show = arg and arg[1] == "--show"
local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local W, H = 26, 20
local DOC_FILES = { "Welcome.txt", "plans/tree-station.txt", "plans/dashboard-upgrade.txt", "guides/miner.txt" }

local function newFs()
  local files, dirs, mtime = {}, { [""] = true }, {}
  local function norm(p) return (p:gsub("^/+", ""):gsub("/+$", "")) end
  local function mkdirs(p)
    local acc = ""
    for part in p:gmatch("[^/]+") do
      acc = acc == "" and part or acc .. "/" .. part
      dirs[acc] = true
    end
  end
  local api = {}
  function api.combine(a, b) return norm((a or "") .. "/" .. (b or "")) end
  function api.getName(p) return norm(p):match("[^/]+$") or "" end
  function api.isDir(p) return dirs[norm(p)] == true end
  function api.exists(p) return files[norm(p)] ~= nil or dirs[norm(p)] == true end
  function api.makeDir(p) mkdirs(norm(p)) end
  function api.attributes(p) return { modified = mtime[norm(p)] or 0, size = #(files[norm(p)] or "") } end
  function api.list(p)
    local out, prefix = {}, norm(p) == "" and "" or norm(p) .. "/"
    local seenNames = {}
    for _, tbl in ipairs({ files, dirs }) do
      for k in pairs(tbl) do
        if k ~= "" and k:sub(1, #prefix) == prefix then
          local rest = k:sub(#prefix + 1)
          if rest ~= "" and not rest:find("/") and not seenNames[rest] then seenNames[rest] = true out[#out + 1] = rest end
        end
      end
    end
    table.sort(out)
    return out
  end
  function api.open(p, mode)
    p = norm(p)
    if mode == "r" then
      local s = files[p]
      if not s then return nil end
      local pos = 1
      return {
        readAll = function() return s end,
        read = function(n) local r = s:sub(pos, pos + n - 1) pos = pos + n return r end,
        close = function() end,
      }
    end
    local b = ""
    return { write = function(s) b = b .. s end, close = function() files[p] = b mkdirs(p:match("(.*)/") or "") end }
  end
  local function add(p, content, t) p = norm(p) files[p] = content mtime[p] = t mkdirs(p:match("(.*)/") or "") end
  return api, add, files
end

local function serialise(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = "[" .. (type(k) == "string" and ("%q"):format(k) or tostring(k)) .. "]=" .. serialise(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return type(v) == "string" and ("%q"):format(v) or tostring(v)
end

local KEYS = { left = 203, right = 205, up = 200, down = 208, enter = 28, space = 57, backspace = 14, pageUp = 201, pageDown = 209, p = 25 }

local function run(events)
  local screen = {}
  for y = 1, H do screen[y] = (" "):rep(W) end
  local cy = 1
  local fsApi, addFile, files = newFs()
  for i, f in ipairs(DOC_FILES) do addFile("docs/" .. f, assert(readfile("docs/" .. f), f), 1000 + i) end
  local sent, queue, timers = {}, {}, 0
  for i, e in ipairs(events) do queue[i] = e end
  local env
  env = setmetatable({
    term = {
      getSize = function() return W, H end,
      isColour = function() return true end,
      setCursorPos = function(_, y) cy = y end,
      blit = function(t, f, b)
        assert(#t == W and #f == W and #b == W, "blit width " .. #t .. " on row " .. cy)
        screen[cy] = t
      end,
      setBackgroundColor = function() end, setTextColor = function() end, clear = function() end,
    },
    fs = fsApi,
    textutils = {
      serialise = serialise,
      unserialise = function(s) local f = load("return " .. s) return f and f() end,
      formatTime = function() return "9:05" end,
    },
    os = {
      time = function() return 9.08 end, day = function() return 42 end, clock = function() return 50 end,
      getComputerID = function() return 5 end,
      startTimer = function() timers = timers + 1 return timers end,
      queueEvent = function(name, d) if name == "bridge_send" then sent[#sent + 1] = d end end,
      pullEvent = function()
        local e = table.remove(queue, 1)
        if not e then error("END_OF_EVENTS", 0) end
        return table.unpack(e)
      end,
    },
    keys = KEYS,
    colors = { black = 32768, white = 1 },
    peripheral = { find = function() return nil end },
    pocket = {},
    sleep = function() end,
    print = function() end, printError = function(e) error(e, 0) end,
  }, { __index = _G })
  env.require = function(m)
    local f = assert(loadfile("programs/" .. m:gsub("%.", "/") .. ".lua", "t", env))
    return f()
  end
  local f = assert(loadfile("programs/claudeos.lua", "t", env))
  local ok, err = pcall(f)
  return screen, sent, files, ok, err
end

local function text(screen) return table.concat(screen, "\n") end
local function dump(title, screen)
  if not show then return end
  print("\n  " .. title)
  print("  +" .. ("-"):rep(W) .. "+")
  for _, l in ipairs(screen) do print("  |" .. l .. "|") end
  print("  +" .. ("-"):rep(W) .. "+")
end

local snapshot = {
  time = "22:10",
  computers = {
    { id = 1, label = "turtle-1", kind = "turtle", online = true, fuel = 198, lastSeen = "22:09", jobs = {} },
    { id = 2, label = "turtle-2", kind = "turtle", online = true, fuel = 76, lastSeen = "22:09",
      jobs = { { program = "farm", tail = { "Pass: growing=4, bread=0" } } } },
  },
  messages = { { time = "22:05", text = "Hello from Claude! Your pocket is linked." } },
  events = {},
}
local push = { "bridge_push", "status", snapshot }
local skipBoot = { "key", KEYS.enter }

print("Home screen")
local screen, sent = run({ skipBoot, push })
-- the program ends with END_OF_EVENTS, which run() reports as a failure; that's expected
check(sent[1] and sent[1].action == "subscribe", "subscribes to the bridge")
check(text(screen):find("FILES") and text(screen):find("MESSAGES") and text(screen):find("FLEET"), "shows the app tiles")
check(text(screen):find("4 new") ~= nil, "FILES tile shows 4 new docs")
check(text(screen):find("Day 42") ~= nil, "shows the game day")
dump("home", screen)

print("Files")
screen = run({ skipBoot, push, { "mouse_click", 1, 4, 11 } })
check(text(screen):find("Welcome to Claude") ~= nil, "lists docs by title")
check(text(screen):find("guides/") and text(screen):find("plans/"), "shows folders")
check(text(screen):find("NEW") ~= nil, "marks new docs")
dump("files", screen)

print("Reader")
-- folders sort first: guides/, plans/, then Welcome (row 5)
screen = run({ skipBoot, push, { "mouse_click", 1, 4, 11 }, { "mouse_click", 1, 6, 5 } })
check(text(screen):find("USING IT") ~= nil, "renders section headings")
check(text(screen):find("o_o") ~= nil, "renders ASCII art")
check(text(screen):find(" 0/3") ~= nil, "shows checklist progress")
check(text(screen):find("PRINT") ~= nil, "has a PRINT button")
dump("reader", screen)

print("Ticking and printing")
local files
screen, sent, files = run({ skipBoot, push, { "mouse_click", 1, 4, 11 }, { "mouse_click", 1, 6, 5 },
  { "key", KEYS.pageDown }, { "key", KEYS.pageDown } })
local rows = text(screen)
-- find the row of "Open Files" and tap it
local tapRow
for y, l in ipairs(screen) do if l:find("Open Files") then tapRow = y end end
screen, sent, files = run({ skipBoot, push, { "mouse_click", 1, 4, 11 }, { "mouse_click", 1, 6, 5 },
  { "key", KEYS.pageDown }, { "key", KEYS.pageDown }, { "mouse_click", 1, 5, tapRow or 1 }, { "key", KEYS.p } })
check(text(screen):find("%[x%] Open Files") ~= nil, "tapping an item ticks it")
check(text(screen):find(" 1/3") ~= nil, "progress updates")
check(files[".os/checks"] and files[".os/checks"]:find("Open Files"), "ticks are saved")
local printed
for _, s in ipairs(sent) do if s.action == "print" then printed = s.path end end
check(printed == "Welcome.txt", "P asks the bridge to print the doc (" .. tostring(printed) .. ")")
dump("ticked", screen)
local _ = rows

print("Notifications")
screen = run({ skipBoot, push, { "bridge_push", "docs", { files = { "a.txt", "b.txt" } } } })
check(text(screen):find("Claude sent 2 docs") ~= nil, "shows a toast when docs arrive")

print(failures == 0 and "\nAll tests passed" or ("\n" .. failures .. " check(s) failed"))
if failures > 0 then os.exit(1) end
