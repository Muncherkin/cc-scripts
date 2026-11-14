-- The loading bay's ledger: what each turtle may still draw from storage.
--
-- The bay is the factory's birth spot. It touches a wired modem, so a turtle
-- parked there is on the storage network and the factory pushes items
-- straight into it: no chests at the sites, no kits handed over, no
-- requests. A turtle's whole need is written here once, against its
-- computer id (its allowance); every time it stands in the bay the factory
-- fills it from what's left. A newborn has no id until it's switched on, so
-- its allowance waits under "next" and goes to the first unlabelled turtle
-- the bay hasn't seen: a birth cut short still ends with a loaded turtle.
--
--   Bay.read() -> ledger    { [id] = { items = { [item] = n }, fuel = n }, next = { entry, ... } }
--   Bay.add(id | "next", items, fuel)   adds to an allowance
--   Bay.get(id), Bay.set(id, entry)     entry == nil forgets it
--   Bay.adopt(id) -> entry              the oldest "next" allowance becomes id's
--   Bay.left(entry) -> n                items still to draw

local M = {}

M.FILE = "/.factory/allow"

function M.read()
  local h = fs.open(M.FILE, "r")
  local t = h and textutils.unserialise(h.readAll()) or nil
  if h then h.close() end
  t = t or {}
  t.next = t.next or {}
  return t
end

function M.write(t)
  local h = fs.open(M.FILE, "w")
  h.write(textutils.serialise(t))
  h.close()
end

local function merge(entry, items, fuel)
  entry = entry or { items = {}, fuel = 0 }
  for item, n in pairs(items or {}) do
    if n > 0 then entry.items[item] = (entry.items[item] or 0) + n end
  end
  entry.fuel = (entry.fuel or 0) + (fuel or 0)
  return entry
end

function M.add(id, items, fuel)
  local t = M.read()
  if id == "next" then
    t.next[#t.next + 1] = merge(nil, items, fuel)
  else
    t[id] = merge(t[id], items, fuel)
  end
  M.write(t)
end

function M.get(id) return M.read()[id] end

function M.set(id, entry)
  local t = M.read()
  t[id] = entry
  M.write(t)
end

function M.adopt(id)
  local t = M.read()
  local entry = table.remove(t.next, 1)
  if not entry then return nil end
  t[id] = merge(t[id], entry.items, entry.fuel)
  M.write(t)
  return t[id]
end

function M.left(entry)
  local n = 0
  for _, c in pairs(entry and entry.items or {}) do n = n + c end
  return n
end

return M
