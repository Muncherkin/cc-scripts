-- The fleet server's state: a key-value store, the fleet log, each
-- computer's last report and cell reservations held on leases. Pure:
-- fleetd.lua does the radio and the disk. Every call takes the time in ms
-- and returns what to send. See docs/fleet-network.md.
--
-- Cells: a client holds the cell it last reported standing in ("here") and
-- the cells it reserved (each until released, replaced or `exp`). A client
-- that sends nothing for LEASE ms goes quiet: its reservations end, but its
-- last cell stays blocked (stale) for STALE ms, since a stopped turtle is
-- still a block in the passage.

local fleetstore = {}
local Store = {}
Store.__index = Store

fleetstore.LEASE = 30000
fleetstore.STALE = 600000
fleetstore.HOLD = 120000      -- the longest a reservation lasts without renewal
fleetstore.MAX_CELLS = 32     -- reserved cells per client
fleetstore.LOG_KEEP = 500     -- log entries kept in memory and saved state
-- Report fields kept in a computer's fleet record.
fleetstore.FIELDS = { "pos", "dim", "facing", "fuel", "status", "role", "job", "note" }

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

function fleetstore.cellKey(c)
  local k = c.x .. "," .. c.y .. "," .. c.z
  if c.dim and c.dim ~= "" then k = k .. "@" .. c.dim end
  return k
end
local cellKey = fleetstore.cellKey

-- A store from saved state (or nil). Every saved client starts a fresh
-- lease at `now`, so a server restart doesn't free anyone's cells.
function fleetstore.new(saved, now)
  saved = saved or {}
  local s = setmetatable({
    kv = saved.kv or {}, fleet = saved.fleet or {}, cells = saved.cells or {},
    stale = saved.stale or {}, log = saved.log or {}, seq = saved.seq or 0,
    subs = {}, wants = {}, last = {}, dirty = false,
  }, Store)
  for _, rec in pairs(s.fleet) do rec.seen = now end
  return s
end

function Store:save()
  return { kv = self.kv, fleet = self.fleet, cells = self.cells, stale = self.stale, log = self.log, seq = self.seq }
end

function Store:nameOf(id)
  local rec = self.fleet[id]
  return rec and rec.name or tostring(id)
end

-- Sends msg to every subscriber of topic whose prefix matches key.
-- (Outside handle and tick there's no one to send to.)
function Store:notify(topic, key, msg)
  if not self.pushes then return end
  msg.ev = topic
  for id, list in pairs(self.subs) do
    for _, sub in ipairs(list) do
      if sub.topic == topic and (not sub.prefix or (key or ""):sub(1, #sub.prefix) == sub.prefix) then
        self.pushes[#self.pushes + 1] = { to = id, msg = copy(msg) }
        break
      end
    end
  end
end

function Store:append(from, text, data, now)
  self.seq = self.seq + 1
  local e = { seq = self.seq, t = now, from = from, name = self:nameOf(from), text = text, data = copy(data) }
  self.log[#self.log + 1] = e
  while #self.log > fleetstore.LOG_KEEP do table.remove(self.log, 1) end
  self.dirty = true
  if self.onAppend then self.onAppend(e) end
  self:notify("log", text, { entry = e })
  return e
end

function Store:setCell(k, by)
  self:notify("cells", k, { cell = k, by = by, name = by and self:nameOf(by) or nil })
end

-- Drops a hold on cell k; frees the cell when nothing holds it.
function Store:unhold(k, id, what)
  local h = self.cells[k]
  if not h or h.by ~= id then return end
  h[what] = nil
  if not h.here and not h.exp then
    self.cells[k] = nil
    self:setCell(k, nil)
  end
end

-- id now stands in cell (a table): it holds it, whoever had reserved it.
function Store:setHere(id, cell, now)
  local rec = self.fleet[id]
  local k = cellKey(cell)
  if rec.here == k then return end
  if rec.here then self:unhold(rec.here, id, "here") end
  rec.here = k
  self.stale[k] = nil
  local h = self.cells[k]
  if h and h.by ~= id then
    self:append(id, ("%s is in %s, reserved by %s"):format(self:nameOf(id), k, self:nameOf(h.by)), nil, now)
    h = nil
  end
  if h then h.here = true
  else
    self.cells[k] = { by = id, here = true }
    self:setCell(k, id)
  end
  self.dirty = true
end

-- Who keeps id out of cell k, or nil.
function Store:blocker(k, id)
  local h = self.cells[k]
  if h and h.by ~= id then return { by = h.by, name = self:nameOf(h.by), here = h.here } end
  local s = self.stale[k]
  if s and s.by ~= id then return { by = s.by, name = self:nameOf(s.by), stale = true } end
end

-- Records a message from id: its lease starts over.
function Store:touch(id, name, now)
  local rec = self.fleet[id]
  if not rec then
    rec = { id = id }
    self.fleet[id] = rec
    self.dirty = true
  end
  if name and rec.name ~= name then rec.name = name self.dirty = true end
  rec.seen = now
  if rec.quiet then
    rec.quiet = nil
    for k, s in pairs(self.stale) do
      if s.by == id then self.stale[k] = nil end
    end
    self.dirty = true
  end
  return rec
end

local ops = {}

function ops.ping(self, from, msg, now) return { ok = true, t = now } end

function ops.get(self, from, msg)
  local e = self.kv[msg.key]
  if not e then return { ok = true, ver = 0 } end
  return { ok = true, value = e.value, ver = e.ver, by = e.by, t = e.t }
end

-- Sets (or with value nil deletes) a key. With ver, only if the key is
-- still at that version (0: doesn't exist yet).
function ops.put(self, from, msg, now)
  assert(type(msg.key) == "string", "key must be a string")
  local e = self.kv[msg.key]
  local cur = e and e.ver or 0
  if msg.ver and msg.ver ~= cur then return { ok = false, err = "conflict", ver = cur, value = e and e.value } end
  local ver = cur + 1
  if msg.value == nil then
    self.kv[msg.key] = nil
  else
    self.kv[msg.key] = { value = copy(msg.value), ver = ver, by = self:nameOf(from), t = now }
  end
  self.dirty = true
  self:notify("kv", msg.key, { key = msg.key, value = msg.value, ver = ver, by = self:nameOf(from) })
  return { ok = true, ver = ver }
end

function ops.keys(self, from, msg)
  local prefix, out = msg.prefix or "", {}
  for k in pairs(self.kv) do
    if k:sub(1, #prefix) == prefix then out[#out + 1] = k end
  end
  table.sort(out)
  return { ok = true, keys = out }
end

function ops.append(self, from, msg, now)
  local e = self:append(from, msg.text and tostring(msg.text), msg.data, now)
  return { ok = true, seq = e.seq }
end

-- Log entries after seq `since` (default: the last `limit`).
function ops.log(self, from, msg)
  local limit, out = msg.limit or 50, {}
  for _, e in ipairs(self.log) do
    if not msg.since or e.seq > msg.since then out[#out + 1] = e end
  end
  while #out > limit do table.remove(out, msg.since and #out or 1) end
  return { ok = true, entries = out, seq = self.seq }
end

function ops.report(self, from, msg, now)
  local rec = self.fleet[from]
  for _, f in ipairs(fleetstore.FIELDS) do
    if msg[f] ~= nil then rec[f] = copy(msg[f]) end
  end
  if msg.pos then
    local cell = copy(msg.pos)
    cell.dim = cell.dim or msg.dim
    self:setHere(from, cell, now)
  end
  self.dirty = true
  self:notify("fleet", rec.name, { rec = rec })
  return { ok = true }
end

function ops.fleet(self)
  local out = {}
  for _, rec in pairs(self.fleet) do out[#out + 1] = rec end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return { ok = true, fleet = out }
end

-- Reserves all of msg.cells or none. msg.here: where the client stands now
-- (saves a report). msg.replace: drop the client's other reservations, so
-- a turtle can reserve "the next cells of my path" on every step.
function ops.reserve(self, from, msg, now)
  if msg.here then self:setHere(from, msg.here, now) end
  local cells, keys = msg.cells or {}, {}
  for i, c in ipairs(cells) do keys[i] = cellKey(c) end
  for i, k in ipairs(keys) do
    local b = self:blocker(k, from)
    if b then
      self.wants[from] = keys
      -- Each waiting for the other: one of them has to give way.
      for _, w in ipairs(self.wants[b.by] or {}) do
        local h = self.cells[w]
        if h and h.by == from then b.deadlock = true end
      end
      b.ok, b.cell = false, cells[i]
      return b
    end
  end
  self.wants[from] = nil
  local mine, keep = {}, {}
  for _, k in ipairs(keys) do keep[k] = true end
  for k, h in pairs(self.cells) do
    if h.by == from and h.exp then
      if msg.replace and not keep[k] then mine[#mine + 1] = k else keep[k] = true end
    end
  end
  local n = 0
  for _ in pairs(keep) do n = n + 1 end
  if n > fleetstore.MAX_CELLS then return { ok = false, err = "too many cells" } end
  for _, k in ipairs(mine) do self:unhold(k, from, "exp") end
  local exp = now + math.min(msg.hold or fleetstore.HOLD, fleetstore.HOLD)
  for _, k in ipairs(keys) do
    local h = self.cells[k]
    if h then h.exp = exp
    else
      self.cells[k] = { by = from, exp = exp }
      self:setCell(k, from)
    end
  end
  self.dirty = true
  return { ok = true, exp = exp }
end

-- Releases msg.cells, or every reservation (not the cell it stands in).
function ops.release(self, from, msg, now)
  if msg.here then self:setHere(from, msg.here, now) end
  if msg.cells then
    for _, c in ipairs(msg.cells) do self:unhold(cellKey(c), from, "exp") end
  else
    for k, h in pairs(self.cells) do
      if h.by == from then self:unhold(k, from, "exp") end
    end
  end
  self.wants[from] = nil
  self.dirty = true
  return { ok = true }
end

-- Who holds each of msg.cells: a list of {by, name, here|stale} or false.
function ops.who(self, from, msg)
  local out = {}
  for i, c in ipairs(msg.cells or {}) do out[i] = self:blocker(cellKey(c), nil) or false end
  return { ok = true, holders = out }
end

-- Topics: kv (prefix: key), log, fleet (prefix: name), cells. Pushes end
-- when the subscriber goes quiet.
function ops.subscribe(self, from, msg)
  local list = self.subs[from] or {}
  self.subs[from] = list
  for i = #list, 1, -1 do
    if list[i].topic == msg.topic and list[i].prefix == msg.prefix then table.remove(list, i) end
  end
  list[#list + 1] = { topic = msg.topic, prefix = msg.prefix }
  return { ok = true }
end

function ops.unsubscribe(self, from, msg)
  local list = self.subs[from] or {}
  for i = #list, 1, -1 do
    if not msg.topic or list[i].topic == msg.topic then table.remove(list, i) end
  end
  return { ok = true }
end

-- Handles a request from computer `from`. Returns the reply (nil for
-- something that isn't a request) and a list of pushes {to, msg}. A resent
-- request (same rid as the last one) gets the same reply again.
function Store:handle(from, msg, now)
  if type(msg) ~= "table" or type(msg.op) ~= "string" then return nil, {} end
  local last = self.last[from]
  if msg.rid and last and last.rid == msg.rid then return last.reply, {} end
  self.pushes = {}
  self:touch(from, msg.name, now)
  local reply
  local op = ops[msg.op]
  if not op then
    reply = { ok = false, err = "unknown op " .. msg.op }
  else
    local ok, r = pcall(op, self, from, msg, now)
    reply = ok and r or { ok = false, err = tostring(r) }
  end
  reply.re = msg.rid
  if msg.rid then self.last[from] = { rid = msg.rid, reply = reply } end
  local pushes = self.pushes
  self.pushes = nil
  return reply, pushes
end

-- Ends what has run out: reservations past exp, leases of quiet clients,
-- stale cells. Returns pushes.
function Store:tick(now)
  self.pushes = {}
  for k, h in pairs(self.cells) do
    if h.exp and h.exp <= now then self:unhold(k, h.by, "exp") end
  end
  for id, rec in pairs(self.fleet) do
    if not rec.quiet and now - (rec.seen or 0) > fleetstore.LEASE then
      rec.quiet = true
      local held = false
      for k, h in pairs(self.cells) do
        if h.by == id then
          held = true
          if h.here then self.stale[k] = { by = id, since = now } end
          self.cells[k] = nil
          self:setCell(k, nil)
        end
      end
      rec.here = nil
      self.subs[id], self.wants[id], self.last[id] = nil, nil, nil
      if held or rec.pos then self:append(id, rec.name and (rec.name .. " went quiet") or "quiet", nil, now) end
      self:notify("fleet", rec.name, { rec = rec })
      self.dirty = true
    end
  end
  for k, s in pairs(self.stale) do
    if now - s.since > fleetstore.STALE then
      self.stale[k] = nil
      self.dirty = true
    end
  end
  local pushes = self.pushes
  self.pushes = nil
  return pushes
end

return fleetstore
