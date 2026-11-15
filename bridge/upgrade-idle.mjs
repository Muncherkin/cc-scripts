#!/usr/bin/env node
// Moves builders onto the current agent without cutting a move short: the
// old agent (before v7) reboots the moment it's told to update, so each
// builder is updated only while it stands waiting in the bay (trip "wait",
// where it sleeps), or has no job running. Checks every 20 s until all are
// on the current version or the time is up.
//
//   node bridge/upgrade-idle.mjs [minutes]

import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const API = 'http://127.0.0.1:8788';
const minutes = Number(process.argv[2]) || 60;
const VERSION = Number(fs.readFileSync('cc/agent.lua', 'utf8').match(/local VERSION = (\d+)/)[1]);
const log = (msg) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);
const cli = (...args) => { try { return execFileSync('node', ['bridge/cli.js', ...args], { encoding: 'utf8', timeout: 30000 }); } catch (e) { return String(e.stdout || e.message); } };
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const started = Date.now();
while (Date.now() - started < minutes * 60000) {
  let computers, jobs;
  try {
    computers = await (await fetch(API + '/computers')).json();
    jobs = await (await fetch(API + '/jobs')).json();
  } catch { await sleep(20); continue; }
  const old = computers.filter((c) => c.turtle && c.version < VERSION);
  if (!old.length) { log(`every turtle online is on agent v${VERSION}`); break; }
  for (const c of old) {
    // /jobs shows only recent jobs: a turtle counts as idle only when it
    // has no autorun at all (gatherers without a bay are left for later).
    const busy = jobs.some((j) => j.computer === c.id && j.state === 'running') || !!(c.autorun && c.autorun.program);
    const r = cli('eval', 'if not fs.exists("/.builder") then return "-" end local h=fs.open("/.builder","r") local s=textutils.unserialise(h.readAll()) h.close() return tostring(s.trip)', '--c', String(c.id), '--timeout', '5');
    const trip = (r.match(/=> "(.*)"/) || [])[1];
    if (trip === 'wait' || !busy) {
      log(`#${c.id} ${trip === 'wait' ? 'waiting in the bay' : 'idle'}: updating`);
      cli('update-agent', '--c', String(c.id));
    }
  }
  await sleep(20);
}
