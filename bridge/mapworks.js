#!/usr/bin/env node
// Maps the Clockworks with the Mover (#26): what is still standing in the
// volume the excavators were to clear. The Mover scans with its geo scanner
// (radius 8, free), and walks only through cells a scan has shown to be air,
// so it never digs. Each next scan is the reachable spot that shows the most
// of the volume not yet seen.
//
//   node bridge/mapworks.js [maxScans]
//
// Writes logs/scans/works.json ({ solid: { "x,y,z": name }, seen: [centres] },
// site coordinates) after every scan, so it can be stopped and run again, and
// logs/scans/works.txt: what's left, by block and by layer.

import fs from 'node:fs';
import { volume } from '../design/excavation.mjs';

const API = 'http://127.0.0.1:8788';
const MOVER = 26;
const LIFT = [3547, 0, 4754];
const R = 8;
const OUT = 'logs/scans/works.json';
const REPORT = 'logs/scans/works.txt';
const maxScans = Number(process.argv[2]) || 200;

const key = (x, y, z) => `${x},${y},${z}`;
const unkey = (k) => k.split(',').map(Number);
const log = (msg) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);

async function call(route, body) {
  const res = await fetch(API + route, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error);
  return data;
}
async function finish(job) {
  while (job.state === 'queued' || job.state === 'running') job = await call('/wait', { computer: MOVER, job: job.id, timeout: 120 });
  return job;
}
const text = (job) => (job.output || []).map((o) => o.text).join('');
async function worker(...args) {
  return finish(await call('/run', { computer: MOVER, program: 'worker', args: args.map(String), sync: false, timeout: 300 }));
}
async function evalLua(code) {
  const job = await finish(await call('/eval', { computer: MOVER, code, timeout: 60 }));
  if (job.state !== 'ok') throw new Error(job.error || 'eval failed');
  return job.result;
}

const cells = volume();
const data = fs.existsSync(OUT) ? JSON.parse(fs.readFileSync(OUT, 'utf8')) : { solid: {}, seen: [] };
const solid = new Map(Object.entries(data.solid));
const seen = data.seen;

const inSeen = (x, y, z) => seen.some(([cx, cy, cz]) => Math.abs(x - cx) <= R && Math.abs(y - cy) <= R && Math.abs(z - cz) <= R);
const isAir = (x, y, z) => inSeen(x, y, z) && !solid.has(key(x, y, z));

async function where() {
  const out = text(await worker('at'));
  const m = out.match(/At (-?\d+) (-?\d+) (-?\d+)/);
  if (!m) throw new Error('worker at: ' + out);
  return [m[1] - LIFT[0], m[2] - LIFT[1], m[3] - LIFT[2]];
}

async function scan(at) {
  const job = await worker('scan');
  if (job.state !== 'ok') throw new Error('scan: ' + (job.error || text(job)));
  const raw = await evalLua('local h=fs.open("/scan.txt","r") local s=h.readAll() h.close() return s');
  const body = typeof raw === 'string' ? raw : String(raw);
  // Forget what this cube held before: blocks come and go.
  for (const k of [...solid.keys()]) {
    const [x, y, z] = unkey(k);
    if (Math.abs(x - at[0]) <= R && Math.abs(y - at[1]) <= R && Math.abs(z - at[2]) <= R) solid.delete(k);
  }
  let n = 0;
  for (const line of body.split(/\\?\n/)) {
    const m = line.match(/(-?\d+) (-?\d+) (-?\d+) (\S+)/);
    if (!m) continue;
    solid.set(key(m[1] - LIFT[0], m[2] - LIFT[1], m[3] - LIFT[2]), m[4]);
    n++;
  }
  seen.push(at);
  fs.writeFileSync(OUT, JSON.stringify({ solid: Object.fromEntries(solid), seen }));
  return n;
}

// Cells of the volume no scan has covered yet.
function unseen() {
  const out = [];
  for (const k of cells) {
    const [x, y, z] = unkey(k);
    if (!inSeen(x, y, z)) out.push([x, y, z]);
  }
  return out;
}

// Breadth-first through known air from `from`: distance and parent per cell.
function reach(from) {
  const dist = new Map([[key(...from), 0]]);
  const parent = new Map();
  const queue = [from];
  const steps = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
  for (let i = 0; i < queue.length; i++) {
    const [x, y, z] = queue[i];
    const d = dist.get(key(x, y, z));
    for (const [dx, dy, dz] of steps) {
      const n = [x + dx, y + dy, z + dz];
      const k = key(...n);
      if (dist.has(k) || !isAir(...n)) continue;
      dist.set(k, d + 1);
      parent.set(k, key(x, y, z));
      queue.push(n);
    }
  }
  return { dist, parent };
}

// The reachable cell whose scan would show the most unseen volume, with a
// little pull toward near ones. Candidates: reachable cells on a 2-grid.
function choose(from) {
  const todo = unseen();
  if (todo.length === 0) return null;
  const { dist, parent } = reach(from);
  // Unseen cells in a box, by 3D prefix sums: a count per candidate in O(1).
  let lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
  for (const c of todo) for (let i = 0; i < 3; i++) { lo[i] = Math.min(lo[i], c[i]); hi[i] = Math.max(hi[i], c[i]); }
  const n = [hi[0] - lo[0] + 2, hi[1] - lo[1] + 2, hi[2] - lo[2] + 2];
  const sum = new Int32Array(n[0] * n[1] * n[2]);
  const at = (x, y, z) => (x * n[1] + y) * n[2] + z;
  for (const c of todo) sum[at(c[0] - lo[0] + 1, c[1] - lo[1] + 1, c[2] - lo[2] + 1)]++;
  for (let x = 1; x < n[0]; x++) for (let y = 1; y < n[1]; y++) for (let z = 1; z < n[2]; z++) {
    sum[at(x, y, z)] += sum[at(x - 1, y, z)] + sum[at(x, y - 1, z)] + sum[at(x, y, z - 1)]
      - sum[at(x - 1, y - 1, z)] - sum[at(x - 1, y, z - 1)] - sum[at(x, y - 1, z - 1)] + sum[at(x - 1, y - 1, z - 1)];
  }
  const clamp = (v, i) => Math.max(0, Math.min(n[i] - 1, v));
  const box = (x, y, z) => {
    const x0 = clamp(x - R - lo[0], 0), x1 = clamp(x + R - lo[0] + 1, 0);
    const y0 = clamp(y - R - lo[1], 1), y1 = clamp(y + R - lo[1] + 1, 1);
    const z0 = clamp(z - R - lo[2], 2), z1 = clamp(z + R - lo[2] + 1, 2);
    return sum[at(x1, y1, z1)] - sum[at(x0, y1, z1)] - sum[at(x1, y0, z1)] - sum[at(x1, y1, z0)]
      + sum[at(x0, y0, z1)] + sum[at(x0, y1, z0)] + sum[at(x1, y0, z0)] - sum[at(x0, y0, z0)];
  };
  let best = null;
  for (const [k, d] of dist) {
    const [x, y, z] = unkey(k);
    if ((x & 1) || (y & 1) || (z & 1)) continue;
    const gain = box(x, y, z);
    if (gain === 0) continue;
    const score = gain - d * 4;
    if (!best || score > best.score) best = { at: [x, y, z], gain, d, score };
  }
  if (!best) return { left: todo.length };
  const path = [];
  for (let k = key(...best.at); k; k = parent.get(k)) path.unshift(unkey(k));
  return { ...best, path, left: todo.length };
}

// Straight legs of a cell path.
function legs(path) {
  const out = [];
  for (let i = 1; i < path.length; i++) {
    const a = path[i - 1], b = path[i];
    const dir = [b[0] - a[0], b[1] - a[1], b[2] - a[2]].join();
    if (out.length && out[out.length - 1].dir === dir) out[out.length - 1].to = b;
    else out.push({ dir, to: b });
  }
  return out;
}

function report() {
  const byName = {}, byLayer = {};
  let left = 0, notSeen = 0;
  for (const k of cells) {
    const [x, y, z] = unkey(k);
    if (!inSeen(x, y, z)) { notSeen++; continue; }
    const name = solid.get(k);
    if (!name) continue;
    left++;
    byName[name] = (byName[name] || 0) + 1;
    byLayer[y] = (byLayer[y] || 0) + 1;
  }
  const lines = [`Volume ${cells.size} cells, ${notSeen} not seen, ${left} still standing (${seen.length} scans)`, '', 'By block:'];
  for (const [n, c] of Object.entries(byName).sort((a, b) => b[1] - a[1])) lines.push(`  ${c} ${n}`);
  lines.push('', 'By layer (site y):');
  for (const y of Object.keys(byLayer).map(Number).sort((a, b) => a - b)) lines.push(`  y ${y}: ${byLayer[y]}`);
  fs.writeFileSync(REPORT, lines.join('\n') + '\n');
  return lines[0];
}

let here = await where();
// node bridge/mapworks.js goto x y z [scan]: walk the Mover to a world cell
// through air the map knows, as near as it can get; scan there if asked.
if (process.argv[2] === 'goto') {
  const to = [process.argv[3] - LIFT[0], process.argv[4] - LIFT[1], process.argv[5] - LIFT[2]];
  const { dist, parent } = reach(here);
  let best = null;
  for (const [k] of dist) {
    const c = unkey(k);
    const d = Math.abs(c[0] - to[0]) + Math.abs(c[1] - to[1]) + Math.abs(c[2] - to[2]);
    if (!best || d < best.d) best = { at: c, d };
  }
  const path = [];
  for (let k = key(...best.at); k; k = parent.get(k)) path.unshift(unkey(k));
  for (const leg of legs(path)) {
    const job = await worker('go', leg.to[0] + LIFT[0], leg.to[1] + LIFT[1], leg.to[2] + LIFT[2]);
    if (job.state !== 'ok') { log('stopped: ' + (job.error || text(job)).split('\n')[0]); break; }
  }
  here = await where();
  log(`at site ${here.join(' ')} (${best.d} from the target by the map)`);
  if (process.argv[6] === 'scan') log(`scan: ${await scan(here)} blocks`);
  process.exit(0);
}
// node bridge/mapworks.js clear: the Mover digs out what the excavators left
// standing in the volume: loose rock only (their plugs and fill), and only
// cells with no water, lava or anything else unknown beside them. Nearest
// first, standing in known air next to each one.
if (process.argv[2] === 'clear') {
  const ROCK = /^minecraft:(cobbled_deepslate|cobblestone|diorite|calcite|deepslate|tuff|stone|granite|andesite)$/;
  const SIDES = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
  const wet = (x, y, z) => SIDES.some(([dx, dy, dz]) => /water|lava|stella|arcanum/i.test(solid.get(key(x + dx, y + dy, z + dz)) || ''));
  let dug = 0, skipped = 0;
  for (;;) {
    const { dist, parent } = reach(here);
    let best = null;
    for (const k of cells) {
      const name = solid.get(k);
      if (!name || !ROCK.test(name)) continue;
      const [x, y, z] = unkey(k);
      if (wet(x, y, z)) continue;
      for (const [dx, dy, dz] of SIDES) {
        const d = dist.get(key(x + dx, y + dy, z + dz));
        if (d != null && (!best || d < best.d)) best = { cell: [x, y, z], from: [x + dx, y + dy, z + dz], d };
      }
    }
    if (!best) break;
    const path = [];
    for (let k = key(...best.from); k; k = parent.get(k)) path.unshift(unkey(k));
    let ok = true;
    for (const leg of legs(path)) {
      const job = await worker('go', leg.to[0] + LIFT[0], leg.to[1] + LIFT[1], leg.to[2] + LIFT[2]);
      if (job.state !== 'ok') { log('stopped: ' + (job.error || text(job)).split('\n')[0]); ok = false; break; }
    }
    if (ok) {
      const job = await worker('go', best.cell[0] + LIFT[0], best.cell[1] + LIFT[1], best.cell[2] + LIFT[2], 'dig');
      ok = job.state === 'ok';
      if (!ok) log('dig failed: ' + (job.error || text(job)).split('\n')[0]);
    }
    here = await where();
    if (ok) { solid.delete(key(...best.cell)); dug++; } else {
      // Don't try this one again this run; the next scan puts it back.
      solid.set(key(...best.cell), 'skipped:' + solid.get(key(...best.cell)));
      skipped++;
    }
    if ((dug + skipped) % 10 === 0) log(`${dug} dug, ${skipped} skipped, at ${here.join(' ')}`);
  }
  fs.writeFileSync(OUT, JSON.stringify({ solid: Object.fromEntries(solid), seen }));
  log(`Cleared ${dug}, skipped ${skipped}`);
  log(report());
  process.exit(0);
}
log(`Mover at site ${here.join(' ')}`);
if (!inSeen(...here)) log(`first scan: ${await scan(here)} blocks`);
for (let i = 0; i < maxScans; i++) {
  const next = choose(here);
  if (!next) { log('Everything in the volume has been seen'); break; }
  if (!next.at) { log(`${next.left} cells can't be seen from anywhere it can reach`); break; }
  log(`to ${next.at.join(' ')} (${next.d} steps) for ${next.gain} of ${next.left} unseen cells`);
  let ok = true;
  for (const leg of legs(next.path)) {
    const w = [leg.to[0] + LIFT[0], leg.to[1] + LIFT[1], leg.to[2] + LIFT[2]];
    const job = await worker('go', ...w);
    if (job.state !== 'ok') {
      log(`stopped on the way: ${(job.error || text(job)).split('\n')[0]}`);
      ok = false;
      break;
    }
  }
  here = await where();
  // Wherever it got to, look: a blocked leg means the map there is stale.
  log(`scan at ${here.join(' ')}: ${await scan(here)} blocks${ok ? '' : ' (after a stop)'}`);
  log(report());
}
log(report());
