#!/usr/bin/env node
// Builds one structure of the Clockworks with no hands, in plain Factory
// Blocks (every variant becomes the plain block; andesite bars are left out):
//
//   1 the factory makes what the structure needs (orders, kept in stock)
//   2 the Mover (#26) fetches it at the fuel station, by asking in its label,
//     sets a supply chest under the structure's home cell and a staging chest
//     over it, and fills the supply chest
//   3 the factory births a builder, which walks a route planned here to the
//     home cell and builds (programs/buildsite.lua, programs/builder.lua)
//
//   node bridge/build.js <n | id> [plan]     n: index in design SITE (1 = first)
//                                            plan: only say what it would do
//
// Paths go through cells the Mover's map (logs/scans/works.json, made by
// bridge/mapworks.js) knows to be air, so nothing is dug on the way.

import fs from 'node:fs';
import { SITE } from '../design/structures.mjs';

const API = 'http://127.0.0.1:8788';
const MOVER = 26, FACTORY = 4;
const LIFT = [3547, 0, 4754];
const R = 8;
const BIRTH = [22, -13, 9];          // the birth spot, site coordinates
const STATION_TOP = [22, 6, 9];      // the way in: down the column over it
const PARK = [8, 6, 8];              // where the Mover waits out of the way
const PLAIN = 'factory_blocks:factory';
const LOAD = 12 * 64;                // what the Mover carries a trip
const SHORT = { [PLAIN]: 'plain_block', 'computercraft:wired_modem_full': 'modem_block', 'computercraft:cable': 'cable',
  'minecraft:chest': 'chest', 'minecraft:dirt': 'dirt', 'computercraft:monitor_advanced': 'advanced_monitor',
  'computercraft:computer_advanced': 'advanced_computer', 'minecraft:coal': 'coal' };

const key = (x, y, z) => `${x},${y},${z}`;
const unkey = (k) => k.split(',').map(Number);
const log = (msg) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const W = (c) => [c[0] + LIFT[0], c[1] + LIFT[1], c[2] + LIFT[2]];

async function call(route, body) {
  const res = await fetch(API + route, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error);
  return data;
}
async function finish(job, computer) {
  while (job.state === 'queued' || job.state === 'running') job = await call('/wait', { computer, job: job.id, timeout: 120 });
  return job;
}
const text = (job) => (job.output || []).map((o) => o.text).join('');
async function run(computer, program, ...args) {
  return finish(await call('/run', { computer, program, args: args.map(String), sync: false, timeout: 900 }), computer);
}
async function worker(...args) {
  const job = await run(MOVER, 'worker', ...args);
  if (job.state !== 'ok') throw new Error(`worker ${args.join(' ')}: ${(job.error || text(job)).split('\n')[0]}`);
  return text(job).trim();
}
async function evalLua(computer, code) {
  const job = await finish(await call('/eval', { computer, code, timeout: 60 }), computer);
  if (job.state !== 'ok') throw new Error(job.error || 'eval failed');
  return job.result;
}

// The map -------------------------------------------------------------------
const data = JSON.parse(fs.readFileSync('logs/scans/works.json', 'utf8'));
const centres = new Set(data.seen.map((s) => s.join(',')));
const solid = new Map();
for (const [k, n] of Object.entries(data.solid)) {
  if (centres.has(k) && /turtle/.test(n)) continue; // the Mover itself, as it scanned
  solid.set(k, n);
}
const inSeen = (x, y, z) => data.seen.some(([cx, cy, cz]) => Math.abs(x - cx) <= R && Math.abs(y - cy) <= R && Math.abs(z - cz) <= R);
const isAir = (x, y, z) => inSeen(x, y, z) && !solid.has(key(x, y, z));
const STEPS = [[1, 0, 0, 'e'], [-1, 0, 0, 'w'], [0, 1, 0, 'u'], [0, -1, 0, 'd'], [0, 0, 1, 's'], [0, 0, -1, 'n']];

function path(from, to) {
  const parent = new Map([[key(...from), null]]);
  const queue = [from];
  for (let i = 0; i < queue.length; i++) {
    const c = queue[i];
    if (c[0] === to[0] && c[1] === to[1] && c[2] === to[2]) break;
    for (const [dx, dy, dz] of STEPS) {
      const n = [c[0] + dx, c[1] + dy, c[2] + dz];
      const k = key(...n);
      if (parent.has(k) || !isAir(...n)) continue;
      parent.set(k, key(...c));
      queue.push(n);
    }
  }
  if (!parent.has(key(...to))) return null;
  const out = [];
  for (let k = key(...to); k; k = parent.get(k)) out.unshift(unkey(k));
  return out;
}
function legs(cells) {
  const out = [];
  for (let i = 1; i < cells.length; i++) {
    const a = cells[i - 1], b = cells[i];
    const [, , , op] = STEPS.find(([dx, dy, dz]) => dx === b[0] - a[0] && dy === b[1] - a[1] && dz === b[2] - a[2]);
    if (out.length && out[out.length - 1].op === op) { out[out.length - 1].to = b; out[out.length - 1].n++; } else out.push({ op, to: b, n: 1 });
  }
  return out;
}

async function moverAt() {
  const m = (await worker('at')).match(/At (-?\d+) (-?\d+) (-?\d+)/);
  return [m[1] - LIFT[0], m[2] - LIFT[1], m[3] - LIFT[2]];
}
async function moverTo(to) {
  const from = await moverAt();
  const cells = path(from, to);
  if (!cells) throw new Error(`No way on the map from ${from} to ${to}`);
  for (const leg of legs(cells)) await worker('go', ...W(leg.to));
}

// The structure -------------------------------------------------------------
const pick = process.argv[2];
const planOnly = process.argv[3] === 'plan';
const place = /^\d+$/.test(pick || '') ? SITE[pick - 1] : SITE.find((s) => s.id === pick);
if (!place) {
  console.log('Structures: ' + SITE.map((s, i) => `${i + 1} ${s.id}${s.name ? ' (' + s.name + ')' : ''}`).join(', '));
  process.exit(1);
}
const src = fs.readFileSync(`programs/blueprints/${place.id}.lua`, 'utf8');
const hm = src.match(/home = \{ x = (-?\d+), y = (-?\d+), z = (-?\d+), face = "(\w)" \}/);
const sz = src.match(/size = \{ x = (\d+), y = (\d+), z = (\d+) \}/);
const H = [place.at[0] + Number(hm[1]), place.at[1] + Number(hm[2]), place.at[2] + Number(hm[3])];
const face = hm[4];
const S = [H[0], H[1] - 1, H[2]], T = [H[0], H[1] + 1, H[2]], H2 = [H[0], H[1] + 2, H[2]];
const bom = JSON.parse(fs.readFileSync('design/out/bom.json', 'utf8'))[place.id].counts;
const need = {};
for (const [id, n] of Object.entries(bom)) {
  if (id === 'create:andesite_bars') continue;
  const item = id.startsWith('factory_blocks:') ? PLAIN : id;
  need[item] = (need[item] || 0) + n;
}
need['minecraft:coal'] = 48;

// What stands inside the structure's box now, that isn't rock: the builder
// would dig it.
const foreign = {};
for (let x = 0; x < sz[1]; x++) for (let y = 0; y < sz[2]; y++) for (let z = 0; z < sz[3]; z++) {
  const n = solid.get(key(place.at[0] + x, place.at[1] + y, place.at[2] + z));
  if (n && !/^minecraft:(deepslate|stone|tuff|cobble|cobbled_deepslate|diorite|granite|andesite|calcite|dirt|gravel|torch|wall_torch)$/.test(n) && !/_ore$/.test(n)) {
    foreign[n] = (foreign[n] || 0) + 1;
  }
}

const route = path(BIRTH, H);
log(`${place.name || place.id}: home ${W(H).join(' ')} facing ${face}; supply chest at ${W(S).join(' ')}`);
log(`needs ${Object.entries(need).map(([k, v]) => `${v} ${k.replace(/^\w+:/, '')}`).join(', ')}`);
log(`in its box now: ${Object.keys(foreign).length ? JSON.stringify(foreign) : 'only rock and torches'}`);
log(`home is ${isAir(...H) ? 'air' : solid.get(key(...H)) || 'unseen'}, under it ${isAir(...S) ? 'air' : solid.get(key(...S)) || 'unseen'}, over it ${isAir(...T) ? 'air' : solid.get(key(...T)) || 'unseen'}, 2 over ${isAir(...H2) ? 'air' : solid.get(key(...H2)) || 'unseen'}`);
const routeText = route ? legs(route).map((l) => l.op + l.n).join('') : null;
log(`builder's route: ${routeText || 'NONE'} (${route ? route.length - 1 : 0} steps)`);
if (planOnly) process.exit(0);
if (Object.keys(foreign).length) { log('Not building: something of yours stands in the box'); process.exit(1); }
if (!route || !isAir(...H) || !isAir(...T) || !isAir(...H2)) { log('Not building: the home cell or the way to it is not clear on the map'); process.exit(1); }

// 1 The factory makes it ----------------------------------------------------
async function factory(...args) { return text(await run(FACTORY, 'factory', ...args)); }
const orderIds = [];
for (const [item, n] of Object.entries(need)) {
  if (item === 'minecraft:coal' || item === 'minecraft:dirt') continue;
  const m = (await factory('order', item, n, 'keep')).match(/Order (\d+)/);
  if (m) orderIds.push(m[1]);
}
await factory('order', 'minecraft:chest', 2, 'keep');
log(`ordered: ${orderIds.join(', ')}`);
for (let waited = 0; ; waited += 30) {
  const out = await factory('orders');
  const open = orderIds.filter((id) => !new RegExp(`#${id} [^\\n]*: done`).test(out));
  if (!open.length) break;
  if (waited % 300 === 0) log('waiting for the factory: ' + out.split('\n').filter((l) => open.some((id) => l.startsWith(`#${id} `))).join(' | '));
  if (waited > 3600) { log('The factory can\'t make it all: stopping'); process.exit(1); }
  await sleep(30);
}

// 2 The Mover stocks the site -------------------------------------------------
// Its pockets first: what it dug up earlier would end up in the supply chest.
await evalLua(MOVER, 'for s=1,16 do local d=turtle.getItemDetail(s) if d and not (d.name=="minecraft:coal" or d.name:find("geo_scanner")) then turtle.select(s) turtle.dropDown() end end turtle.select(1) return true');

async function fetchLoad(items) {
  await moverTo(STATION_TOP);
  await worker('go', ...W(BIRTH));
  for (const [item, n] of items) {
    const before = Number((await worker('have', item)).match(/Have (\d+)/)[1]);
    await worker('label', `Mover [need ${SHORT[item] || item} ${n}]`);
    const got = Number((await worker('have', item, before + n, 900)).match(/Have (\d+)/)[1]);
    await worker('label', 'Mover');
    log(`  ${got - before} of ${n} ${item}`);
    if (got - before < n) throw new Error(`The factory gave only ${got - before} of ${n} ${item}`);
  }
  // Off the station by its way out: north, then up.
  await worker('go', LIFT[0] + BIRTH[0], LIFT[1] + BIRTH[1], LIFT[2] + BIRTH[2] - 1);
  await worker('go', LIFT[0] + BIRTH[0], 7, LIFT[2] + BIRTH[2] - 1);
}

// Loads of at most LOAD items; the chests go with the first.
const todo = Object.entries(need).map(([item, n]) => [item, n]);
const loads = [];
let cur = [['minecraft:chest', 2]], room = LOAD - 64;
for (const [item, n] of todo) {
  let left = n;
  while (left > 0) {
    if (room < 64) { loads.push(cur); cur = []; room = LOAD; }
    const take = Math.min(left, Math.floor(room / 64) * 64);
    cur.push([item, take]);
    room -= Math.ceil(take / 64) * 64;
    left -= take;
  }
}
loads.push(cur);

for (let i = 0; i < loads.length; i++) {
  log(`load ${i + 1} of ${loads.length}`);
  await fetchLoad(loads[i]);
  if (i === 0) {
    await moverTo(H);
    if (!isAir(...S)) {
      await worker('go', ...W(S), 'dig');
      await worker('go', ...W(H));
      solid.delete(key(...S));
    }
    await worker('place', ...W(S), 'minecraft:chest');
    solid.set(key(...S), 'minecraft:chest');
    await moverTo(H2);
    await worker('place', ...W(T), 'minecraft:chest');
    solid.set(key(...T), 'minecraft:chest');
  }
  await moverTo(H);
  log('  ' + await worker('put', ...W(S)));
  // put keeps fuel back as the Mover's own: the builder's coal goes in by name.
  if (loads[i].some(([item]) => item === 'minecraft:coal')) log('  coal: ' + await worker('put', ...W(S), 'minecraft:coal'));
}
await moverTo(PARK);

// 3 The builder ---------------------------------------------------------------
const way = path(BIRTH, H);
const wayText = legs(way).map((l) => l.op + l.n).join('');
const born = await factory('order', 'birth', 'builder', place.id, wayText, face, 'plain');
log(born.trim() + ` (route ${wayText})`);
