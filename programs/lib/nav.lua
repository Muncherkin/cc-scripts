-- Restart-safe turtle movement with position tracking.
--
-- Coordinates are relative to where the program started: +z is the initial
-- facing, +x is to the right, +y is up. dir: 0=+z 1=+x 2=-z 3=-x.
--
-- The caller owns a state table (persisted however it likes) containing
-- pos = {x,y,z}, dir and pending; nav writes to it and calls save() around
-- every move, so after a reboot recover() can tell whether the last move
-- happened (fuel drops by exactly 1 per move).

local nav = {}

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
nav.DX, nav.DZ = DX, DZ

local state, save

function nav.init(s, saveFn)
  state, save = s, saveFn
  state.pos = state.pos or { x = 0, y = 0, z = 0 }
  state.dir = state.dir or 0
end

local function apply(kind, dir)
  local p = state.pos
  if kind == "up" then p.y = p.y + 1
  elseif kind == "down" then p.y = p.y - 1
  else
    local sign = kind == "back" and -1 or 1
    p.x = p.x + DX[dir] * sign
    p.z = p.z + DZ[dir] * sign
  end
end

function nav.recover()
  local pend = state.pending
  if not pend then return end
  if pend.kind ~= "turn" and turtle.getFuelLevel() < pend.fuel then apply(pend.kind, pend.dir) end
  state.pending = nil
  save()
end

function nav.turn(right)
  state.pending = { kind = "turn" }
  if right then turtle.turnRight() else turtle.turnLeft() end
  state.dir = (state.dir + (right and 1 or 3)) % 4
  state.pending = nil
  save()
end

function nav.face(dir)
  local diff = (dir - state.dir) % 4
  if diff == 1 then nav.turn(true)
  elseif diff == 2 then nav.turn(true) nav.turn(true)
  elseif diff == 3 then nav.turn(false) end
end

local ACT = {
  forward = { move = turtle.forward, detect = turtle.detect, dig = turtle.dig, inspect = turtle.inspect },
  back = { move = turtle.back },
  up = { move = turtle.up, detect = turtle.detectUp, dig = turtle.digUp, inspect = turtle.inspectUp },
  down = { move = turtle.down, detect = turtle.detectDown, dig = turtle.digDown, inspect = turtle.inspectDown },
}

-- Moves one block. opts.canDig(block) decides whether a block in the way may
-- be dug (default: never). Entities in the way are waited out, never attacked.
-- Returns true, dugSomething  or  false, reason.
function nav.move(kind, opts)
  opts = opts or {}
  local a = ACT[kind]
  local dug = false
  for _ = 1, opts.tries or 30 do
    if turtle.getFuelLevel() == 0 then return false, "out of fuel" end
    state.pending = { kind = kind, dir = state.dir, fuel = turtle.getFuelLevel() }
    save()
    if a.move() then
      apply(kind, state.dir)
      state.pending = nil
      save()
      return true, dug
    end
    state.pending = nil
    if not a.detect then return false, "blocked" end
    if a.detect() then
      local _, block = a.inspect()
      if not (opts.canDig and opts.canDig(block)) then return false, "blocked by " .. tostring(block and block.name) end
      if not a.dig() then return false, "can't dig " .. tostring(block and block.name) end
      dug = true
    else
      sleep(0.5) -- a player or mob is in the way
    end
  end
  return false, "stuck"
end

function nav.pos() return state.pos end
function nav.dir() return state.dir end

-- Steps along one axis to a target value.
function nav.stepTo(axis, target, opts)
  while state.pos[axis] ~= target do
    local kind
    if axis == "y" then
      kind = state.pos.y < target and "up" or "down"
    else
      if axis == "x" then nav.face(state.pos.x < target and 1 or 3) else nav.face(state.pos.z < target and 0 or 2) end
      kind = "forward"
    end
    local ok, why = nav.move(kind, opts)
    if not ok then return false, why end
  end
  return true
end

return nav
