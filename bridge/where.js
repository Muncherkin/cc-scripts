#!/usr/bin/env node
// Where is everything? Asks each computer for its program's saved position
// and turns it into world coordinates (see bridge/positions.js).
//
//   node bridge/where.js                       every computer, where it is
//   node bridge/where.js set <id> <x> <y> <z> <facing> [dimension]
//        record where a computer stands (or where its program started),
//        facing north/east/south/west, e.g. from F3 while looking at it

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PROBE, locate, isValidFacing } from './positions.js';

const API = 'http://127.0.0.1:8788';
const FLEET = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fleet.json');

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

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === 'set') {
  const [id, x, y, z, facing, dim] = rest;
  if (!isValidFacing(facing)) { console.error('Usage: where.js set <id> <x> <y> <z> <north|east|south|west> [dimension]'); process.exit(1); }
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
      info = JSON.parse(JSON.parse(job.result.replace(/\\\n/g, '\\n')));
    } catch (e) {
      console.log(`${name} (no answer: ${e.message})`);
      continue;
    }
    const l = locate(fleet, c.id, info);
    const rel = l.relative ? ` (${l.relative.x}, ${l.relative.y}, ${l.relative.z} from where ${l.program ?? 'it'} started)` : '';
    if (l.world) console.log(`${name} ${l.world.join(' ')}  ${l.dim ?? ''}${l.by === 'gps' ? ' by GPS' : ''}${rel}`);
    else console.log(`${name} start unknown${rel}`);
  }
}
