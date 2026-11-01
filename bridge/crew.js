#!/usr/bin/env node
// Births turtles on the factory (#4), each as soon as it can: parts in
// stock and the birth spot free. Newborns go to work by themselves. When
// parts are missing it says so on the glasses, once, and keeps trying.
//
//   node bridge/crew.js [zone ...]      the excavator crew (default: zones 2 to 8)
//   node bridge/crew.js <job>           one turtle for that job, e.g. guard
//
// Leave it running in a terminal (npm run bridge must be running too).

const API = 'http://127.0.0.1:8788';
const FACTORY = 4;
const RETRY = 120; // seconds between tries

async function call(method, route, body) {
  const res = await fetch(API + route, { method, headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error);
  return data;
}
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const log = (msg) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);
const text = (job) => job.output.map((o) => o.text).join('');

async function birth(zone) {
  const args = typeof zone === 'number' ? ['birth', 'excavator', String(zone)] : ['birth', zone];
  let job = await call('POST', '/run', { computer: FACTORY, program: 'factory', args, sync: false, timeout: 400 });
  while (job.state === 'queued' || job.state === 'running') job = await call('POST', '/wait', { computer: FACTORY, job: job.id, timeout: 120 });
  return job;
}

const argv = process.argv.slice(2);
const zones = argv.length && isNaN(Number(argv[0])) ? [argv[0]] : argv.map(Number);
if (!zones.length) for (let z = 2; z <= 8; z++) zones.push(z);
let told = '';
for (const zone of zones) {
  for (;;) {
    let job;
    try {
      job = await birth(zone);
    } catch (e) {
      log(`zone ${zone}: ${e.message}; retrying`);
      await sleep(RETRY);
      continue;
    }
    if (job.state === 'ok' && job.result === 'true') {
      log(`${typeof zone === 'number' ? 'zone ' + zone : zone}: born`);
      break;
    }
    const why = (job.state === 'ok' ? text(job) : job.error ?? text(job)).trim().replace(/\s+/g, ' ');
    log(`${typeof zone === 'number' ? 'zone ' + zone : zone}: not yet (${why.slice(0, 160)})`);
    if (why.includes('Missing') && why !== told) {
      told = why;
      const missing = why.slice(why.indexOf('Missing'));
      const who = typeof zone === 'number' ? 'Excavator crew' : `The ${zone}`;
      try { await call('POST', '/attention', { text: `${who} needs: ${missing.replace('Missing:', '').trim()}` }); } catch {}
    }
    await sleep(RETRY);
  }
}
log(zones.length > 1 ? 'The whole crew is out' : 'Done');
