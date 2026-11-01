// Where the fleet is. Turtles keep their position relative to where their
// program started (lib/nav and the miner save it on every move). With the
// world coordinates of each start (bridge/fleet.json, or the factory's birth
// spot for the programs born there), that gives their real position. Few
// turtles can use GPS: a turtle needs a wireless modem for it, and the miners
// carry a pickaxe and a chunk controller.
//
// fleet.json: { "<id>": { at: [x,y,z], facing, dim } or
//               { from: "<id>", offset: [dx,dy,dz], facing, dim } }
// `from` starts are relative to another computer. Programs' frames: +z ahead
// (facing), +x to the right of it, +y up.

const FACING = { north: [0, -1], east: [1, 0], south: [0, 1], west: [-1, 0] };
const RIGHT = { north: 'east', east: 'south', south: 'west', west: 'north' };
export const FACTORY_ID = '4';
// Programs whose turtles are born on the factory's birth spot, one north of
// the factory, and start out facing north.
const BORN_AT_FACTORY = new Set(['excavate', 'treefarm', 'doorman', 'guard']);

// Lua that reports a computer's program and saved position as JSON.
export const PROBE = `
local function read(p)
  if not fs.exists(p) or fs.isDir(p) then return nil end
  local h = fs.open(p, "r") local s = h.readAll() h.close()
  return textutils.unserialise(s)
end
local a = read("/.agent/autorun") or {}
local files = { miner = "/.miner/state", treefarm = "/.treefarm", geominer = "/.geominer",
  elevator = "/.elevator", excavate = "/.excavate", builder = "/.builder",
  doorman = "/.doorman", guard = "/.guard" }
local prog = a.program
local s = prog and files[prog] and read(files[prog])
if not s then
  for p, f in pairs(files) do local t = read(f) if t and t.pos then s, prog = t, prog or p break end end
end
local gx, gy, gz
if peripheral.find("modem", function(_, m) return m.isWireless() end) then gx, gy, gz = gps.locate(1) end
return textutils.serialiseJSON({ program = prog, pos = s and s.pos, gps = gx and { gx, gy, gz } or nil })
`;

// Where a computer's frame starts, in world coordinates: { at, facing, dim }.
export function origin(fleet, id, program, seen = new Set()) {
  const f = fleet[id] ?? {};
  if (seen.has(id)) return null;
  seen.add(id);
  if (f.at) return { at: f.at, facing: f.facing ?? 'north', dim: f.dim ?? 'overworld' };
  let from = f.from, offset = f.offset, facing = f.facing;
  if (!from && BORN_AT_FACTORY.has(program)) [from, offset, facing] = [FACTORY_ID, [0, 0, -1], 'north'];
  if (!from) return null;
  const o = origin(fleet, from, null, seen);
  if (!o) return null;
  return { at: o.at.map((v, i) => v + offset[i]), facing: facing ?? o.facing, dim: f.dim ?? o.dim };
}

// Program frame -> world.
export function toWorld(o, p) {
  const [fx, fz] = FACING[o.facing];
  const [rx, rz] = FACING[RIGHT[o.facing]];
  return [o.at[0] + p.z * fx + p.x * rx, o.at[1] + p.y, o.at[2] + p.z * fz + p.x * rz];
}

// One computer's position from its PROBE answer:
// { world: [x,y,z] | null, dim, by: 'gps'|'start'|null, program, relative }.
export function locate(fleet, id, info) {
  const o = origin(fleet, String(id), info.program);
  const p = info.pos ?? { x: 0, y: 0, z: 0 };
  if (info.gps) return { world: info.gps, dim: o?.dim ?? null, by: 'gps', program: info.program, relative: info.pos ?? null };
  if (o) return { world: toWorld(o, p), dim: o.dim, by: 'start', program: info.program, relative: info.pos ?? null };
  return { world: null, dim: fleet[id]?.dim ?? null, by: null, program: info.program, relative: info.pos ?? null };
}

export const isValidFacing = (f) => Boolean(FACING[f]);
