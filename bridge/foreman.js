#!/usr/bin/env node
// Keeps the fleet going: every minute it looks at the autorun jobs that
// ended, on any machine (builders, gatherers, the factory), and one that
// stopped with an error is started again with the same program and
// arguments (it resumes from its saved state), up to 6 times an hour a
// machine. Prints a line when something changes, and a summary at the end.
//
//   node bridge/foreman.js [minutes]

import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const API = 'http://127.0.0.1:8788';
const minutes = Number(process.argv[2]) || 60;
const FIRST = 34;
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const log = (msg) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);
const cli = (...args) => { try { return execFileSync('node', ['bridge/cli.js', ...args], { encoding: 'utf8', timeout: 120000 }); } catch (e) { return String(e.stdout || e.message); } };

const handled = new Set(fs.readdirSync('logs/jobs'));
const restarts = {}, times = {}, last = {}, built = new Set();
const started = Date.now();
while (Date.now() - started < minutes * 60000) {
  for (const f of fs.readdirSync('logs/jobs')) {
    if (handled.has(f) || !f.startsWith('autorun')) continue;
    let j;
    try { j = JSON.parse(fs.readFileSync('logs/jobs/' + f, 'utf8')); } catch { continue; }
    handled.add(f);
    if (!j.program) continue;
    const text = (j.output || []).map((o) => o.text).join('');
    const tail = text.trim().split('\n').slice(-1)[0] || '';
    if (j.state === 'ok') { built.add(j.computer); log(`#${j.computer} finished: ${tail}`); continue; }
    const why = (j.error || '').split('\n')[0];
    if (/Stopped by bridge/.test(why)) continue;
    const recent = (times[j.computer] || []).filter((t) => Date.now() - t < 3600000);
    times[j.computer] = recent;
    if (recent.length >= 6) { log(`#${j.computer} keeps failing (${why}): left stopped for now`); continue; }
    recent.push(Date.now());
    restarts[j.computer] = (restarts[j.computer] || 0) + 1;
    log(`#${j.computer} ${j.program} stopped: ${why} -> started again (${restarts[j.computer]})`);
    // Every job on it first: one stopped by id can leave another running.
    cli('stop', '--c', String(j.computer));
    cli('autorun', j.program, ...(j.args || []).map(String), '--start', '--c', String(j.computer));
  }
  let computers = [];
  try { computers = await (await fetch(API + '/computers')).json(); } catch { /* bridge busy */ }
  const crew = computers.filter((c) => c.id >= FIRST).map((c) => c.id).sort((a, b) => a - b);
  const line = `${crew.length} builders online (${crew.join(' ')}), ${built.size} finished`;
  if (line !== last.line) { log(line); last.line = line; }
  await sleep(60);
}
log(`done watching: ${built.size} finished, restarts ${JSON.stringify(restarts)}`);
