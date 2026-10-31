-- Boot disk for newborn turtles. The factory copies this onto the floppy in
-- the drive next to its birth spot, together with the agent config, the job
-- and the job's programs. A freshly placed turtle boots from it once:
-- it refuels, takes its programs, and installs the agent with the job as its
-- autorun. The installer then reboots it into the fleet.

local REPO_RAW = "https://raw.githubusercontent.com/Muncherkin/cc-scripts/main/"
local disk = "/" .. fs.getDir(shell.getRunningProgram())

local function read(path)
  local h = fs.open(path, "r")
  if not h then error("Boot disk is missing " .. path, 0) end
  local data = h.readAll()
  h.close()
  return data
end

local function write(path, data)
  local h = fs.open(path, "w")
  h.write(data)
  h.close()
end

-- Never boot from a disk again: this turtle has its own startup from now on.
settings.set("shell.allow_disk_startup", false)
settings.save()

local job = textutils.unserialise(read(disk .. "/job"))

-- Programs keep their folders, e.g. files/lib/nav.lua -> /lib/nav.lua.
local function copyTree(from, to)
  for _, name in ipairs(fs.list(from)) do
    local src, dst = from .. "/" .. name, to .. "/" .. name
    if fs.isDir(src) then copyTree(src, dst) else write(dst, read(src)) end
  end
end
copyTree(disk .. "/files", "")
write("/.agent/autorun", textutils.serialise({ program = job.program, args = job.args or {} }))

for slot = 1, 16 do
  local item = turtle.getItemDetail(slot)
  if item and (item.name == "minecraft:charcoal" or item.name == "minecraft:coal") then
    turtle.select(slot)
    turtle.refuel()
  end
end
turtle.select(1)

local cfg = textutils.unserialise(read(disk .. "/agent-config"))
local res, err = http.get(REPO_RAW .. "cc/install.lua?t=" .. os.epoch("utc"))
if not res then error("Can't download the installer: " .. tostring(err), 0) end
write("/install.lua", res.readAll())
res.close()
shell.run("/install.lua", cfg.gistUrl, cfg.token)
