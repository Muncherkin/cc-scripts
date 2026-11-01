-- Fleet server: the in-game hub every computer can get from and put to. A
-- key-value store, the fleet log, each computer's last report and cell
-- reservations (lib/fleetstore.lua), served over rednet (protocol "fleet")
-- to lib/fleet.lua clients. Programs on this computer (and Claude, through
-- the agent's eval) can queue "fleet_local" requests and get
-- "fleet_local_reply" events back. See docs/fleet-network.md.
--
-- Usage: fleetd     (needs a modem; an ender modem reaches every dimension)

local fleetstore = require("lib.fleetstore")
local statelib = require("lib.state")

local DIR = "/fleetd"
local STATE = DIR .. "/state"
local LOGFILE = DIR .. "/log"
local SAVE_EVERY = 5000

local function now() return os.epoch("utc") end

local modems = 0
peripheral.find("modem", function(side)
  rednet.open(side)
  modems = modems + 1
end)
if modems == 0 then error("fleetd needs a modem (an ender modem reaches every dimension)", 0) end

local other = rednet.lookup("fleet", "fleetd")
if other and other ~= os.getComputerID() then error("fleetd is already running on #" .. other, 0) end
rednet.host("fleet", "fleetd")

local db = fleetstore.new(statelib.load(STATE), now())
-- The whole log goes to a file, one entry per line; the store keeps the tail.
db.onAppend = function(e)
  local h = fs.open(LOGFILE, "a")
  if h then
    h.writeLine(textutils.serialise(e, { compact = true }))
    h.close()
  end
end

local function send(pushes)
  for _, p in ipairs(pushes) do
    if p.to == "local" then os.queueEvent("fleet_local_push", p.msg)
    else rednet.send(p.to, p.msg, "fleet") end
  end
end

local count = 0
for _ in pairs(db.fleet) do count = count + 1 end
print(("fleetd on #%d: %d computers known, log at %d"):format(os.getComputerID(), count, db.seq))
db:append(os.getComputerID(), "fleetd started", nil, now())

local lastSave, timer = 0, os.startTimer(1)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "rednet_message" and c == "fleet" then
    local reply, pushes = db:handle(a, b, now())
    if reply then rednet.send(a, reply, "fleet") end
    send(pushes)
  elseif ev == "fleet_local" and type(a) == "table" then
    local reply, pushes = db:handle("local", a, now())
    if reply then os.queueEvent("fleet_local_reply", reply) end
    send(pushes)
  elseif ev == "timer" and a == timer then
    send(db:tick(now()))
    if db.dirty and now() - lastSave >= SAVE_EVERY then
      statelib.save(STATE, db:save())
      db.dirty, lastSave = false, now()
    end
    timer = os.startTimer(1)
  end
end
