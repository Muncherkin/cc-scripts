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
    // Lost: the link dropped, not the job; the agent keeps running it.
    if (j.state === 'lost' || /disconnected/i.test(why)) continue;
    // Only what the machine is still set to run (an autorun cleared since is
    // a turtle taken off its job), with the arguments it's set to run with:
    // never none by accident (2026-11-15: a restart without `run` left the
    // factory printing usage). Read from the machine itself: the bridge's
    // copy is from when it connected.
    const r = cli('eval', 'if not fs.exists("/.agent/autorun") then return "" end local h=fs.open("/.agent/autorun","r") local a=textutils.unserialise(h.readAll()) h.close() return textutils.serialiseJSON({program=a.program,args=a.args or {}})', '--c', String(j.computer), '--timeout', '5');
    const m = r.match(/=> "(.*)"\s*\n/);
    let auto = null;
    try { auto = m && m[1] ? JSON.parse(JSON.parse('"' + m[1] + '"')) : null; } catch { auto = null; }
    if (!m) { log(`#${j.computer} ${j.program} stopped: ${why}; can't read its autorun, left for the next round`); handled.delete(f); continue; }
    if (!auto || auto.program !== j.program) { log(`#${j.computer} ${j.program} stopped: ${why}; no longer its autorun, left stopped`); continue; }
    const args = Array.isArray(auto.args) ? auto.args : Object.values(auto.args || {});
    if (Array.isArray(j.args) && j.args.length > args.length) { log(`#${j.computer} ${j.program} stopped: ${why}; its autorun has fewer arguments than it ran with, left stopped`); continue; }
    const recent = (times[j.computer] || []).filter((t) => Date.now() - t < 3600000);
    times[j.computer] = recent;
    if (recent.length >= 6) { log(`#${j.computer} keeps failing (${why}): left stopped for now`); continue; }
    recent.push(Date.now());
    restarts[j.computer] = (restarts[j.computer] || 0) + 1;
    log(`#${j.computer} ${j.program} stopped: ${why} -> started again (${restarts[j.computer]})`);
    // Every job on it first: one stopped by id can leave another running.
    cli('stop', '--c', String(j.computer));
    cli('autorun', j.program, ...args.map(String), '--start', '--c', String(j.computer));
  }
  let computers = [];
  try { computers = await (await fetch(API + '/computers')).json(); } catch { /* bridge busy */ }
  const crew = computers.filter((c) => c.id >= FIRST).map((c) => c.id).sort((a, b) => a - b);
  const line = `${crew.length} builders online (${crew.join(' ')}), ${built.size} finished`;
  if (line !== last.line) { log(line); last.line = line; }
  await sleep(60);
}
log(`done watching: ${built.size} finished, restarts ${JSON.stringify(restarts)}`);
