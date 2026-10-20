-- Short jingles on an attached speaker. chime.play("print") etc; returns
-- false when there's no speaker.

local chime = {}

local TUNES = {
  print = { { "chime", 12 }, { "chime", 16 }, { "chime", 19 }, { "bell", 24 } },
  alert = { { "bell", 18 }, { "bell", 12 }, { "bell", 18 }, { "bell", 12 } },
  done = { { "pling", 12 }, { "pling", 19 } },
}

function chime.play(name, volume)
  local speaker = peripheral.find("speaker")
  if not speaker then return false end
  for _, note in ipairs(TUNES[name] or TUNES.print) do
    speaker.playNote(note[1], volume or 1.5, note[2])
    sleep(0.12)
  end
  return true
end

return chime
