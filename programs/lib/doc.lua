-- Parser for the document format shared by printlist and Claude OS:
--   # Title / > Subtitle / ## Section / - 35 Gold Ingot | note
--   ``` art ``` / --- page break / anything else is text
-- parse(src) returns a list of blocks:
--   { t = "title"|"subtitle"|"heading"|"text"|"art"|"blank"|"break", text = ... }
--   { t = "item", count = 35 or nil, name = "Gold Ingot", note = "..." or nil, key = "..." }

local doc = {}

function doc.parse(src)
  local blocks, inArt, haveTitle = {}, false, false
  local function add(b) blocks[#blocks + 1] = b end
  for raw in (src .. "\n"):gmatch("(.-)\r?\n") do
    if raw:match("^```") then
      inArt = not inArt
    elseif inArt then
      add({ t = "art", text = raw })
    elseif raw:match("^# ") and not haveTitle then
      haveTitle = true
      add({ t = "title", text = raw:sub(3) })
    elseif raw:match("^> ") then
      add({ t = "subtitle", text = raw:sub(3) })
    elseif raw:match("^## ") then
      add({ t = "heading", text = raw:sub(4) })
    elseif raw:match("^%-%-%-") then
      add({ t = "break" })
    elseif raw:match("^%- ") then
      local body = raw:sub(3)
      local item, note = body:match("^(.-)%s*|%s*(.*)$")
      item = item or body
      local count, name = item:match("^(%d+)%s+(.*)$")
      add({ t = "item", count = tonumber(count), name = name or item, note = note ~= "" and note or nil, key = item })
    elseif raw:match("^%s*$") then
      add({ t = "blank" })
    else
      add({ t = "text", text = raw })
    end
  end
  return blocks
end

-- The title of a document (first "# " line), without parsing all of it.
function doc.title(src)
  return src:match("^# ([^\r\n]+)") or src:match("\n# ([^\r\n]+)")
end

-- Word-wraps text to width; continuation lines start with indent.
function doc.wrap(text, width, indent)
  indent = indent or ""
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if #line == 0 then line = (#lines == 0 and "" or indent) .. word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1] = line line = indent .. word end
    while #line > width do
      lines[#lines + 1] = line:sub(1, width)
      line = indent .. line:sub(width + 1)
    end
  end
  if #line > 0 then lines[#lines + 1] = line end
  if #lines == 0 then lines[1] = "" end
  return lines
end

return doc
