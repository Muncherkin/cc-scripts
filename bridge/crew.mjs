#!/usr/bin/env node
// Queues a crew of builders, one a structure (or a stripe of a big one), each
// born carrying its chests, blocks and coal (programs/buildsite.lua). No
// Mover trips: what doesn't fit in a turtle's pockets is listed at the end.
//
//   node bridge/crew.mjs <id|n>[:stripes] ... [plan]
//     core                 the whole structure, one turtle
//     fields:12            the Engine Hall in 12 stripes (rows of z), 12 turtles
//     plan                 only say what it would queue
//
// Homes: the blueprint's own if it's free; else (and for stripes) an open
// cell inside the box that the map says a turtle can walk to. Building is
// in plain Factory Blocks; the builder leaves standing whatever isn't rock.

import fs from 'node:fs';
import { SITE } from '../design/structures.mjs';

const API = 'http://127.0.0.1:8788';
const FACTORY = 4;
const LIFT = [3547, 0, 4754];
const R = 8;
const BIRTH = [22, -13, 9];
const PLAIN = 'factory_blocks:factory';
const POCKETS = 13; // stacks of load beside the chests and the birth fuel

const key = (x, y, z) => `${x},${y},${z}`;
const unkey = (k) => k.split(',').map(Number);
const log = (msg) => console.log(msg);

async function call(route, body) {
  const res = await fetch(API + route, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error);
  return data;
}
async function factory(...args) {
  let job = await call('/run', { computer: FACTORY, program: 'factory', args: args.map(String), sync: false, timeout: 120 });
  while (job.state === 'queued' || job.state === 'running') job = await call('/wait', { computer: FACTORY, job: job.id, timeout: 120 });
  return (job.output || []).map((o) => o.text).join('');
}

// The map ---------------------------------------------------------------------
const data = JSON.parse(fs.readFileSync('logs/scans/works.json', 'utf8'));
const centres = new Set(data.seen.map((s) => s.join(',')));
const solid = new Map();
for (const [k, n] of Object.entries(data.solid)) {
  if (centres.has(k) && /turtle/.test(n)) continue;
  solid.set(k, n);
}
const seenGrid = new Set();
const inSeen = (x, y, z) => data.seen.some(([cx, cy, cz]) => Math.abs(x - cx) <= R && Math.abs(y - cy) <= R && Math.abs(z - cz) <= R);
const isAir = (x, y, z) => !solid.has(key(x, y, z)) && inSeen(x, y, z);
const ROCK = /^minecraft:(deepslate|stone|tuff|cobblestone|cobbled_deepslate|diorite|granite|andesite|calcite|dirt|gravel|clay)$|_ore/;
const STEPS = [[1, 0, 0, 'e'], [-1, 0, 0, 'w'], [0, 1, 0, 'u'], [0, -1, 0, 'd'], [0, 0, 1, 's'], [0, 0, -1, 'n']];

// Breadth-first from the birth spot through known air: parents of every cell.
const parent = new Map([[key(...BIRTH), null]]);
{
  const queue = [BIRTH];
  for (let i = 0; i < queue.length; i++) {
    const c = queue[i];
    for (const [dx, dy, dz] of STEPS) {
      const n = [c[0] + dx, c[1] + dy, c[2] + dz];
      const k = key(...n);
      if (parent.has(k) || !isAir(...n)) continue;
      parent.set(k, key(...c));
      queue.push(n);
    }
  }
}
function routeTo(cell) {
  if (!parent.has(key(...cell))) return null;
  const cells = [];
  for (let k = key(...cell); k; k = parent.get(k)) cells.unshift(unkey(k));
  let out = '', n = 0, last = null;
  for (let i = 1; i < cells.length; i++) {
    const a = cells[i - 1], b = cells[i];
    const op = STEPS.find(([dx, dy, dz]) => dx === b[0] - a[0] && dy === b[1] - a[1] && dz === b[2] - a[2])[3];
    if (op === last) n++; else { if (last) out += last + n; last = op; n = 1; }
  }
  if (last) out += last + n;
  return { text: out, steps: cells.length - 1 };
}

// Blueprints ------------------------------------------------------------------
function blueprint(id) {
  const src = fs.readFileSync(`programs/blueprints/${id}.lua`, 'utf8');
  const sz = src.match(/size = \{ x = (\d+), y = (\d+), z = (\d+) \}/).slice(1).map(Number);
  const hm = src.match(/home = \{ x = (-?\d+), y = (-?\d+), z = (-?\d+), face = "(\w)" \}/);
  const palette = {};
  const pal = src.slice(src.indexOf('palette = {'), src.indexOf('layers = {'));
  for (const m of pal.matchAll(/(?:\["(.)"\]|(\w))\s*=\s*"([^"]+)"/g)) palette[m[1] || m[2]] = m[3];
  const rows = [...src.slice(src.indexOf('layers = {')).matchAll(/"([^"\n]*)"/g)].map((m) => m[1]);
  const layers = [];
  for (let y = 0; y < sz[1]; y++) layers.push(rows.slice(y * sz[2], (y + 1) * sz[2]));
  return { id, size: sz, home: { x: +hm[1], y: +hm[2], z: +hm[3], face: hm[4] }, palette, layers };
}
const itemOf = (id) => (id.startsWith('factory_blocks:') ? PLAIN : id === 'create:andesite_bars' || id === 'minecraft:air' ? null : id);
const isOpen = (ch) => ch === '.' || ch === 'P';

function countsOf(bp, z0, z1) {
  const need = {};
  for (let y = 0; y < bp.size[1]; y++) for (let z = z0; z <= z1; z++) for (const ch of bp.layers[y][z]) {
    const item = bp.palette[ch] && itemOf(bp.palette[ch]);
    if (item) need[item] = (need[item] || 0) + 1;
  }
  return need;
}

// A home for the builder: the cell it stands in, with room for a chest under
// and over it, that a newborn can walk to.
const taken = new Set();
function homeFor(bp, at, z0, z1, own) {
  const ok = (bx, by, bz) => {
    const H = [at[0] + bx, at[1] + by, at[2] + bz];
    const S = [H[0], H[1] - 1, H[2]], T = [H[0], H[1] + 1, H[2]];
    if (taken.has(key(...H)) || !parent.has(key(...H))) return null;
    // Not in the fuel station's lanes: the column over the birth spot and the cells beside it.
    if (Math.abs(H[0] - BIRTH[0]) <= 1 && Math.abs(H[2] - BIRTH[2]) <= 2) return null;
    const free = (c) => isAir(...c) || ROCK.test(solid.get(key(...c)) || '');
    if (!free(S) || !free(T)) return null;
    return routeTo(H);
  };
  if (own) {
    const r = ok(bp.home.x, bp.home.y, bp.home.z);
    if (r) return { b: [bp.home.x, bp.home.y, bp.home.z], face: bp.home.face, route: r, own: true };
  }
  // Inside the box: an open cell, low, nearest by the way there.
  let best = null;
  for (let y = 1; y < Math.min(bp.size[1] - 1, 4); y++) for (let z = z0; z <= z1; z++) for (let x = 0; x < bp.size[0]; x++) {
    if (!isOpen(bp.layers[y][z][x]) || !isOpen(bp.layers[y + 1][z][x])) continue;
    const r = ok(x, y, z);
    if (r && (!best || r.steps < best.route.steps)) best = { b: [x, y, z], face: 's', route: r };
  }
  return best;
}

// The crew --------------------------------------------------------------------
const planOnly = process.argv.includes('plan');
const picks = process.argv.slice(2).filter((a) => a !== 'plan');
const orders = [], later = [];
for (const pick of picks) {
  const [name, stripesArg, onlyArg] = pick.split(':');
  const only = onlyArg ? onlyArg.split(',').map(Number) : null; // which stripes (from 0), to queue some again
  const place = /^\d+$/.test(name) ? SITE[name - 1] : SITE.find((s) => s.id === name || s.name === name);
  if (!place) { log(`No structure ${name}: ${SITE.map((s, i) => `${i + 1} ${s.name || s.id}`).join(', ')}`); continue; }
  const bp = blueprint(place.id);
  const label = place.name || place.id;
  // Stripes of rows with about the same number of blocks.
  const stripes = [];
  const n = Number(stripesArg) || 1;
  if (n === 1) stripes.push([0, bp.size[2] - 1]);
  else {
    const per = [];
    let total = 0;
    for (let z = 0; z < bp.size[2]; z++) { const c = Object.values(countsOf(bp, z, z)).reduce((a, b) => a + b, 0); per.push(c); total += c; }
    let z0 = 0, acc = 0;
    for (let z = 0; z < bp.size[2]; z++) {
      acc += per[z];
      const left = n - stripes.length;
      if (acc >= total / n && left > 1 && z > 0 && z < bp.size[2] - 2 || z === bp.size[2] - 1) { stripes.push([z0, z]); z0 = z + 1; acc = 0; }
    }
  }
  for (const [index, [z0, z1]] of stripes.entries()) {
    if (only && !only.includes(index)) continue;
    const whole = n === 1;
    const home = homeFor(bp, place.at, z0, z1, whole);
    const tag = whole ? label : `${label} rows ${z0}-${z1}`;
    if (!home) { log(`${tag}: no home cell a turtle can walk to on the map: skipped`); continue; }
    taken.add(key(place.at[0] + home.b[0], place.at[1] + home.b[1], place.at[2] + home.b[2]));
    const need = countsOf(bp, z0, z1);
    // Pockets: plain blocks first, then coal, then the rest.
    const kit = [];
    let slots = POCKETS;
    const take = (item, want) => {
      const got = Math.min(want, slots * 64);
      if (got > 0) { kit.push(`${item}=${got}`); slots -= Math.ceil(got / 64); }
      if (want > got) later.push(`${tag}: ${want - got} ${item}`);
    };
    if (need[PLAIN]) take(PLAIN, need[PLAIN]);
    if (slots > 0) take('minecraft:coal', 64);
    for (const [item, c] of Object.entries(need)) if (item !== PLAIN) take(item, c);
    const args = ['order', 'birth', 'builder', bp.id, home.route.text, home.face, 'plain'];
    if (!whole) args.push(`z=${z0}-${z1}`);
    if (!home.own) args.push(`home=${home.b.join(',')},${home.face}`);
    args.push(...kit);
    log(`${tag}: home ${home.b.join(',')}${home.own ? '' : ' (inside)'}, ${home.route.steps} steps, carries ${kit.join(' ')}`);
    orders.push(args);
  }
}
if (later.length) log('\nNot in their pockets (to bring later):\n  ' + later.join('\n  '));
if (planOnly) process.exit(0);
for (const args of orders) log((await factory(...args)).trim());
