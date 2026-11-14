#!/usr/bin/env node
// Queues a crew of builders, one a structure or a stripe of a big one. Each
// is born at the factory's loading bay with its whole bill of materials as
// its allowance there (programs/lib/bay.lua): the factory loads it, it walks
// out, builds, and comes back to the bay by itself whenever it runs out
// (programs/buildsite.lua, programs/builder.lua). No chests, no hauling.
//
//   node bridge/crew.mjs <id|name|n>[:stripes[:which]] ... [plan]
//     core                 the whole structure, one turtle
//     fields:12            the Engine Hall in stripes (rows of z), a turtle each
//     fields:12:4,5,6      only those stripes (from 0)
//     plan                 only say what it would queue
//
// Traffic: one-way lanes over the hall. Out of the bay north and up to y 7,
// across at y 7, down onto the home cell; home to the bay up to y 6, across
// at y 6, and down the column over the bay. Everything leaving is at 7 and
// everything arriving at 6, so no two turtles ever meet head on. A home is
// the blueprint's own cell if those lanes reach it, else an open cell
// inside the box with clear air above it up to the lanes.
// Building is in plain Factory Blocks; andesite bars are left out; the
// builder leaves standing whatever isn't rock.

import fs from 'node:fs';
import { SITE } from '../design/structures.mjs';

const API = 'http://127.0.0.1:8788';
const FACTORY = 4;
const R = 8;
const BAY = [22, -13, 9];   // the birth spot, site coordinates
const OUT_Y = 7, IN_Y = 6;  // lane heights (world y: the lift's bottom is 0)
const PLAIN = 'factory_blocks:factory';
const FUEL = 160;           // coal on a builder's allowance

const key = (x, y, z) => `${x},${y},${z}`;
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

// The map: what the Mover's scans saw (logs/scans/works.json, site coordinates).
const data = JSON.parse(fs.readFileSync('logs/scans/works.json', 'utf8'));
const centres = new Set(data.seen.map((s) => s.join(',')));
const solid = new Map();
for (const [k, n] of Object.entries(data.solid)) {
  if (/^computercraft:turtle/.test(n)) continue; // turtles move: where one stood during a scan is not a wall
  solid.set(k, n);
}
const inSeen = (x, y, z) => data.seen.some(([cx, cy, cz]) => Math.abs(x - cx) <= R && Math.abs(y - cy) <= R && Math.abs(z - cz) <= R);
const isAir = (x, y, z) => !solid.has(key(x, y, z)) && inSeen(x, y, z);

// A straight leg from a to b along one axis: its route text, or null if a
// cell on it isn't air.
function leg(a, b) {
  const axis = [0, 1, 2].find((i) => a[i] !== b[i]);
  if (axis === undefined) return '';
  const step = Math.sign(b[axis] - a[axis]);
  const c = [...a];
  while (c[axis] !== b[axis]) {
    c[axis] += step;
    if (!isAir(...c)) return null;
  }
  const op = [['w', 'e'], ['d', 'u'], ['n', 's']][axis][step > 0 ? 1 : 0];
  return op + Math.abs(b[axis] - a[axis]);
}
function legs(points) {
  let out = '';
  for (let i = 1; i < points.length; i++) {
    const l = leg(points[i - 1], points[i]);
    if (l === null) return null;
    out += l;
  }
  return out;
}
// The two routes of a home cell H, or null if the lanes don't reach it.
function lanes(H) {
  if (H[1] >= IN_Y) return null;
  const [bx, by, bz] = BAY;
  const out = legs([BAY, [bx, by, bz - 1], [bx, OUT_Y, bz - 1], [H[0], OUT_Y, bz - 1], [H[0], OUT_Y, H[2]], H])
    || legs([BAY, [bx, by, bz - 1], [bx, OUT_Y, bz - 1], [bx, OUT_Y, H[2]], [H[0], OUT_Y, H[2]], H]);
  const back = legs([H, [H[0], IN_Y, H[2]], [H[0], IN_Y, bz], [bx, IN_Y, bz], BAY])
    || legs([H, [H[0], IN_Y, H[2]], [bx, IN_Y, H[2]], [bx, IN_Y, bz], BAY]);
  if (!out || !back) return null;
  return { out, back };
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

const taken = new Set();
function homeFor(bp, at, z0, z1, own) {
  const tryCell = (bx, by, bz) => {
    const H = [at[0] + bx, at[1] + by, at[2] + bz];
    if (taken.has(key(...H)) || !isAir(...H)) return null;
    // Clear of the bay's own columns.
    if (Math.abs(H[0] - BAY[0]) <= 1 && Math.abs(H[2] - BAY[2]) <= 2) return null;
    return lanes(H);
  };
  if (own) {
    const r = tryCell(bp.home.x, bp.home.y, bp.home.z);
    if (r) return { b: [bp.home.x, bp.home.y, bp.home.z], face: bp.home.face, routes: r, own: true };
  }
  let best = null;
  for (let y = 1; y < Math.min(bp.size[1] - 1, 4); y++) for (let z = z0; z <= z1; z++) for (let x = 0; x < bp.size[0]; x++) {
    if (!isOpen(bp.layers[y][z][x]) || !isOpen(bp.layers[y + 1][z][x])) continue;
    const r = tryCell(x, y, z);
    if (r && (!best || r.out.length + r.back.length < best.routes.out.length + best.routes.back.length)) best = { b: [x, y, z], face: 's', routes: r };
  }
  return best;
}

// The crew --------------------------------------------------------------------
const planOnly = process.argv.includes('plan');
const picks = process.argv.slice(2).filter((a) => a !== 'plan');
const orders = [];
for (const pick of picks) {
  const [name, stripesArg, onlyArg] = pick.split(':');
  const only = onlyArg ? onlyArg.split(',').map(Number) : null;
  const place = /^\d+$/.test(name) ? SITE[name - 1] : SITE.find((s) => s.id === name || s.name === name);
  if (!place) { log(`No structure ${name}: ${SITE.map((s, i) => `${i + 1} ${s.name || s.id}`).join(', ')}`); continue; }
  const bp = blueprint(place.id);
  const label = place.name || place.id;
  // Stripes of rows with about the same number of blocks; the end walls go
  // with their neighbours (a wall row has no open cell for a home).
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
    const tag = whole ? label : `${label} stripe ${index} (rows ${z0}-${z1})`;
    const home = homeFor(bp, place.at, z0, z1, whole);
    if (!home) { log(`${tag}: no home cell the lanes reach on the map: skipped`); continue; }
    taken.add(key(place.at[0] + home.b[0], place.at[1] + home.b[1], place.at[2] + home.b[2]));
    const need = countsOf(bp, z0, z1);
    const allow = Object.entries(need).map(([item, c]) => `${item}=${c}`);
    allow.push(`minecraft:coal=${FUEL}`);
    const args = ['order', 'birth', 'builder', bp.id, home.routes.out, home.routes.back, home.face, 'plain'];
    if (!whole) args.push(`z=${z0}-${z1}`);
    if (!home.own) args.push(`home=${home.b.join(',')},${home.face}`);
    args.push(...allow);
    log(`${tag}: home ${home.b.join(',')}${home.own ? '' : ' (inside)'}, out ${home.routes.out}, back ${home.routes.back}; ${Object.entries(need).map(([k, v]) => `${v} ${k.replace(/^\w+:/, '')}`).join(', ')}`);
    orders.push(args);
  }
}
if (planOnly) process.exit(0);
for (const args of orders) log((await factory(...args)).trim().slice(0, 100));
