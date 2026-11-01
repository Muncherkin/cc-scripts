-- Client for the fleet server (fleetd.lua): the shared key-value store, the
-- fleet log, position reports and cell reservations, over rednet. See
-- docs/fleet-network.md.
--
--   local fleet = require("lib.fleet")
--   local f, err = fleet.connect()        -- nil, err: no modem or no server
--   f:put("site/lift", { x = 1, y = 2, z = 3 })
--   local v, ver = f:get("site/lift")
--   f:append("zone 3 dug")
--   f:report{ pos = { x = 1, y = 2, z = 3 }, fuel = turtle.getFuelLevel() }
--   local ok, who = f:reserve({ { x = 1, y = 2, z = 4 } })
--
-- Calls wait for the reply without losing other events: whatever else
-- arrives meanwhile is queued again afterwards. Pushes from subscriptions
-- that arrive during a call become "fleet_event" (topic, msg) events;
-- outside a call they are rednet_message events, which fleet.push()
-- recognises. A call that gets no answer returns nil, "offline", and the
-- client doesn't try again for RETRY seconds (f.offline is set).

local fleet = {}
fleet.PROTOCOL = "fleet"
fleet.TIMEOUT = 2
fleet.RETRY = 30

local Client = {}
Client.__index = Client

local function now() return os.epoch("utc") end

local function openModems()
  local n = 0
  if not peripheral or not rednet then return 0 end
  peripheral.find("modem", function(side)
    if not rednet.isOpen(side) then rednet.open(side) end
    n = n + 1
  end)
  return n
end

-- opts: name (default the label), server (an id; default the
-- "fleet.server" setting, else a rednet lookup), timeout, local (talk to a
-- fleetd on this same computer through events).
function fleet.connect(opts)
  opts = opts or {}
  local c = setmetatable({
    name = opts.name or os.getComputerLabel() or ("#" .. os.getComputerID()),
    timeout = opts.timeout or fleet.TIMEOUT,
    -- rids start at the clock so a rebooted client's first request isn't
    -- taken for a resend of its last one
    server = opts.server, rid = now(),
  }, Client)
  if opts["local"] then
    c.server = "local"
    return c
  end
  if openModems() == 0 then return nil, "no modem" end
  c.server = c.server or (settings and settings.get("fleet.server"))
    or rednet.lookup(fleet.PROTOCOL, "fleetd")
  if not c.server then return nil, "no fleet server in range" end
  return c
end

-- The push message if this event is one from a fleet server, else nil.
function fleet.push(ev, from, msg, proto)
  if ev == "rednet_message" and proto == fleet.PROTOCOL and type(msg) == "table" and msg.ev then return msg end
  if ev == "fleet_local_push" and type(from) == "table" then return from end
end

-- Sends msg once and waits for its reply (nil after the timeout).
function Client:exchange(msg)
  if self.server == "local" then os.queueEvent("fleet_local", msg)
  else rednet.send(self.server, msg, fleet.PROTOCOL) end
  local timer = os.startTimer(self.timeout)
  local later, reply = {}, nil
  while true do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "terminate" then
      for _, e in ipairs(later) do os.queueEvent(table.unpack(e, 1, e.n)) end
      error("Terminated", 0)
    elseif ev[1] == "timer" and ev[2] == timer then
      break
    elseif (ev[1] == "rednet_message" and ev[2] == self.server and ev[4] == fleet.PROTOCOL)
        or (ev[1] == "fleet_local_reply" and self.server == "local") then
      local m = ev[1] == "fleet_local_reply" and ev[2] or ev[3]
      if type(m) == "table" and m.re == msg.rid then
        reply = m
        os.cancelTimer(timer)
        break
      elseif type(m) == "table" and m.ev then
        later[#later + 1] = table.pack("fleet_event", m.ev, m)
      end
    elseif ev[1] == "fleet_local_push" and type(ev[2]) == "table" then
      later[#later + 1] = table.pack("fleet_event", ev[2].ev, ev[2])
    else
      later[#later + 1] = ev
    end
  end
  for _, e in ipairs(later) do os.queueEvent(table.unpack(e, 1, e.n)) end
  return reply
end

-- Sends a request (op and fields) and returns the reply, or nil when the
-- server doesn't answer. Resending is safe: the rid makes the server
-- answer a repeat from its cache instead of doing it twice.
function Client:call(msg)
  if self.offline and now() < self.offline then return nil end
  self.rid = self.rid + 1
  msg.rid, msg.name = self.rid, self.name
  for _ = 1, 2 do
    local reply = self:exchange(msg)
    if reply then
      self.offline = nil
      return reply
    end
  end
  self.offline = now() + fleet.RETRY * 1000
  return nil
end

-- The value (nil if unset) and its version (0 if unset).
function Client:get(key)
  local r = self:call{ op = "get", key = key }
  if not r then return nil, nil, "offline" end
  return r.value, r.ver
end

-- Sets key (value nil deletes it). With ver, only if the key is still at
-- that version: true, newVer | false, "conflict", curVer, curValue.
function Client:put(key, value, ver)
  local r = self:call{ op = "put", key = key, value = value, ver = ver }
  if not r then return nil, "offline" end
  if not r.ok then return false, r.err, r.ver, r.value end
  return true, r.ver
end

function Client:del(key, ver) return self:put(key, nil, ver) end

-- Changes a key with fn(old) -> new, retrying when someone else got there
-- first. Returns true, newVer or nil/false, err.
function Client:update(key, fn)
  for _ = 1, 5 do
    local v, ver, err = self:get(key)
    if err then return nil, err end
    local ok, e2 = self:put(key, fn(v), ver)
    if ok or e2 ~= "conflict" then return ok, e2 end
  end
  return false, "conflict"
end

function Client:keys(prefix)
  local r = self:call{ op = "keys", prefix = prefix }
  if not r then return nil, "offline" end
  return r.keys
end

-- Adds a line (and optional data) to the fleet log; returns its seq.
function Client:append(text, data)
  local r = self:call{ op = "append", text = text, data = data }
  if not r then return nil, "offline" end
  return r.seq
end

-- Log entries {seq, t, from, name, text, data} after seq `since` (default:
-- the latest `limit`), and the newest seq.
function Client:log(since, limit)
  local r = self:call{ op = "log", since = since, limit = limit }
  if not r then return nil, "offline" end
  return r.entries, r.seq
end

-- Updates this computer's fleet record: pos, dim, facing, fuel, status,
-- role, job, note. A pos also holds that cell.
function Client:report(t)
  local msg = { op = "report" }
  for k, v in pairs(t) do msg[k] = v end
  local r = self:call(msg)
  if not r then return nil, "offline" end
  return r.ok
end

-- Every computer's record: id, name, seen, quiet and the reported fields.
function Client:fleet()
  local r = self:call{ op = "fleet" }
  if not r then return nil, "offline" end
  return r.fleet
end

-- Reserves all of cells ({x, y, z, dim}) or none. opts: replace (drop my
-- other reservations), here (the cell I stand in), hold (ms). Returns true
-- | false, {by, name, cell, here|stale, deadlock} | nil, "offline".
function Client:reserve(cells, opts)
  opts = opts or {}
  local r = self:call{ op = "reserve", cells = cells, replace = opts.replace, here = opts.here, hold = opts.hold }
  if not r then return nil, "offline" end
  if r.ok then return true, r.exp end
  return false, r
end

-- Releases cells, or all my reservations (not the cell I stand in).
function Client:release(cells, here)
  local r = self:call{ op = "release", cells = cells, here = here }
  if not r then return nil, "offline" end
  return r.ok
end

-- For each cell, who holds it ({by, name, here|stale}) or false.
function Client:who(cells)
  local r = self:call{ op = "who", cells = cells }
  if not r then return nil, "offline" end
  return r.holders
end

-- Topics: "kv" (prefix: key), "log", "fleet" (prefix: name), "cells".
-- Subscriptions end when this computer goes quiet: keep calling something
-- (ping) at least every fleetstore.LEASE/2.
function Client:subscribe(topic, prefix)
  local r = self:call{ op = "subscribe", topic = topic, prefix = prefix }
  return r and r.ok
end

function Client:unsubscribe(topic)
  local r = self:call{ op = "unsubscribe", topic = topic }
  return r and r.ok
end

-- The server's clock (ms), or nil.
function Client:ping()
  local r = self:call{ op = "ping" }
  return r and r.t
end

---------------------------------------------------------------------------
-- The movement harness's occupancy interface
---------------------------------------------------------------------------
-- local occ = fleet.occupancy(client, { dim = "overworld" })
--   occ.claim(cells) -> true | false, info  all of cells or none; replaces
--                        the previous claim (claim the next few cells of
--                        the path on every step)
--   occ.moved(cell)   now standing in cell (sent with the next claim, or
--                        on its own every REPORT seconds)
--   occ.release()     drop every claim (keeps the cell it stands in)
--   occ.who(cells)    holders, as Client:who
-- Cells are world positions {x, y, z}. Without a client, or while the
-- server doesn't answer, every claim succeeds with info.offline: turtles
-- still can't move into each other, the network only saves them waiting
-- face to face.

fleet.REPORT = 5

function fleet.occupancy(client, opts)
  opts = opts or {}
  local occ, here, sent = {}, nil, 0
  local function cell(c)
    return { x = c.x, y = c.y, z = c.z, dim = c.dim or opts.dim }
  end
  local function cells(list)
    local out = {}
    for i, c in ipairs(list) do out[i] = cell(c) end
    return out
  end

  function occ.claim(list)
    if not client then return true, { offline = true } end
    local ok, info = client:reserve(cells(list), { replace = true, here = here })
    if ok == nil then return true, { offline = true } end
    sent = now()
    return ok, info
  end

  function occ.moved(c)
    here = cell(c)
    if client and now() - sent >= fleet.REPORT * 1000 then
      if client:report{ pos = here, dim = here.dim } then sent = now() end
    end
  end

  function occ.release()
    if client then client:release(nil, here) end
  end

  function occ.who(list)
    if not client then return nil, "offline" end
    return client:who(cells(list))
  end

  return occ
end

---------------------------------------------------------------------------
-- Borrowing a tool slot for a modem
---------------------------------------------------------------------------
-- A turtle whose upgrade slots are full (pickaxe + chunk controller) can
-- carry a modem in its inventory and swap it with the pickaxe to talk:
-- fleet.withModem(fn) equips the first modem found in the inventory on the
-- pickaxe's side (or opts.side), runs fn(), and swaps back, like
-- geominer's scanner. Never the chunk controller's side: its chunks would
-- unload. Returns fn's results, or nil, err.

local MODEMS = {
  ["computercraft:wireless_modem_advanced"] = true,
  ["computercraft:wireless_modem_normal"] = true,
}

function fleet.withModem(fn, opts)
  opts = opts or {}
  if peripheral.find("modem") then return fn() end
  local side = opts.side
  if not side and turtle.getEquippedLeft then
    local r, l = turtle.getEquippedRight(), turtle.getEquippedLeft()
    side = r and r.name:find("pickaxe", 1, true) and "right"
      or l and l.name:find("pickaxe", 1, true) and "left"
  end
  if not side then return nil, "no pickaxe side to borrow" end
  local slot
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and MODEMS[d.name] then slot = s break end
  end
  if not slot then return nil, "no modem to equip" end
  local equip = side == "left" and turtle.equipLeft or turtle.equipRight
  local prev = turtle.getSelectedSlot()
  turtle.select(slot)
  if not equip() then
    turtle.select(prev)
    return nil, "couldn't equip the modem"
  end
  for _ = 1, 10 do                  -- the modem takes a moment to attach
    if peripheral.isPresent(side) then break end
    sleep(0.05)
  end
  local res = table.pack(pcall(fn))
  turtle.select(slot)
  if peripheral.isPresent(side) and rednet.isOpen(side) then rednet.close(side) end
  equip()           -- the tool goes back on, the modem back into the slot
  turtle.select(prev)
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

return fleet
