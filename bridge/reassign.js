// Hands out new jobs as turtles come online: for each assignment, once the
// computer is connected (and, if `after` is set, once its excavate state has
// reached that phase), it waits for a moment between moves, stops the old
// job, syncs the programs and starts the new autorun. Each runs once.
// Progress goes to logs/reassign.log. Usage: node bridge/reassign.js
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const LOG = 'logs/reassign.log';
const log = (msg) => {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG, line + '\n');
};

const cli = (...args) => {
  try {
    return execFileSync('node', ['bridge/cli.js', ...args], { encoding: 'utf8', timeout: 150000 });
  } catch (e) {
    return String(e.stdout || '') + String(e.stderr || '') + String(e.message || '');
  }
};

// The jobs, in the order they're wanted.
const assignments = [
  { id: 4, program: 'factory', args: ['run'], why: 'item requests by label at the fuel station' },
  { id: 12, program: 'excavate', args: ['fill', '3,1,6,2'], why: 'dry zones 3, 1, 6, 2' },
  { id: 15, program: 'excavate', args: ['fill', '4'], why: 'dry zone 4' },
  { id: 16, program: 'excavate', args: ['help', '8', '7500', '8180'], why: 'finish zone 8 round the Stella Arcanum' },
  { id: 16, program: 'excavate', args: ['fill', '8'], after: 'done', why: 'then dry zone 8' },
  { id: 24, program: 'excavate', args: ['light', '1,2,3,5,6,7'], why: 'lamplighter with the hazard rule' },
  { id: 25, program: 'excavate', args: ['porter'], why: 'porter with the hazard rule' },
];

const connected = () => new Set([...cli('computers').matchAll(/^#(\d+)/gm)].map((m) => Number(m[1])));
const evalOn = (id, lua) => cli('eval', '--c', String(id), lua).split('\n')[0];

const pending = assignments.map((a) => ({ ...a, done: false, startedNext: false }));
log(`Watching for ${pending.length} assignments`);

while (pending.some((a) => !a.done)) {
  const online = connected();
  for (const a of pending) {
    if (a.done || !online.has(a.id)) continue;
    // Only the first open assignment per computer.
    if (pending.find((b) => b.id === a.id && !b.done) !== a) continue;
    if (a.after) {
      const phase = evalOn(a.id, "local f=fs.open('/.excavate','r') local s=f and textutils.unserialise(f.readAll()) if f then f.close() end return s and s.phase");
      if (!phase.includes(`"${a.after}"`)) continue;
    }
    if (a.program === 'excavate') {
      let clean = false;
      for (let i = 0; i < 10 && !clean; i++) {
        clean = evalOn(a.id, "local f=fs.open('/.excavate','r') local s=f and f.readAll() or '' if f then f.close() end return s:find('pending')==nil") === '=> true';
      }
      if (!clean) { log(`#${a.id} busy moving; later`); continue; }
    }
    cli('stop', '--c', String(a.id));
    cli('sync', '--c', String(a.id));
    const out = cli('autorun', a.program, ...a.args, '--start', '--c', String(a.id));
    a.done = /"started":true/.test(out);
    log(`#${a.id} ${a.program} ${a.args.join(' ')} (${a.why}): ${a.done ? 'started' : out.trim().slice(0, 120)}`);
  }
  await new Promise((r) => setTimeout(r, 30000));
}
log('All assignments handed out');
