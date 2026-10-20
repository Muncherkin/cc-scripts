#!/usr/bin/env node
// Command-line client for the bridge API (bridge must be running: npm run bridge).
//
//   node bridge/cli.js computers
//   node bridge/cli.js info
//   node bridge/cli.js sync
//   node bridge/cli.js run <program> [args...] [--no-sync]
//   node bridge/cli.js eval "<lua expression or statements>"
//   node bridge/cli.js wait <jobId>
//   node bridge/cli.js jobs
//   node bridge/cli.js autorun <program> [args...] [--start] | autorun --clear
//   node bridge/cli.js docs [--c id]      (copy docs/ to pocket computers' /docs)
//   node bridge/cli.js print <doc path>   (print docs/<path>; falls back to pockets)
//   node bridge/cli.js say <text>          (show a message on dashboard monitors)
//   node bridge/cli.js dashboard           (what dashboards currently show)
//   node bridge/cli.js stop [jobId] | reboot | update-agent
//
// Options: --c <computerId>  --timeout <seconds>  --json

const API = 'http://127.0.0.1:8788';

const argv = process.argv.slice(2);
const opts = { json: false, sync: true };
const positional = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--c') opts.computer = argv[++i];
  else if (a === '--timeout') opts.timeout = Number(argv[++i]);
  else if (a === '--json') opts.json = true;
  else if (a === '--no-sync') opts.sync = false;
  else if (a === '--start') opts.start = true;
  else if (a === '--clear') opts.clear = true;
  else positional.push(a);
}
const [cmd, ...rest] = positional;

async function call(method, route, body) {
  let res;
  try {
    res = await fetch(API + route, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    console.error('Bridge is not running. Start it with: npm run bridge');
    process.exit(2);
  }
  const data = await res.json();
  if (!res.ok) { console.error('Error:', data.error); process.exit(1); }
  return data;
}

function printJob(job) {
  if (opts.json) { console.log(JSON.stringify(job, null, 2)); return; }
  for (const o of job.output) process.stdout.write(o.stream === 'stderr' ? `[stderr] ${o.text}` : o.text);
  if (job.state === 'ok') {
    if (job.result != null) console.log(`=> ${job.result}`);
    console.log(`-- ok (${job.ms} ms)${job.statusAfter?.turtle ? `, fuel ${job.statusAfter.fuel}` : ''}`);
  } else if (job.state === 'queued' || job.state === 'running') {
    console.log(`-- still ${job.state} after timeout; check later with: node bridge/cli.js wait ${job.id}`);
  } else {
    console.log(`-- ${job.state}: ${job.error}`);
  }
  if (job.state !== 'ok') process.exitCode = 1;
}

const base = { computer: opts.computer, timeout: opts.timeout };

switch (cmd) {
  case 'computers': {
    const list = await call('GET', '/computers');
    if (opts.json) console.log(JSON.stringify(list, null, 2));
    else if (!list.length) console.log('No computers connected');
    else for (const c of list) console.log(`#${c.id} ${c.label ?? ''} ${c.turtle ? `turtle fuel=${c.fuel}` : c.pocket ? 'pocket' : 'computer'} agent v${c.version}`);
    break;
  }
  case 'info': console.log(JSON.stringify(await call('GET', '/info'), null, 2)); break;
  case 'sync': console.log((await call('POST', '/sync', base)).synced.join('\n') || 'Nothing to sync'); break;
  case 'run': printJob(await call('POST', '/run', { ...base, program: rest[0], args: rest.slice(1), sync: opts.sync })); break;
  case 'eval': printJob(await call('POST', '/eval', { ...base, code: rest.join(' ') })); break;
  case 'wait': printJob(await call('POST', '/wait', { ...base, job: rest[0] })); break;
  case 'jobs':
    for (const j of await call('GET', '/jobs')) console.log(`${j.id}  #${j.computer}  ${j.state.padEnd(7)} ${(j.program ?? j.code ?? (j.type === 'autorun' ? '(autorun)' : '')).slice(0, 60)}${j.error ? '  ' + j.error.split('\n')[0] : ''}`);
    break;
  case 'autorun':
    console.log(JSON.stringify(await call('POST', '/autorun', opts.clear ? base : { ...base, program: rest[0], args: rest.slice(1), start: opts.start, sync: opts.sync })));
    break;
  case 'docs': console.log(JSON.stringify(await call('POST', '/docs', opts.computer !== undefined ? { computer: opts.computer } : {}), null, 2)); break;
  case 'print': console.log(JSON.stringify(await call('POST', '/print', { path: rest[0] }))); break;
  case 'say': console.log(JSON.stringify(await call('POST', '/say', { text: rest.join(' ') }))); break;
  case 'dashboard': console.log(JSON.stringify(await call('GET', '/dashboard'), null, 2)); break;
  case 'stop': console.log(JSON.stringify(await call('POST', '/stop', { ...base, job: rest[0] }))); break;
  case 'reboot': case 'update-agent':
    console.log(JSON.stringify(await call('POST', `/${cmd}`, base))); break;
  default:
    console.log('Commands: computers, info, sync, run <program> [args], eval <code>, wait <job>, jobs, autorun <program> [--start] | --clear, docs, print <doc>, say <text>, dashboard, stop [job], reboot, update-agent');
}
