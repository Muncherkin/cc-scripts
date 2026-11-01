#!/usr/bin/env node
// Where is everything? Turtles keep their position relative to where their
// program started (lib/nav and the miner save it on every move). With the
// world coordinates of each start, recorded in bridge/fleet.json, that gives
// their real position. Few turtles can use GPS: a turtle needs a wireless
// modem for it, and the miners carry a pickaxe and a chunk controller.
//
//   node bridge/where.js                       every computer, where it is
//   node bridge/where.js set <id> <x> <y> <z> <facing> [dimension]
//        record where a computer stands (or where its program started),
//        facing north/east/south/west, e.g. from F3 while looking at it
//
// fleet.json: { "<id>": { at: [x,y,z], facing, dim } or
//               { from: "<id>", offset: [dx,dy,dz], facing, dim } }
// `from` starts are relative to another computer (the birth spot is one
// north of the factory turtle). Programs' frames: +z ahead (facing), +x to
// the right of it, +y up.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const API = 'http://127.0.0.1:8788';
const FLEET = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fleet.json');
const FACING = { north: [0, -1], east: [1, 0], south: [0, 1], west: [-1, 0] };
const RIGHT = { north: 'east', east: 'south', south: 'west', west: 'north' };

async function call(method, route, body) {
  let res;
  try {
    res = await fetch(API + route, { method, headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  } catch {
    console.error('Bridge is not running. Start it with: npm run bridge');
    process.exit(2);
  }
  const data = await res.json();
  if (!res.ok) throw new Error(data.error);
  return data;
}

const fleet = fs.existsSync(FLEET) ? JSON.parse(fs.readFileSync(FLEET, 'utf8')) : {};

// Where a computer's frame starts, in world coordinates: { at, facing, dim }.
function origin(id, seen = new Set()) {
  const f = fleet[id];
  if (!f || seen.has(id)) return null;
  seen.add(id);
  if (f.at) return f;
  if (!f.from) return null;
  const o = origin(f.from, seen);
  if (!o) return null;
  return { at: o.at.map((v, i) => v + f.offset[i]), facing: f.facing, dim: f.dim ?? o.dim };
}

// Program frame -> world.
function toWorld(o, p) {
  const [fx, fz] = FACING[o.facing];
  const [rx, rz] = FACING[RIGHT[o.facing]];
  return [o.at[0] + p.z * fx + p.x * rx, o.at[1] + p.y, o.at[2] + p.z * fz + p.x * rz];
}

const PROBE = `
local function read(p)
  if not fs.exists(p) or fs.isDir(p) then return nil end
  local h = fs.open(p, "r") local s = h.readAll() h.close()
  return textutils.unserialise(s)
end
local a = read("/.agent/autorun") or {}
local files = { miner = "/.miner/state", treefarm = "/.treefarm", geominer = "/.geominer",
  elevator = "/.elevator", excavate = "/.excavate", builder = "/.builder" }
local prog = a.program
local s = prog and files[prog] and read(files[prog])
if not s then
  for p, f in pairs(files) do local t = read(f) if t and t.pos then s, prog = t, prog or p break end end
end
local gx, gy, gz
if peripheral.find("modem", function(_, m) return m.isWireless() end) then gx, gy, gz = gps.locate(1) end
return textutils.serialiseJSON({ program = prog, pos = s and s.pos, gps = gx and { gx, gy, gz } or nil })
`;

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === 'set') {
  const [id, x, y, z, facing, dim] = rest;
  if (!FACING[facing]) { console.error('Usage: where.js set <id> <x> <y> <z> <north|east|south|west> [dimension]'); process.exit(1); }
  fleet[id] = { ...(fleet[id] ?? {}), at: [x, y, z].map(Number), facing, dim: dim ?? fleet[id]?.dim ?? 'overworld' };
  delete fleet[id].from; delete fleet[id].offset;
  fs.writeFileSync(FLEET, JSON.stringify(fleet, null, 2) + '\n');
  console.log(`Recorded #${id} at ${x} ${y} ${z} facing ${facing}`);
} else {
  const list = await call('GET', '/computers');
  for (const c of list.sort((a, b) => a.id - b.id)) {
    const name = `#${c.id} ${fleet[c.id]?.name ?? c.label ?? ''}`.padEnd(18);
    let info;
    try {
      const job = await call('POST', '/eval', { computer: c.id, code: PROBE, timeout: 5 });
      info = JSON.parse(job.result.replace(/^"|"$/g, '').replace(/\\"/g, '"').replace(/\\\n/g, '\n'));
    } catch (e) {
      console.log(`${name} (no answer: ${e.message})`);
      continue;
    }
    const o = origin(String(c.id));
    const p = info.pos ?? { x: 0, y: 0, z: 0 };
    const rel = info.pos ? ` (${p.x}, ${p.y}, ${p.z} from where ${info.program ?? 'it'} started)` : '';
    if (info.gps) console.log(`${name} ${info.gps.join(' ')}  by GPS${rel}`);
    else if (o) console.log(`${name} ${toWorld(o, p).join(' ')}  ${o.dim}${rel}`);
    else console.log(`${name} start unknown${rel}`);
  }
}
