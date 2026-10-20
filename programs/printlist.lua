-- Prints a materials list / plan on the attached printer, then chimes.
--
-- Usage: printlist <name>   (reads /prints/<name>.txt, or a path)
--
-- File format, one element per line:
--   # Title                 page title (first one only)
--   > Subtitle              small line under the title
--   ## Section              section heading
--   - 35 Gold Ingot | note  checklist item: count, name, optional note
--   ```                     starts/ends verbatim ASCII art (centered)
--   ---                     page break
--   anything else           wrapped text; blank lines are kept

local chime = require("lib.chime")

local W, H = 25, 21 -- printed page size

-- Word-wraps text to width; continuation lines start with indent.
local function wrap(text, width, indent)
  indent = indent or ""
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if #line == 0 then line = (#lines == 0 and "" or indent) .. word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1] = line line = indent .. word end
    while #line > width do -- words longer than a line
      lines[#lines + 1] = line:sub(1, width)
      line = indent .. line:sub(width + 1)
    end
  end
  if #line > 0 then lines[#lines + 1] = line end
  if #lines == 0 then lines[1] = "" end
  return lines
end

local function center(text)
  text = text:sub(1, W)
  return (" "):rep(math.floor((W - #text) / 2)) .. text
end

-- Turns the source into a title and a list of body lines ("\f" = page break).
local function layout(src)
  local title, subtitle, body = nil, nil, {}
  local inArt = false
  local function add(l) body[#body + 1] = l end
  for raw in (src .. "\n"):gmatch("(.-)\r?\n") do
    if raw:match("^```") then
      inArt = not inArt
    elseif inArt then
      add({ art = raw })
    elseif raw:match("^# ") and not title then
      title = raw:sub(3)
    elseif raw:match("^> ") then
      subtitle = raw:sub(3)
    elseif raw:match("^## ") then
      if #body > 0 and body[#body] ~= "" then add("") end
      add("\v") -- keep the heading together with what follows
      add(raw:sub(4):upper())
      add(("-"):rep(math.min(W, #raw - 3)))
    elseif raw:match("^%- ") then
      local item, note = raw:sub(3):match("^(.-)%s*|%s*(.*)$")
      item = item or raw:sub(3)
      local count, name = item:match("^(%d+)%s+(.*)$")
      local text = count and (count .. "x " .. name) or item
      for _, l in ipairs(wrap("[ ] " .. text, W, "    ")) do add(l) end
      if note and #note > 0 then
        for _, l in ipairs(wrap(note, W - 4)) do add("    " .. l) end
      end
    elseif raw:match("^%-%-%-") then
      add("\f")
    else
      for _, l in ipairs(wrap(raw, W)) do add(l) end
    end
  end

  -- Center art blocks as a whole, based on their widest line.
  local i = 1
  while i <= #body do
    if type(body[i]) == "table" then
      local j, widest = i, 0
      while j <= #body and type(body[j]) == "table" do widest = math.max(widest, #body[j].art) j = j + 1 end
      local pad = (" "):rep(math.max(0, math.floor((W - widest) / 2)))
      for k = i, j - 1 do body[k] = (pad .. body[k].art):sub(1, W) end
      i = j
    else
      i = i + 1
    end
  end
  return title or "Untitled", subtitle, body
end

-- Splits body lines into pages, each with a header and footer.
local function paginate(title, subtitle, body)
  local pages, page = {}, nil
  local function newPage()
    page = { center(title) }
    if #pages == 0 and subtitle then page[#page + 1] = center(subtitle) end
    page[#page + 1] = ("="):rep(W)
    pages[#pages + 1] = page
  end
  newPage()
  for _, l in ipairs(body) do
    if l == "\f" then
      newPage()
    elseif l == "\v" then
      if #page > H - 5 then newPage() end
    elseif l == "" and #page >= H - 1 then
      -- a blank line at the bottom of a full page: drop it rather than start a page
    else
      if #page >= H - 1 then newPage() end
      if not (l == "" and #page <= 3) then page[#page + 1] = l end
    end
  end
  -- Never print a page that has nothing but its header.
  while #pages > 1 and #pages[#pages] <= 2 do pages[#pages] = nil end
  for n, p in ipairs(pages) do
    local footer = ("p%d/%d"):format(n, #pages)
    p.footer = footer .. (" "):rep(W - #footer - 6) .. "Claude"
  end
  return pages
end

local name = ...
if not name then error("Usage: printlist <name>", 0) end
local path = fs.exists(name) and name or ("/prints/" .. name .. (name:match("%.txt$") and "" or ".txt"))
local h = fs.open(path, "r")
if not h then error("No such list: " .. path, 0) end
local src = h.readAll()
h.close()

local title, subtitle, body = layout(src)
local pages = paginate(title, subtitle, body)

local printer = peripheral.find("printer")
if not printer then error("No printer attached", 0) end
if printer.getInkLevel() == 0 then error("The printer has no ink: put a dye in it (black dye or an ink sac for black text)", 0) end
if printer.getPaperLevel() < #pages then
  error(("Needs %d paper, the printer has %d"):format(#pages, printer.getPaperLevel()), 0)
end

for n, p in ipairs(pages) do
  if not printer.newPage() then error("The printer couldn't start a page (out of paper/ink, or the output tray is full?)", 0) end
  printer.setPageTitle(#pages > 1 and ("%s %d/%d"):format(title, n, #pages) or title)
  for y, l in ipairs(p) do
    printer.setCursorPos(1, y)
    printer.write(l)
  end
  printer.setCursorPos(1, H)
  printer.write(p.footer)
  if not printer.endPage() then error("Couldn't finish page " .. n .. ": is the output tray full?", 0) end
end

print(("Printed '%s' (%d page%s)"):format(title, #pages, #pages == 1 and "" or "s"))
chime.play("print")
return #pages
