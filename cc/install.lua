-- Installs the cc-scripts agent on this computer.
-- Usage: wget run <raw url of this file> <gistUrl> <token>
-- (the bridge prints the exact command when it starts)

local REPO_RAW = "https://raw.githubusercontent.com/Muncherkin/cc-scripts/main/"

local gistUrl, token = ...
if not gistUrl or not token then
  printError("Usage: install <gistUrl> <token>")
  return
end

local function download(path)
  local res, err = http.get(REPO_RAW .. path .. "?t=" .. os.epoch("utc"))
  if not res then error("Download failed for " .. path .. ": " .. tostring(err), 0) end
  local body = res.readAll()
  res.close()
  return body
end

local function writeFile(path, content)
  local h = fs.open(path, "w")
  h.write(content)
  h.close()
end

writeFile("/.agent/agent.lua", download("cc/agent.lua"))
writeFile("/.agent/config", textutils.serialise({ gistUrl = gistUrl, token = token }))
writeFile("/startup/00_agent.lua", [[
if multishell then
  local id = shell.openTab("/.agent/agent.lua")
  multishell.setTitle(id, "agent")
else
  shell.run("/.agent/agent.lua")
end
]])

-- A label makes the computer keep its files when broken and picked up.
if not os.getComputerLabel() then
  os.setComputerLabel((turtle and "turtle-" or "computer-") .. os.getComputerID())
end

print("Agent installed as " .. os.getComputerLabel())
if not multishell then
  print("Note: not an advanced computer, so the agent runs in the foreground. Ctrl+T stops it.")
end
shell.run("/startup/00_agent.lua")
