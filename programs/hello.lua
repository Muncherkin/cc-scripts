-- Smoke test for the dev loop: prints some info about this computer.
local args = { ... }
print("Hello from computer " .. os.getComputerID() .. " (" .. (os.getComputerLabel() or "no label") .. ")")
print("Args: " .. (#args > 0 and table.concat(args, " ") or "none"))
print("Day " .. os.day() .. ", time " .. textutils.formatTime(os.time(), true))
if turtle then
  print("Turtle fuel: " .. tostring(turtle.getFuelLevel()))
  local ok, block = turtle.inspect()
  print("In front: " .. (ok and block.name or "air"))
end
return "hello done"
