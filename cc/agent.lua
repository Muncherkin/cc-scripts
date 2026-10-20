-- cc-scripts agent: connects this computer to the dev bridge so code can be
-- pushed, run and inspected remotely. Installed by cc/install.lua.

local VERSION = 1
local CONFIG = "/.agent/config"

local cfg do
  local h = fs.open(CONFIG, "r")
  if not h then error("No config at " .. CONFIG .. " - run install.lua first", 0) end
  cfg = textutils.unserialise(h.readAll())
  h.close()
end

local ws
local queue = {}
local current -- id of the job being run, if any

local function send(msg)
  if ws then pcall(ws.send, textutils.serialiseJSON(msg)) end
end

-- Like os.pullEvent, but Ctrl+T only stops the agent when no job is running
-- (during a job it terminates the job instead).
local function pull(filter)
  while true do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "terminate" and not current then error("Terminated", 0) end
    if filter == nil or ev[1] == filter then return table.unpack(ev, 1, ev.n) end
  end
end

local function wait(seconds)
  local t = os.startTimer(seconds)
  repeat local _, id = pull("timer") until id == t
end

local function status()
  local s = {
    id = os.getComputerID(),
    label = os.getComputerLabel(),
    version = VERSION,
    turtle = turtle ~= nil,
    pocket = pocket ~= nil,
    advanced = term.isColour(),
  }
  if turtle then
    s.fuel = turtle.getFuelLevel()
    s.selected = turtle.getSelectedSlot()
  end
  return s
end

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

local function jobLoop()
  while true do
    while #queue == 0 do pull("agent_job") end
    local job = table.remove(queue, 1)
    current = job.id
    send({ type = "started", job = job.id })
    local t0 = os.epoch("utc")
    local ok, result
    parallel.waitForAny(
      function() ok, result = runJob(job) end,
      function()
        while true do
          local _, id = pull("agent_stop")
          if id == job.id or id == "*" then ok, result = false, "Stopped by bridge" return end
        end
      end
    )
    current = nil
    local done = { type = "done", job = job.id, ok = ok, ms = os.epoch("utc") - t0, status = status() }
    if ok then done.result = result else done.error = tostring(result) end
    send(done)
  end
end

local PROTECTED = { [".agent"] = true, ["startup/00_agent.lua"] = true }

local function safePath(path)
  local p = fs.combine("", path)
  if p:sub(1, 2) == ".." then return nil end
  for prefix in pairs(PROTECTED) do
    if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then return nil end
  end
  return p
end

local function writeFile(path, content)
  local h = fs.open(path, "w")
  h.write(content)
  h.close()
end

local function handle(msg)
  if msg.type == "run" or msg.type == "eval" then
    queue[#queue + 1] = msg
    os.queueEvent("agent_job")
  elseif msg.type == "stop" then
    os.queueEvent("agent_stop", msg.job or "*")
  elseif msg.type == "put" then
    local p = safePath(msg.path)
    if p then writeFile(p, msg.content) end
    send({ type = "ack", req = msg.req, ok = p ~= nil, path = msg.path })
  elseif msg.type == "delete" then
    local p = safePath(msg.path)
    if p then fs.delete(p) end
    send({ type = "ack", req = msg.req, ok = p ~= nil, path = msg.path })
  elseif msg.type == "status" then
    send({ type = "status", req = msg.req, status = status() })
  elseif msg.type == "self_update" then
    writeFile("/.agent/agent.lua", msg.content)
    send({ type = "ack", req = msg.req, ok = true })
    wait(0.5)
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
      print("Bridge offline, retrying...")
    else
      local url = base:gsub("^http", "ws") .. "/ws?token=" .. cfg.token
      local sock, err = http.websocket(url)
      if not sock then
        print("Connect failed: " .. tostring(err))
      else
        ws = sock
        print("Connected to bridge")
        send({ type = "hello", status = status() })
        local ping = os.startTimer(25)
        while true do
          local ev, a, b = pull()
          if ev == "websocket_message" then
            local ok, msg = pcall(textutils.unserialiseJSON, b)
            if ok and type(msg) == "table" then handle(msg) end
          elseif ev == "websocket_closed" then
            break
          elseif ev == "timer" and a == ping then
            send({ type = "ping" })
            ping = os.startTimer(25)
          end
        end
        ws = nil
        print("Disconnected from bridge")
      end
    end
    wait(5)
  end
end

print("cc-scripts agent v" .. VERSION .. " (computer " .. os.getComputerID() .. ")")
parallel.waitForAny(connectLoop, jobLoop)
