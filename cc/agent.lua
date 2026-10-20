-- cc-scripts agent: connects this computer to the dev bridge so code can be
-- pushed, run and inspected remotely. Installed by cc/install.lua.
--
-- Jobs run concurrently as coroutines next to the bridge connection, so an
-- autorun program (e.g. a farm) can run forever while still accepting evals.

local VERSION = 6
local DIR = "/.agent"
local CONFIG = DIR .. "/config"
local AUTORUN = DIR .. "/autorun"
local LOG = DIR .. "/log"

local function readTable(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local t = textutils.unserialise(h.readAll())
  h.close()
  return t
end

local function writeFile(path, content)
  local h = fs.open(path, "w")
  h.write(content)
  h.close()
end

local cfg = readTable(CONFIG)
if not cfg then error("No config at " .. CONFIG .. " - run install.lua first", 0) end

-- With multishell the agent has its own tab and can print. Without it, the
-- agent shares the screen with the shell, so its messages go to a log file.
local quiet = multishell == nil
local function say(text)
  if not quiet then print(text) return end
  local h = fs.open(LOG, fs.exists(LOG) and fs.getSize(LOG) < 16000 and "a" or "w")
  h.writeLine(("[%s] %s"):format(textutils.formatTime(os.time(), true), text))
  h.close()
end

local ws
local function send(msg)
  if ws then pcall(ws.send, textutils.serialiseJSON(msg)) end
end

local function status()
  local s = {
    id = os.getComputerID(),
    label = os.getComputerLabel(),
    version = VERSION,
    turtle = turtle ~= nil,
    pocket = pocket ~= nil,
    advanced = term.isColour(),
    autorun = readTable(AUTORUN),
    peripherals = {},
  }
  for _, side in ipairs(peripheral.getNames()) do
    s.peripherals[#s.peripherals + 1] = peripheral.getType(side)
  end
  if turtle then
    s.fuel = turtle.getFuelLevel()
    s.selected = turtle.getSelectedSlot()
  end
  return s
end

---------------------------------------------------------------------------
-- Task scheduler (like parallel, but tasks can be added while running)
---------------------------------------------------------------------------

local tasks = {}

local finish

local function resumeTask(t, ...)
  local ok, filter = coroutine.resume(t.co, ...)
  if not ok then
    -- A crashing job must never take the agent (and other jobs) down with it.
    if not t.job then error(filter, 0) end
    t.dead = true
    finish(t.job, false, "Agent error: " .. tostring(filter), t.t0 or os.epoch("utc"))
    return
  end
  t.filter = filter
end

-- t may be passed in so the task function can refer to its own task table
-- even when it finishes before spawn returns.
local function spawn(fn, job, t)
  t = t or {}
  t.co, t.job = coroutine.create(fn), job
  tasks[#tasks + 1] = t
  resumeTask(t)
  return t
end

local function hasJobs()
  for _, t in ipairs(tasks) do
    if t.job and not t.dead then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Jobs
---------------------------------------------------------------------------

-- Environment for jobs: print/write/printError are mirrored to the bridge.
local function makeEnv(jobId)
  local function out(stream, text)
    send({ type = "output", job = jobId, stream = stream, text = text })
  end
  local function join(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, "\t")
  end

  local env = setmetatable({}, { __index = _ENV })
  env.print = function(...) out("stdout", join(...) .. "\n") return print(...) end
  env.write = function(text) out("stdout", tostring(text)) return write(text) end
  env.printError = function(...) out("stderr", join(...) .. "\n") return printError(...) end
  env.require, env.package = require("cc.require").make(env, "/")
  -- Lets programs talk to the bridge directly. Messages the bridge pushes
  -- back arrive as "bridge_push" events: name, data.
  env.bridge = {
    send = function(data) send({ type = "from_job", job = jobId, data = data }) end,
    connected = function() return ws ~= nil end,
  }
  return env
end

local function serialise(value)
  local ok, s = pcall(textutils.serialise, value, { allow_repetitions = true })
  return ok and s or tostring(value)
end

local function runJob(job)
  local env = makeEnv(job.id)
  local fn, err

  if job.type == "eval" then
    fn = load("return " .. job.code, "=eval", "t", env)
    if not fn then fn, err = load(job.code, "=eval", "t", env) end
  else
    local path = shell.resolveProgram(job.program)
    if not path then return false, "No such program: " .. job.program end
    fn, err = loadfile(path, nil, env)
    env.arg = { [0] = path, table.unpack(job.args or {}) }
  end
  if not fn then return false, err end

  local res = table.pack(xpcall(function() return fn(table.unpack(job.args or {})) end, debug.traceback))
  if not res[1] then return false, res[2] end
  if res.n <= 1 then return true, nil end
  local vals = {}
  for i = 2, res.n do vals[#vals + 1] = serialise(res[i]) end
  return true, table.concat(vals, ", ")
end

finish = function(job, ok, result, t0)
  local done = { type = "done", job = job.id, ok = ok, ms = os.epoch("utc") - t0, status = status() }
  if ok then done.result = result else done.error = tostring(result) end
  send(done)
end

local function startJob(job)
  local task = { t0 = os.epoch("utc") }
  spawn(function()
    send({ type = "started", job = job.id, program = job.program, args = job.args })
    local ok, result = runJob(job)
    if not task.dead then finish(job, ok, result, task.t0) end
  end, job, task)
end

local function stopJobs(id)
  for _, t in ipairs(tasks) do
    if t.job and not t.dead and (id == nil or t.job.id == id) then
      t.dead = true
      finish(t.job, false, "Stopped by bridge", t.t0)
    end
  end
end

local function startAutorun()
  local auto = readTable(AUTORUN)
  if auto and auto.program then
    say("Autorun: " .. auto.program)
    startJob({ type = "run", id = "autorun-" .. os.epoch("utc"), program = auto.program, args = auto.args or {} })
  end
end

---------------------------------------------------------------------------
-- Bridge messages
---------------------------------------------------------------------------

local PROTECTED = { [".agent"] = true, ["startup/00_agent.lua"] = true }

local function safePath(path)
  local p = fs.combine("", path)
  if p:sub(1, 2) == ".." then return nil end
  for prefix in pairs(PROTECTED) do
    if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then return nil end
  end
  return p
end

local function handle(msg)
  if msg.type == "run" or msg.type == "eval" then
    startJob(msg)
  elseif msg.type == "stop" then
    stopJobs(msg.job)
  elseif msg.type == "put" then
    local p = safePath(msg.path)
    if p then writeFile(p, msg.content) end
    send({ type = "ack", req = msg.req, ok = p ~= nil, path = msg.path })
  elseif msg.type == "delete" then
    local p = safePath(msg.path)
    if p then fs.delete(p) end
    send({ type = "ack", req = msg.req, ok = p ~= nil, path = msg.path })
  elseif msg.type == "push" then
    os.queueEvent("bridge_push", msg.event, msg.data)
  elseif msg.type == "status" then
    send({ type = "status", req = msg.req, status = status() })
  elseif msg.type == "autorun" then
    if msg.program then
      writeFile(AUTORUN, textutils.serialise({ program = msg.program, args = msg.args or {} }))
    else
      fs.delete(AUTORUN)
    end
    send({ type = "ack", req = msg.req, ok = true })
    if msg.start then startAutorun() end
  elseif msg.type == "self_update" then
    writeFile(DIR .. "/agent.lua", msg.content)
    send({ type = "ack", req = msg.req, ok = true })
    sleep(0.5)
    os.reboot()
  elseif msg.type == "reboot" then
    os.reboot()
  end
end

local function fetchBridgeUrl()
  local res = http.get(cfg.gistUrl .. "?t=" .. os.epoch("utc"))
  if not res then return nil end
  local url = res.readAll():gsub("%s+", "")
  res.close()
  if not url:match("^https?://") then return nil end
  return url
end

local function connectLoop()
  while true do
    local base = fetchBridgeUrl()
    if not base then
      say("Bridge offline, retrying...")
    else
      local url = base:gsub("^http", "ws") .. "/ws?token=" .. cfg.token
      local sock, err = http.websocket(url, { ["ngrok-skip-browser-warning"] = "1" })
      if not sock then
        say("Connect failed: " .. tostring(err))
      else
        ws = sock
        say("Connected to bridge")
        send({ type = "hello", status = status() })
        -- Tell the bridge what's already running (e.g. autorun jobs started
        -- before we connected), and let programs know they can subscribe now.
        for _, t in ipairs(tasks) do
          if t.job and not t.dead then
            send({ type = "started", job = t.job.id, program = t.job.program or "(eval)", args = t.job.args })
          end
        end
        os.queueEvent("bridge_connected")
        local ping = os.startTimer(25)
        while true do
          local ev, a, b = os.pullEvent()
          if ev == "websocket_message" then
            local ok, msg = pcall(textutils.unserialiseJSON, b)
            if ok and type(msg) == "table" then handle(msg) end
          elseif ev == "websocket_closed" then
            break
          elseif ev == "bridge_send" and type(a) == "table" then
            -- Programs outside the agent (e.g. Claude OS in another tab)
            -- talk to the bridge with os.queueEvent("bridge_send", data).
            send({ type = "from_job", job = "ipc", data = a })
          elseif ev == "timer" and a == ping then
            send({ type = "ping", fuel = turtle and turtle.getFuelLevel() or nil })
            ping = os.startTimer(25)
          end
        end
        ws = nil
        say("Disconnected from bridge")
      end
    end
    sleep(5)
  end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

say("cc-scripts agent v" .. VERSION .. " (computer " .. os.getComputerID() .. ")")
spawn(connectLoop)
startAutorun()

while true do
  local ev = table.pack(os.pullEventRaw())
  local terminate = ev[1] == "terminate"
  -- Ctrl+T stops running jobs first; with no jobs left it stops the agent
  -- (unless the agent shares the screen with a shell, where Ctrl+T is meant for the shell).
  if terminate and not hasJobs() and not quiet then error("Terminated", 0) end

  for _, t in ipairs({ table.unpack(tasks) }) do
    local wants
    if terminate then wants = t.job ~= nil else wants = t.filter == nil or t.filter == ev[1] end
    if wants and not t.dead and coroutine.status(t.co) == "suspended" then
      resumeTask(t, table.unpack(ev, 1, ev.n))
    end
  end

  for i = #tasks, 1, -1 do
    if tasks[i].dead or coroutine.status(tasks[i].co) == "dead" then table.remove(tasks, i) end
  end
end
