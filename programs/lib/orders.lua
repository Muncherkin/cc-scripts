-- The factory's order queue and its balancer.
--
-- An order is something wanted: items delivered to the output chest
-- ({ item, n, left }), items kept in stock ({ item, n, keep = true }) or a
-- turtle born into a job ({ birth = job, args }). `factory run` works on the
-- oldest unfinished one; the rest wait. The queue is a file, so any job on
-- the factory turtle can add to it (factory order ...), and reads and
-- writes never yield in between.
--
--   Orders.read() -> q          { next = id, list = { order, ... } } oldest first
--   Orders.add(order) -> order  with its id
--   Orders.update(id, fields)   set fields on one order
--   Orders.head(q)              the order being worked on
--   Orders.pending(q, jobs)     { { item, n }, ... } for planner.rank
--   Orders.balance(...)         what to gather faster, and births to queue

local M = {}

M.FILE = "/.factory/orders"
M.KEEP_DONE = 20    -- finished orders remembered
M.HORIZON = 60      -- minutes in which a shortfall should be gathered
M.BIRTH_GAP = 1800  -- seconds between births of one kind by the balancer

function M.read()
  local h = fs.open(M.FILE, "r")
  local q = h and textutils.unserialise(h.readAll()) or nil
  if h then h.close() end
  return q or { next = 1, list = {} }
end

function M.write(q)
  local done = 0
  for i = #q.list, 1, -1 do
    if q.list[i].done then
      done = done + 1
      if done > M.KEEP_DONE then table.remove(q.list, i) end
    end
  end
  local h = fs.open(M.FILE, "w")
  h.write(textutils.serialise(q))
  h.close()
end

function M.add(order)
  local q = M.read()
  order.id, q.next = q.next, q.next + 1
  order.at = os.epoch("utc")
  q.list[#q.list + 1] = order
  M.write(q)
  return order
end

-- Returns the order, or nil if there is none with that id.
function M.update(id, fields)
  local q = M.read()
  for _, o in ipairs(q.list) do
    if o.id == id then
      for k, v in pairs(fields) do o[k] = v end
      M.write(q)
      return o
    end
  end
end

function M.head(q)
  for _, o in ipairs(q.list) do
    if not o.done then return o end
  end
end

local function short(name) return (name:gsub("^[^:]*:", "")) end

function M.label(o)
  if o.birth then
    return "birth " .. o.birth .. (o.args and #o.args > 0 and (" " .. table.concat(o.args, " ")) or "")
  end
  return ("%d %s%s"):format(o.n, short(o.item), o.keep and " in stock" or "")
end

-- Unfinished orders as planner.rank wants them. A birth counts as its unit;
-- its kit is small and made when it's born.
function M.pending(q, jobs)
  local out = {}
  for _, o in ipairs(q.list) do
    if not o.done then
      if o.birth then
        if jobs[o.birth] then out[#out + 1] = { jobs[o.birth].unit, 1 } end
      else
        out[#out + 1] = { o.item, o.keep and o.n or o.left }
      end
    end
  end
  return out
end

-- The balancing rule on what the orders are short of.
--   rows:  planner.rank rows ({ item, n }): raw shortfall of all orders
--   flows: function(item) -> items/min in, out (nil before there's history)
--   jobs:  lib/jobs; a job with `gathers = { item = per minute }` is a
--          gatherer, and with `auto = true` the factory may birth it itself
-- Returns the advice (lib/rates' rows, with .job where a gatherer exists)
-- and the jobs to birth now: one of a kind at a time, BIRTH_GAP apart.
function M.balance(Rates, rows, have, flows, jobs, q, nowMs)
  local per, by = {}, {}
  for name, job in pairs(jobs) do
    for item, rate in pairs(job.gathers or {}) do
      local better = not by[item] or (job.auto and not jobs[by[item]].auto)
        or (job.auto == jobs[by[item]].auto and rate > per[item])
      if better then per[item], by[item] = rate, name end
    end
  end
  local keep, arows = {}, {}
  for _, r in ipairs(rows) do
    local inn, out = flows(r.item)
    local h = have[r.item] or 0
    keep[r.item] = h + r.n
    arows[#arows + 1] = { item = r.item, have = h, demand = out or 0, supply = inn or 0 }
  end
  local advice = Rates.advise(arows, { keep = keep, per = per, horizon = M.HORIZON })
  local births, seen = {}, {}
  for _, a in ipairs(advice) do
    a.job = by[a.item]
    if a.action == "add" and a.job and jobs[a.job].auto and not seen[a.job] then
      seen[a.job] = true
      local recent = false
      for _, o in ipairs(q.list) do
        if o.birth == a.job and (not o.done or nowMs - (o.at or 0) < M.BIRTH_GAP * 1000) then recent = true end
      end
      if not recent then births[#births + 1] = a.job end
    end
  end
  return advice, births
end

return M
