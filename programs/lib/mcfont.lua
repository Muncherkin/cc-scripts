-- Widths of the Minecraft default font, in GUI pixels at font size 1
-- (glyph width plus the 1 px gap), for laying out overlay text. Measured
-- from screenshots of the smart glasses overlay. Anything not listed is 6.

local mcfont = { HEIGHT = 9 }

local W = {}
for c in ("!',.:;i|"):gmatch(".") do W[c] = 2 end
for c in ("`l"):gmatch(".") do W[c] = 3 end
for c in (" It[]\"()*{}"):gmatch(".") do W[c] = 4 end
for c in ("<>fk"):gmatch(".") do W[c] = 5 end
for c in ("@~"):gmatch(".") do W[c] = 7 end
mcfont.widths = W

-- Width of s in GUI pixels. The last character's trailing gap is dropped.
function mcfont.width(s, size)
  s = tostring(s)
  if s == "" then return 0 end
  local w = 0
  for c in s:gmatch(".") do w = w + (W[c] or 6) end
  return (w - 1) * (size or 1)
end

-- Cuts s to at most maxW pixels, ending in ".." if anything was cut.
function mcfont.fit(s, maxW, size)
  s = tostring(s)
  if mcfont.width(s, size) <= maxW then return s end
  while #s > 0 and mcfont.width(s .. "..", size) > maxW do s = s:sub(1, -2) end
  return s .. ".."
end

-- Word-wraps s into lines of at most maxW pixels (at most maxLines; the
-- last one gets ".." if text was left over). sep is what separates the
-- words, " " by default; ", " keeps "308 cobble" together in a list.
function mcfont.wrap(s, maxW, maxLines, size, sep)
  sep = sep or " "
  local words = {}
  for word in (tostring(s) .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
    word = word:match("^%s*(.-)%s*$")
    if word ~= "" then words[#words + 1] = word end
  end
  local lines, line = {}, ""
  for i, word in ipairs(words) do
    if i < #words then word = word .. sep:gsub("%s+$", "") end
    local try = line == "" and word or line .. " " .. word
    if mcfont.width(try, size) <= maxW then
      line = try
    else
      if line ~= "" then lines[#lines + 1] = line end
      line = mcfont.fit(word, maxW, size)
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  if maxLines and #lines > maxLines then
    local rest = table.concat(lines, " ", maxLines)
    for i = #lines, maxLines + 1, -1 do lines[i] = nil end
    -- rest is wider than maxW (the next word did not fit), so fit adds ".."
    lines[maxLines] = mcfont.fit(rest, maxW, size)
  end
  return lines
end

return mcfont
