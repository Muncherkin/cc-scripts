#!/usr/bin/env node
// The Mover (#26) scans up the service shaft and writes every solid block it
// sees to logs/scans/shaft.json ({ solid: { "x,y,z": name }, seen: [[x,y,z]] },
// world coordinates). It starts and ends at the shaft's foot.
//
//   node bridge/shaftscan.js [y ...]     heights to scan at (default 18 34 50 66)

import fs from 'node:fs';

const API = 'http://127.0.0.1:8788';
const MOVER = 26;
const SHAFT = [3550, 4754], FOOT = 8;
const ys = process.argv.slice(2).map(Number);
if (!ys.length) ys.push(18, 34, 50, 66);

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
const worker = async (...args) => finish(await call('/run', { computer: MOVER, program: 'worker', args: args.map(String), sync: false, timeout: 300 }));

const out = { solid: {}, seen: [] };
for (const y of ys) {
  const go = await worker('go', SHAFT[0], y, SHAFT[1]);
  if (go.state !== 'ok') { console.log('stopped: ' + (go.error || text(go)).split('\n')[0]); break; }
  const scan = await worker('scan');
  if (scan.state !== 'ok') { console.log('scan failed at ' + y); break; }
  const job = await finish(await call('/eval', { computer: MOVER, code: 'local h=fs.open("/scan.txt","r") local out={} for line in h.readLine do local x,_,z=line:match("^(-?%d+) (-?%d+) (-?%d+)") if x and math.abs(tonumber(x)-3550)<=5 and math.abs(tonumber(z)-4754)<=5 then out[#out+1]=line end end h.close() return table.concat(out,";")', timeout: 60 }));
  let n = 0;
  for (const m of String(job.result).matchAll(/(-?\d+) (-?\d+) (-?\d+) ([^\s;"]+)/g)) {
    out.solid[`${m[1]},${m[2]},${m[3]}`] = m[4].replace(/\\$/, '');
    n++;
  }
  out.seen.push([SHAFT[0], y, SHAFT[1]]);
  console.log(`y ${y}: ${n} blocks`);
}
fs.writeFileSync('logs/scans/shaft.json', JSON.stringify(out));
const back = await worker('go', SHAFT[0], FOOT, SHAFT[1]);
console.log(text(back).trim());
