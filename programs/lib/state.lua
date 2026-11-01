-- Saving a program's state so that being stopped or rebooted mid-save never
-- loses it: the new state goes to path.new and replaces the old file only
-- once it's complete. Loading falls back on path.new if the swap was cut
-- short.

local state = {}

local function read(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local data = h.readAll()
  h.close()
  return textutils.unserialise(data or "")
end

-- The saved table, or nil if there is none.
function state.load(path)
  local t = read(path)
  if type(t) == "table" then return t end
  t = read(path .. ".new")
  if type(t) == "table" then return t end
  return nil
end

function state.save(path, t)
  local h = fs.open(path .. ".new", "w")
  h.write(textutils.serialise(t))
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".new", path)
end

return state
