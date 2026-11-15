#!/usr/bin/env node
// Walks a stranded builder to a cell through air the Mover's scans have
// seen (logs/scans/works.json), with lib/nav on its own state file, so its
// position stays right. Its job is stopped first and started again after.
// Fix its position first if it's wrong (see "Finding a lost turtle" in
// CLAUDE.md): this trusts what the builder has in /.builder.
//
//   node bridge/rescue.mjs <id> home|bay|<site x,y,z> [plan]
//     home: its home cell; bay: the top of the column over the bay
//     plan: only print the path

import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const [id, where, mode] = process.argv.slice(2);
if (!id || !where) { console.log('Usage: node bridge/rescue.mjs <id> home|bay|<x,y,z> [plan]'); process.exit(1); }
const cli = (...args) => execFileSync('node', ['bridge/cli.js', ...args], { encoding: 'utf8', timeout: 600000 });
const BAY = [22, -13, 9];
const D = { n: [0, -1], e: [1, 0], s: [0, 1], w: [-1, 0] };
const IDX = { n: 0, e: 1, s: 2, w: 3 };
const WORLD = ['n', 'e', 's', 'w'];
const RIGHT = { s: 'w', n: 'e', e: 's', w: 'n' };
const key = (p) => p.join(',');

function evalOn(code) {
  const r = cli('eval', code, '--c', String(id), '--timeout', '590');
  const m = r.match(/=> "(.*)"\s*\n/);
  if (!m) throw new Error(r.trim().split('\n').slice(-2).join(' '));
  return JSON.parse('"' + m[1] + '"');
}

// Where it is, in site coordinates, and its frame.
const st = JSON.parse(evalOn('local s=textutils.unserialise(fs.open("/.builder","r").readAll()) local b=textutils.unserialise(fs.open("/.buildsite","r").readAll()) return textutils.serialiseJSON({pos=s.pos,dir=s.dir,out=b.out,back=b.back,face=b.face})'));
let home = [...BAY];
for (const [, op, n] of st.out.matchAll(/([nsewud])(\d+)/g)) {
  const k = +n;
  if (op === 'u') home[1] += k; else if (op === 'd') home[1] -= k; else { home[0] += D[op][0] * k; home[2] += D[op][1] * k; }
}
const f = D[st.face], rt = D[RIGHT[st.face]];
const toSite = (p) => [home[0] + f[0] * p.z + rt[0] * p.x, home[1] + p.y, home[2] + f[1] * p.z + rt[1] * p.x];
const start = toSite(st.pos);
let goal;
if (where === 'home') goal = home;
else if (where === 'bay') goal = [BAY[0], 6, BAY[2]];
else goal = where.split(',').map(Number);
console.log(`#${id} at site ${key(start)} (home ${key(home)}, facing in ${st.face}); to ${key(goal)}`);

// Air the scans have seen: not solid (turtles move, so they're not walls).
const data = JSON.parse(fs.readFileSync('logs/scans/works.json', 'utf8'));
const R = 8;
const seen = (x, y, z) => data.seen.some(([cx, cy, cz]) => Math.abs(x - cx) <= R && Math.abs(y - cy) <= R && Math.abs(z - cz) <= R);
const air = (p) => { const n = data.solid[key(p)]; return (!n || /^computercraft:turtle/.test(n)) && seen(...p); };

const from = new Map([[key(start), null]]);
const queue = [start];
let found = key(start) === key(goal);
while (queue.length && !found) {
  const c = queue.shift();
  for (const d of [[1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1], [0, 1, 0], [0, -1, 0]]) {
    const n = [c[0] + d[0], c[1] + d[1], c[2] + d[2]];
    const k = key(n);
    if (from.has(k) || !(k === key(goal) || air(n))) continue;
    from.set(k, key(c));
    if (k === key(goal)) { found = true; break; }
    queue.push(n);
  }
}
if (!found) { console.log('No way through seen air: scan round it first (bridge/mapworks.js goto ... scan)'); process.exit(1); }
const path = [];
for (let k = key(goal); k !== key(start); k = from.get(k)) path.unshift(k.split(',').map(Number));

// Steps as nav ops: u, d, or the local direction to face and go forward.
const ops = [];
let prev = start;
for (const p of path) {
  const d = [p[0] - prev[0], p[1] - prev[1], p[2] - prev[2]];
  if (d[1] > 0) ops.push('u'); else if (d[1] < 0) ops.push('d');
  else {
    const w = WORLD.find((x) => D[x][0] === d[0] && D[x][1] === d[2]);
    ops.push(String((IDX[w] - IDX[st.face] + 4) % 4));
  }
  prev = p;
}
console.log(`${path.length} steps: ${ops.join('')}`);
if (mode === 'plan') process.exit(0);

cli('stop', '--c', String(id));
const lua = `local nav=require("lib.nav") local saved=require("lib.state")
local s=saved.load("/.builder") nav.init(s, function() saved.save("/.builder", s) end) nav.recover()
local ops="${ops.join('')}" local done=0
for i=1,#ops do local o=ops:sub(i,i) local ok,why
  if o=="u" then ok,why=nav.move("up") elseif o=="d" then ok,why=nav.move("down") else nav.face(tonumber(o)) ok,why=nav.move("forward") end
  if not ok then local p=nav.pos() return ("stopped after %d of %d steps at %d,%d,%d: %s"):format(done,#ops,p.x,p.y,p.z,tostring(why)) end
  done=i end
local p=nav.pos() return ("there: %d,%d,%d after %d steps"):format(p.x,p.y,p.z,done)`;
console.log(evalOn(lua.replace(/\n/g, ' ')));
console.log(cli('autorun', 'buildsite', '--start', '--c', String(id)).trim());
