#!/usr/bin/env node
// Watches the fleet for a while and ends early when something needs a look:
// an autorun job that stopped with an error, or a turtle whose fuel hasn't
// moved for too long while its program should be working.
//
//   node bridge/watch.js [minutes] [idleMinutes]
//
// Prints a line a minute per change, and at the end why it stopped.

import fs from 'node:fs';

const API = 'http://127.0.0.1:8788';
const minutes = Number(process.argv[2]) || 30;
const idleMin = Number(process.argv[3]) || 12;
const WORKERS = { 8: 'Juniper', 10: 'Geode' };
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const log = (msg) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);

const get = async (route) => (await fetch(API + route)).json();
const started = Date.now();
const seenErrors = new Set(fs.readdirSync('logs/jobs').filter((f) => f.startsWith('autorun')));
const fuelAt = {};
let lastLine = {};

for (;;) {
  let computers = [];
  try { computers = await get('/computers'); } catch (e) { log('bridge: ' + e.message); }
  const list = Array.isArray(computers) ? computers : computers.computers || [];
  const online = new Set();
  for (const c of list) {
    const id = c.id ?? c.status?.id;
    const fuel = c.fuel ?? c.status?.fuel;
    online.add(id);
    if (!WORKERS[id]) continue;
    const f = fuelAt[id];
    if (!f || f.fuel !== fuel) fuelAt[id] = { fuel, at: Date.now() };
  }
  for (const id of Object.keys(WORKERS)) {
    if (list.length && !online.has(Number(id))) { log(`STOP: ${WORKERS[id]} is offline`); process.exit(0); }
    const f = fuelAt[id];
    if (f && Date.now() - f.at > idleMin * 60000) { log(`STOP: ${WORKERS[id]} hasn't moved for ${idleMin} min (fuel ${f.fuel})`); process.exit(0); }
  }
  // Finished autorun jobs leave a record; a new one with an error is news.
  for (const f of fs.readdirSync('logs/jobs').filter((x) => x.startsWith('autorun'))) {
    if (seenErrors.has(f)) continue;
    seenErrors.add(f);
    try {
      const j = JSON.parse(fs.readFileSync('logs/jobs/' + f, 'utf8'));
      if (j.state === 'error' || j.state === 'lost') {
        log(`STOP: #${j.computer} ${j.program} ${j.state}: ${(j.error || '').split('\n')[0]}`);
        process.exit(0);
      }
      log(`#${j.computer} ${j.program} finished: ${j.state}`);
    } catch { /* being written */ }
  }
  const line = Object.entries(WORKERS).map(([id, n]) => `${n} ${fuelAt[id]?.fuel ?? '?'}`).join(', ');
  if (line !== lastLine.text) { log(line); lastLine.text = line; }
  if (Date.now() - started > minutes * 60000) { log('Time is up, all quiet'); process.exit(0); }
  await sleep(60);
}
