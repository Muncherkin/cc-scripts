-- Offline tests for the fleet network: programs/lib/fleetstore.lua (the
-- server's state), programs/fleetd.lua and programs/lib/fleet.lua over the
-- simulator's radio. Run with: npm test
package.path = "tests/?.lua;programs/?.lua;" .. package.path
local sim = require("sim")
local fleetstore = require("lib.fleetstore")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else print("  FAIL  " .. msg) failures = failures + 1 end
end

local function cell(x, y, z) return { x = x, y = y or 0, z = z or 0 } end

---------------------------------------------------------------------------
-- The store on its own
---------------------------------------------------------------------------

print("Key-value store")
do
  local db = fleetstore.new(nil, 0)
  local function req(from, msg, t) return (db:handle(from, msg, t or 0)) end
  check(req(2, { op = "get", key = "a" }).ver == 0, "unset key: version 0")
  check(req(2, { op = "put", key = "a", value = { n = 1 } }).ver == 1, "put: version 1")
  local r = req(3, { op = "get", key = "a" })
  check(r.value.n == 1 and r.ver == 1, "another computer reads it")
  r = req(3, { op = "put", key = "a", value = 2, ver = 0 })
  check(not r.ok and r.err == "conflict" and r.ver == 1, "put with a stale version: conflict")
  check(req(3, { op = "put", key = "a", value = 2, ver = 1 }).ok, "put with the current version")
  req(2, { op = "put", key = "site/lift", value = 1 })
  req(2, { op = "put", key = "site/door", value = 1 })
  local keys = req(2, { op = "keys", prefix = "site/" }).keys
  check(#keys == 2 and keys[1] == "site/door", "keys by prefix, sorted")
  req(2, { op = "put", key = "a" })
  check(req(2, { op = "get", key = "a" }).value == nil, "put nil deletes")
  check(req(2, { op = "nope" }).err == "unknown op nope", "unknown op")
  check(db:handle(2, "hello", 0) == nil, "not a request: no reply")
end

print("A resent request gets the same reply, not done twice")
do
  local db = fleetstore.new(nil, 0)
  local a = db:handle(2, { op = "append", text = "x", rid = 7 }, 0)
  local b = db:handle(2, { op = "append", text = "x", rid = 7 }, 0)
  check(a.seq == 1 and b.seq == 1 and db.seq == 1, "one entry")
  check(db:handle(2, { op = "append", text = "y", rid = 8 }, 0).seq == 2, "the next rid is new")
end

print("Fleet log")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "ping", name = "Geode" }, 0)
  for i = 1, 5 do db:handle(2, { op = "append", text = "line " .. i }, i) end
  local r = db:handle(3, { op = "log", limit = 2 }, 9)
  check(#r.entries == 2 and r.entries[2].text == "line 5" and r.seq == 5, "the latest entries")
  check(r.entries[1].name == "Geode", "entries carry the sender's name")
  r = db:handle(3, { op = "log", since = 2, limit = 2 }, 9)
  check(#r.entries == 2 and r.entries[1].seq == 3, "paging on from a seq")
  local saved = {}
  db.onAppend = function(e) saved[#saved + 1] = e.text end
  db:handle(2, { op = "append", text = "to file" }, 10)
  check(saved[1] == "to file", "every entry goes to onAppend")
end

print("Reports and the fleet")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "report", name = "Otis", pos = cell(1, 2, 3), fuel = 900, status = "up", bogus = 1 }, 0)
  local f = db:handle(3, { op = "fleet" }, 0).fleet
  check(#f == 2 and f[1].name == "Otis" and f[1].fuel == 900 and f[1].bogus == nil, "record with known fields")
  check(db:handle(3, { op = "who", cells = { cell(1, 2, 3) } }, 0).holders[1].name == "Otis", "the reported cell is held")
end

print("Reservations")
do
  local db = fleetstore.new(nil, 0)
  local function req(from, msg, t) return (db:handle(from, msg, t or 0)) end
  check(req(2, { op = "reserve", cells = { cell(1), cell(2) } }).ok, "free cells: reserved")
  local r = req(3, { op = "reserve", cells = { cell(3), cell(2) } })
  check(not r.ok and r.by == 2 and r.cell.x == 2, "a held cell: refused, says who")
  check(req(4, { op = "reserve", cells = { cell(3) } }).ok, "all or none: 3 wasn't taken")
  check(req(2, { op = "reserve", cells = { cell(1), cell(2) } }).ok, "reserving my own cells again")
  req(2, { op = "reserve", cells = { cell(5) }, replace = true })
  check(req(3, { op = "reserve", cells = { cell(1), cell(2) } }).ok, "replace dropped the old ones")
  req(3, { op = "release" })
  check(req(2, { op = "reserve", cells = { cell(1) } }).ok, "release frees them")
  req(2, { op = "release", cells = { cell(1) } })
  check(req(3, { op = "reserve", cells = { cell(1) } }).ok, "release of one cell")
  local cells = {}
  for i = 1, fleetstore.MAX_CELLS + 1 do cells[i] = cell(100 + i) end
  check(req(5, { op = "reserve", cells = cells }).err == "too many cells", "a limit per client")
  check(req(6, { op = "reserve", cells = { { x = 1, y = 0, z = 0, dim = "mining" } } }).ok,
    "the same position in another dimension is another cell")
end

print("Reservations run out")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "reserve", cells = { cell(1) }, hold = 1000 }, 0)
  db:handle(2, { op = "ping" }, 1500)
  db:tick(1500)
  check(db:handle(3, { op = "reserve", cells = { cell(1) } }, 1500).ok, "past hold: free again")
end

print("Face to face in a one-wide passage")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "report", name = "A", pos = cell(0) }, 0)
  db:handle(3, { op = "report", name = "B", pos = cell(3) }, 0)
  check(db:handle(2, { op = "reserve", cells = { cell(1), cell(2) }, replace = true }, 0).ok, "A claims 1-2")
  local r = db:handle(3, { op = "reserve", cells = { cell(2), cell(1) }, replace = true }, 0)
  check(not r.ok and r.by == 2 and not r.deadlock, "B waits for A")
  r = db:handle(2, { op = "reserve", cells = { cell(3) }, here = cell(2), replace = true }, 0)
  check(not r.ok and r.by == 3 and r.here and r.deadlock, "A reaches 2, wants B's cell: deadlock")
  check(db:handle(4, { op = "who", cells = { cell(1) } }, 0).holders[1].by == 2, "a refused claim keeps the old one")
  db:handle(3, { op = "release" }, 0)
  db:handle(3, { op = "report", pos = cell(4) }, 0)
  check(db:handle(2, { op = "reserve", cells = { cell(3) }, replace = true }, 0).ok, "B backs off: A goes on")
  check(db:handle(4, { op = "who", cells = { cell(1) } }, 0).holders[1] == false, "and the cell behind A is freed")
end

print("Standing in a cell someone reserved")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "reserve", cells = { cell(1) } }, 0)
  db:handle(3, { op = "report", name = "B", pos = cell(1) }, 0)
  local h = db:handle(4, { op = "who", cells = { cell(1) } }, 0).holders[1]
  check(h.by == 3 and h.here, "the turtle that is there holds it")
  check(db.log[#db.log].text:find("reserved by"), "logged")
end

print("A turtle goes quiet")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "report", name = "A", pos = cell(0) }, 0)
  db:handle(2, { op = "reserve", cells = { cell(1) } }, 0)
  db:handle(2, { op = "subscribe", topic = "log" }, 0)
  db:handle(3, { op = "ping" }, fleetstore.LEASE)
  db:tick(fleetstore.LEASE)
  check(not db.fleet[2].quiet, "within the lease: fine")
  local t = fleetstore.LEASE + 1
  db:handle(3, { op = "ping" }, t)
  db:tick(t)
  check(db.fleet[2].quiet, "past the lease: quiet")
  check(db.log[#db.log].text == "A went quiet", "logged")
  check(db:handle(3, { op = "reserve", cells = { cell(1) } }, t).ok, "its reservations end")
  local r = db:handle(3, { op = "reserve", cells = { cell(0) } }, t)
  check(not r.ok and r.stale and r.by == 2, "its last cell stays blocked")
  check(db.subs[2] == nil, "its subscriptions end")
  db:tick(t + fleetstore.STALE + 1)
  check(db:handle(3, { op = "reserve", cells = { cell(0) } }, t + fleetstore.STALE + 1).ok, "until STALE runs out")

  local db2 = fleetstore.new(nil, 0)
  db2:handle(2, { op = "report", name = "A", pos = cell(0) }, 0)
  db2:tick(fleetstore.LEASE + 1)
  db2:handle(2, { op = "report", pos = cell(0) }, fleetstore.LEASE + 2)
  check(not db2.fleet[2].quiet and db2.cells["0,0,0"].here, "heard again: back, holding its cell")
end

print("Saved state survives a server restart")
do
  local db = fleetstore.new(nil, 0)
  db:handle(2, { op = "put", key = "k", value = "v" }, 0)
  db:handle(2, { op = "reserve", cells = { cell(1) } }, 0)
  db:handle(2, { op = "append", text = "hi" }, 0)
  -- through serialise and back, as on disk
  local textutils = sim.env(nil, sim.newComputer(), {}).textutils
  local saved = textutils.unserialise(textutils.serialise(db:save()))
  local t = fleetstore.LEASE * 2
  local db2 = fleetstore.new(saved, t)
  check(db2:handle(3, { op = "get", key = "k" }, t).value == "v", "keys")
  db2:tick(t + 1)
  check(not db2:handle(3, { op = "reserve", cells = { cell(1) } }, t + 1).ok, "reservations, on a fresh lease")
  check(db2:handle(3, { op = "append", text = "x" }, t).seq == 2, "log seq")
end

print("Subscriptions")
do
  local db = fleetstore.new(nil, 0)
  db:handle(3, { op = "subscribe", topic = "kv", prefix = "site/" }, 0)
  db:handle(4, { op = "subscribe", topic = "log" }, 0)
  local _, pushes = db:handle(2, { op = "put", key = "site/lift", value = 5 }, 0)
  check(#pushes == 1 and pushes[1].to == 3 and pushes[1].msg.ev == "kv" and pushes[1].msg.value == 5, "kv push to the prefix")
  _, pushes = db:handle(2, { op = "put", key = "other", value = 5 }, 0)
  check(#pushes == 0, "other keys: nothing")
  _, pushes = db:handle(2, { op = "append", text = "x" }, 0)
  check(#pushes == 1 and pushes[1].to == 4 and pushes[1].msg.entry.text == "x", "log push")
  db:handle(3, { op = "unsubscribe" }, 0)
  _, pushes = db:handle(2, { op = "put", key = "site/lift", value = 6 }, 0)
  check(#pushes == 0, "unsubscribed")
end

---------------------------------------------------------------------------
-- Over the radio: fleetd and lib/fleet
---------------------------------------------------------------------------

-- A radio with fleetd on computer 1 (modem `serverModem`, at the origin).
local function base(serverModem)
  local radio = sim.newRadio()
  local server = radio.add(1, { label = "Hub", modem = serverModem or "ender" })
  radio.start(server, "programs/fleetd.lua")
  radio.run(nil, 0.1)
  return radio, server
end

-- Runs fn(env) on computer c to the end; returns ok, result.
local function client(radio, c, fn, limit)
  radio.spawn(c, fn)
  radio.run(function() return c.done end, limit or 30)
  return c.ok, c.result
end

print("fleetd starts and serves")
do
  local radio, server = base()
  check(not server.done, "running")
  check(server.log[1]:find("fleetd on #1"), "says so")
  local t = radio.add(2, { label = "Otis", modem = "wireless", pos = { x = 30, y = 0, z = 0 } })
  local ok, res = client(radio, t, function(env)
    local fleet = env.require("lib.fleet")
    local f = assert(fleet.connect())
    assert(f:put("site/lift", { x = 1 }))
    local v, ver = f:get("site/lift")
    local seq = f:append("hello")
    local ok2, why, cur = f:put("site/lift", 2, 0)
    return { v = v, ver = ver, seq = seq, conflict = why, cur = cur, server = f.server, ok2 = ok2 }
  end)
  check(ok and res.server == 1, "a client finds the server")
  check(ok and res.v.x == 1 and res.ver == 1, "put and get")
  check(ok and res.seq == 2, "append (after fleetd's own start entry)")
  check(ok and res.ok2 == false and res.conflict == "conflict" and res.cur == 1, "conflict")
  check(server.files["/fleetd/log"] and server.files["/fleetd/log"]:find("hello"), "the log file")
  radio.run(nil, 6)
  check(server.files["/fleetd/state"] ~= nil, "state saved")
  local t2 = radio.add(3, { modem = "ender" })
  local _, r2 = client(radio, t2, function(env)
    local f = assert(env.require("lib.fleet").connect{ server = 1 })
    return f:get("site/lift")
  end)
  check(r2 and r2.x == 1, "a pinned server id")
end

print("Who reaches the server")
do
  local radio = base("ender")
  local far = radio.add(2, { modem = "wireless", pos = { x = 5000, y = 0, z = 0 } })
  local mining = radio.add(3, { modem = "wireless", dim = "mining" })
  local none = radio.add(4, {})
  local probe = function(env)
    local f, err = env.require("lib.fleet").connect()
    return f and f:ping() and "ok" or err
  end
  check(select(2, client(radio, far, probe)) == "ok", "ender server: a wireless turtle 5000 blocks away")
  check(select(2, client(radio, mining, probe)) == "ok", "ender server: wireless in another dimension")
  check(select(2, client(radio, none, probe)) == "no modem", "no modem: says so")

  local radio2 = base("wireless")
  local near = radio2.add(2, { modem = "wireless", pos = { x = 60, y = 0, z = 0 } })
  local away = radio2.add(3, { modem = "wireless", pos = { x = 100, y = 0, z = 0 } })
  local wired = radio2.add(4, { modem = "wired:factory" })
  check(select(2, client(radio2, near, probe)) == "ok", "wireless server: 60 blocks")
  check(select(2, client(radio2, away, probe)) == "no fleet server in range", "wireless server: not 100")
  check(select(2, client(radio2, wired, probe)) == "no fleet server in range", "a wired-only computer needs the server on its cable")
end

print("Other events aren't lost while waiting for a reply")
do
  local radio = base()
  local t = radio.add(2, { modem = "ender" })
  local _, res = client(radio, t, function(env)
    local f = env.require("lib.fleet").connect()
    env.os.queueEvent("bridge_push", "go")
    f:ping()
    local ev, a = env.os.pullEvent()
    return ev .. ":" .. tostring(a)
  end)
  check(res == "bridge_push:go", "queued again after the call")
end

print("Subscriptions over the radio")
do
  local radio = base()
  local a = radio.add(2, { modem = "ender", label = "Pebbles" })
  local b = radio.add(3, { modem = "ender", label = "Monocle" })
  local got
  radio.spawn(b, function(env)
    local fleet = env.require("lib.fleet")
    local f = fleet.connect()
    f:subscribe("kv", "site/")
    while true do
      local msg = fleet.push(env.os.pullEvent())
      if msg then got = msg return end
    end
  end)
  radio.run(nil, 1)
  client(radio, a, function(env)
    local f = env.require("lib.fleet").connect()
    f:put("other", 1)
    f:put("site/door", "open")
  end)
  radio.run(function() return b.done end, 5)
  check(got and got.ev == "kv" and got.key == "site/door" and got.value == "open" and got.by == "Pebbles",
    "the subscriber hears the matching put")
end

print("Two turtles meet in a one-wide passage")
do
  local radio = base()
  local a = radio.add(2, { modem = "ender", label = "A" })
  local b = radio.add(3, { modem = "ender", label = "B" })
  local trace = {}
  -- Each walks the x axis toward the other's end, claiming 2 cells ahead.
  -- On a deadlock the higher id backs off one cell and waits.
  local function walker(from, to, id)
    return function(env)
      local fleet = env.require("lib.fleet")
      local occ = fleet.occupancy(fleet.connect(), { dim = "overworld" })
      local x, step = from, to > from and 1 or -1
      occ.moved(cell(x))
      local waits = 0
      while x ~= to do
        local ahead = { cell(x + step) }
        if x + step ~= to then ahead[2] = cell(x + 2 * step) end
        local ok, info = occ.claim(ahead)
        if ok then
          x = x + step
          occ.moved(cell(x))
          trace[#trace + 1] = id .. "@" .. x
        else
          waits = waits + 1
          if info.deadlock and id == 3 then
            -- back out to the siding past the far end
            trace[#trace + 1] = id .. " gives way"
            while x < 8 do
              if occ.claim({ cell(x + 1) }) then
                x = x + 1
                occ.moved(cell(x))
                trace[#trace + 1] = id .. "@" .. x
              end
              env.sleep(0.4)
            end
            occ.release()
            return "gave way"
          end
          if waits > 20 then return "stuck" end
        end
        env.sleep(0.4)
      end
      occ.release()
      return "arrived"
    end
  end
  radio.spawn(a, walker(0, 6, 2))
  radio.spawn(b, walker(6, 0, 3))
  radio.run(function() return a.done and b.done end, 30)
  check(b.result == "gave way", "B gives way on the deadlock")
  check(a.result == "arrived", "A gets through")
  local pos = {}
  local clash = false
  for _, e in ipairs(trace) do
    local id, x = e:match("^(%d)@(%-?%d+)$")
    if id then
      pos[id] = tonumber(x)
      if pos["2"] and pos["3"] and pos["2"] >= pos["3"] then clash = true end
    end
  end
  check(not clash, "they never stand in or pass through each other's cell")
end

print("The server goes away")
do
  local radio, server = base()
  local t = radio.add(2, { modem = "ender" })
  local res = {}
  radio.spawn(t, function(env)
    local fleet = env.require("lib.fleet")
    local f = fleet.connect()
    local occ = fleet.occupancy(f)
    server.loaded = false
    local t0 = env.os.epoch("utc")
    res.get = select(3, f:get("x"))
    res.waited = env.os.epoch("utc") - t0
    local t1 = env.os.epoch("utc")
    local ok, info = occ.claim({ cell(1) })
    res.claim, res.offline = ok, info.offline
    res.fast = env.os.epoch("utc") - t1
    server.loaded = true
    env.sleep(fleet.RETRY)
    res.back = f:ping() ~= nil
  end)
  radio.run(function() return t.done end, 60)
  check(res.get == "offline" and res.waited >= 4000, "a call times out (two tries)")
  check(res.claim == true and res.offline, "claims go ahead offline")
  check(res.fast == 0, "and don't wait again until RETRY")
  check(res.back, "the server answers again after RETRY")
  check(t.ok, "no errors: " .. tostring(t.result))
end

print("No client: occupancy still works")
do
  local fleet = assert(loadfile("programs/lib/fleet.lua", "t", setmetatable({}, { __index = _G })))()
  local occ = fleet.occupancy(nil)
  local ok, info = occ.claim({ cell(1) })
  check(ok and info.offline, "every claim succeeds")
  occ.moved(cell(1))
  occ.release()
end

print("Local requests on the server's computer")
do
  local radio, server = base()
  -- Another program on the hub: a second coroutine sharing its event queue.
  local helper = radio.add("hub-shell", { label = "Hub" })
  local function both(...)
    local ev = table.pack(...)
    server.queue[#server.queue + 1] = ev
    helper.queue[#helper.queue + 1] = ev
  end
  server.globals.os.queueEvent = both
  helper.globals.os.queueEvent = both
  local ok, res = client(radio, helper, function(env)
    local f = env.require("lib.fleet").connect{ ["local"] = true }
    f:put("from", "eval")
    return (f:get("from"))
  end)
  check(ok and res == "eval", "put and get through fleet_local events: " .. tostring(res))
end

print("Borrowing the pickaxe's slot for a modem")
do
  local radio = base()
  local t = radio.add(2, { side = "left" })
  local inv = { [3] = { name = "computercraft:wireless_modem_advanced", count = 1 } }
  local equipped, selected = "minecraft:diamond_pickaxe", 1
  t.globals.turtle = {
    getItemDetail = function(s) return inv[s] end,
    getSelectedSlot = function() return selected end,
    select = function(s) selected = s return true end,
    equipLeft = function()
      local item = inv[selected]
      inv[selected] = { name = equipped, count = 1 }
      equipped = item and item.name
      t.modem = equipped == "computercraft:wireless_modem_advanced" and "ender" or nil
      if not t.modem then t.open = false end
      return true
    end,
    equipRight = function() error("wrong side") end,
    getEquippedLeft = function() return equipped and { name = equipped } end,
    getEquippedRight = function() return { name = "advancedperipherals:chunk_controller" } end,
  }
  local ok, res = client(radio, t, function(env)
    local fleet = env.require("lib.fleet")
    local before = fleet.connect()
    local v = fleet.withModem(function()
      local f = assert(fleet.connect())
      f:put("k", "swapped")
      return f:get("k")
    end)
    return { before = before, v = v }
  end)
  check(ok and res.before == nil, "no modem equipped: can't connect")
  check(ok and res.v == "swapped", "talks with the modem swapped in: " .. tostring(ok and res.v or res))
  check(equipped == "minecraft:diamond_pickaxe" and inv[3].name:find("modem") and selected == 1,
    "pickaxe back on, modem back in its slot, selection restored")
end

if failures > 0 then
  print(("\n%d failure(s)"):format(failures))
  os.exit(1)
end
print("\nAll fleet tests passed")
