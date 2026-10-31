-- Agent autorun for the door computer. On basic computers the agent runs next
-- to the shell, which owns the keyboard, so this types "door" into the shell
-- to start the vault terminal there.

sleep(1) -- let the shell reach its prompt
os.queueEvent("paste", "door")
os.queueEvent("key", keys.enter, false)
