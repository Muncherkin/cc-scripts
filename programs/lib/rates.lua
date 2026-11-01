-- Item flow rates: how fast each item comes into storage and goes out, in
-- items per minute, and the rule that turns "we use X this fast" into "we
-- need inputs this fast", so the fleet can add gatherers or slow its users.
--
--   local Rates = require("lib.rates")
--   local r = Rates.new({ window = 1800 }, saved)  -- saved: an old r.state()
--   r.snapshot(t, counts)   storage counts (item -> n) at t seconds
--   r.flow(t, item, n)      a move the factory made: n > 0 came in
--                           (intake, furnace output), n < 0 went out
--                           (crafts, smelting, gifts to turtles)
--   r.net(item)             items/min, the trend of the snapshots
--   r.inflow(item)          items/min in, from flows
--   r.outflow(item)         items/min out, from flows
--   r.report()              a row per item: have, net, inn, out, runway
--   Rates.need(planner, uses, setup)  raw inputs/min, smelts and furnaces
--                           that making `uses` (item -> per min) takes
--   Rates.advise(rows, opts)          add, slow or ok for each item
--
-- Snapshots alone only give the net change: a chest that fills by 60 and
-- empties by 60 a minute looks still. Flows tell the two apart, so the
-- factory reports its moves as well.

local M = {}

M.WINDOW = 1800   -- seconds of history the rates look at
M.EVERY = 60      -- snapshots closer together than this are skipped
M.MIN_SPAN = 120  -- seconds of history before a rate means anything

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

function M.new(opts, saved)
  opts = opts or {}
  local window = opts.window or M.WINDOW
  local every = opts.every or M.EVERY
  -- snaps: { { t = s, counts = {} }, ... } oldest first
  -- buckets: { { t = minute start, inn = {}, out = {} }, ... } oldest first
  local st = saved or { snaps = {}, buckets = {} }
  local r = {}

  local function now()
    local a = st.snaps[#st.snaps]
    local b = st.buckets[#st.buckets]
    return math.max(a and a.t or 0, b and (b.last or b.t) or 0)
  end

  local function prune(t)
    while #st.snaps > 2 and st.snaps[2].t <= t - window do table.remove(st.snaps, 1) end
    while #st.buckets > 0 and st.buckets[1].t + 60 <= t - window do table.remove(st.buckets, 1) end
  end

  function r.snapshot(t, counts)
    local last = st.snaps[#st.snaps]
    if last and t - last.t < every then return false end
    st.snaps[#st.snaps + 1] = { t = t, counts = copy(counts) }
    st.first = st.first or t
    prune(t)
    return true
  end

  function r.flow(t, item, n)
    if n == 0 then return end
    local start = t - t % 60
    local b = st.buckets[#st.buckets]
    if not b or b.t ~= start then
      b = { t = start, inn = {}, out = {} }
      st.buckets[#st.buckets + 1] = b
    end
    b.last = t
    local side = n > 0 and b.inn or b.out
    side[item] = (side[item] or 0) + math.abs(n)
    st.first = st.first or t
    prune(t)
  end

  -- Least-squares slope of the counts over the window, per minute. A craft
  -- that takes a stack out between two snapshots moves one point, not the
  -- whole trend.
  function r.net(item)
    local s = st.snaps
    if #s < 2 or s[#s].t - s[1].t < M.MIN_SPAN then return nil end
    local n, st_, sc, stt, stc = #s, 0, 0, 0, 0
    for _, p in ipairs(s) do
      local c = p.counts[item] or 0
      st_, sc, stt, stc = st_ + p.t, sc + c, stt + p.t * p.t, stc + p.t * c
    end
    local d = n * stt - st_ * st_
    if d == 0 then return 0 end
    return (n * stc - st_ * sc) / d * 60
  end

  local function span()
    if not st.first then return nil end
    local s = math.min(window, now() - st.first)
    if s < M.MIN_SPAN then return nil end
    return s / 60
  end

  local function flowRate(item, side)
    local mins = span()
    if not mins then return nil end
    local total = 0
    for _, b in ipairs(st.buckets) do total = total + (b[side][item] or 0) end
    return total / mins
  end

  function r.inflow(item) return flowRate(item, "inn") end
  function r.outflow(item) return flowRate(item, "out") end

  function r.have(item)
    local last = st.snaps[#st.snaps]
    return last and last.counts[item] or 0
  end

  -- One row per item seen; runway is minutes until it runs out at the
  -- current trend (math.huge if it isn't falling). Shortest runway first.
  function r.report()
    local seen = {}
    local last = st.snaps[#st.snaps]
    for item in pairs(last and last.counts or {}) do seen[item] = true end
    for _, b in ipairs(st.buckets) do
      for item in pairs(b.inn) do seen[item] = true end
      for item in pairs(b.out) do seen[item] = true end
    end
    local rows = {}
    for item in pairs(seen) do
      local have, net = r.have(item), r.net(item)
      rows[#rows + 1] = { item = item, have = have, net = net, inn = r.inflow(item) or 0,
                          out = r.outflow(item) or 0,
                          runway = net and net < 0 and have / -net or math.huge }
    end
    table.sort(rows, function(a, b)
      if a.runway ~= b.runway then return a.runway < b.runway end
      return a.item < b.item
    end)
    return rows
  end

  function r.state() return st end

  return r
end

-- What making `uses` (item -> items/min) takes per minute: raw inputs, smelts,
-- the furnaces those smelts keep busy and the logs their charcoal comes from.
-- Rates are worked out from a batch of 64 so one craft's leftovers don't
-- round every item up. setup: { smeltS = 10 }
function M.need(planner, uses, setup)
  setup = setup or {}
  local per = (setup.smeltS or 10)
  local out = { raws = {}, smelts = 0 }
  for item, rate in pairs(uses) do
    local t = planner.tree(item, 64, {})
    for raw, n in pairs(t.raws) do out.raws[raw] = (out.raws[raw] or 0) + n / 64 * rate end
    out.smelts = out.smelts + t.smeltCount / 64 * rate
  end
  out.furnaces = out.smelts * per / 60
  out.fuelLogs = out.smelts / 7
  return out
end

-- The balancing rule. For each item: { item, have, demand, supply } (per
-- minute). opts:
--   keep[item]  stock to hold; a shortfall is made up over `horizon` minutes
--   cap[item]   stock above which more coming in is waste
--   per[item]   what one gatherer brings in a minute, if we have a kind
--   horizon     minutes to refill to `keep` (default 60)
--   slack       how far off balance counts (default 0.1, a tenth)
-- Answers, per item:
--   add   supply is short and a gatherer can make it up: `count` more
--   slow  supply is short and nothing can gather it: users run at `factor`
--   cut   stock is over the cap and still growing: `count` gatherers fewer
--   ok
function M.advise(rows, opts)
  opts = opts or {}
  local keep, cap, per = opts.keep or {}, opts.cap or {}, opts.per or {}
  local horizon, slack = opts.horizon or 60, opts.slack or 0.1
  local out = {}
  for _, row in ipairs(rows) do
    local item, have = row.item, row.have or 0
    local demand, supply = row.demand or 0, row.supply or 0
    local required = demand + math.max(0, (keep[item] or 0) - have) / horizon
    local a = { item = item, required = required, supply = supply, action = "ok" }
    if required > 0 and supply < required * (1 - slack) then
      local gap = required - supply
      if per[item] and per[item] > 0 then
        a.action, a.count = "add", math.ceil(gap / per[item])
      else
        a.action, a.factor = "slow", supply / required
      end
      a.gap = gap
    elseif cap[item] and have > cap[item] and supply > demand * (1 + slack) then
      local excess = supply - demand
      a.action, a.gap = "cut", -excess
      a.count = per[item] and per[item] > 0 and math.floor(excess / per[item]) or nil
    end
    out[#out + 1] = a
  end
  local rank = { add = 1, slow = 2, cut = 3, ok = 4 }
  table.sort(out, function(x, y)
    if rank[x.action] ~= rank[y.action] then return rank[x.action] < rank[y.action] end
    return math.abs(x.gap or 0) > math.abs(y.gap or 0)
  end)
  return out
end

-- Furnaces: the smelts a minute the work needs against what `n` furnaces
-- of `smeltS` seconds an item do. Returns how many more (0 if enough).
function M.furnacesShort(smeltsPerMin, n, smeltS)
  local need = math.ceil(smeltsPerMin * (smeltS or 10) / 60)
  return math.max(0, need - n), need
end

return M
