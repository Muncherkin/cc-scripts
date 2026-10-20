// Dev bridge between this PC and CC: Tweaked computers in Minecraft.
//
//  - Port 8787 (exposed through an ngrok tunnel): in-game agents
//    connect here over a websocket.
//  - Port 8788 (localhost only): JSON API used by bridge/cli.js.
//
// The current tunnel URL is published to a secret gist that agents read, so
// they find the bridge again after it restarts.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { createDashboard } from './dashboard.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const STATE_FILE = path.join(ROOT, 'bridge', '.state.json');
const PROGRAMS_DIR = path.join(ROOT, 'programs');
const DOCS_DIR = path.join(ROOT, 'docs');
const LOG_DIR = path.join(ROOT, 'logs');
const JOB_DIR = path.join(LOG_DIR, 'jobs');
const SEEN_FILE = path.join(LOG_DIR, 'seen.json');
const WS_PORT = 8787;
const API_PORT = 8788;
const INSTALL_URL = 'https://raw.githubusercontent.com/Muncherkin/cc-scripts/main/cc/install.lua';

fs.mkdirSync(JOB_DIR, { recursive: true });

// ---------- logging ----------

const logStream = fs.createWriteStream(path.join(LOG_DIR, 'bridge.log'), { flags: 'a' });
function log(...parts) {
  const line = `[${new Date().toISOString()}] ${parts.join(' ')}`;
  console.log(line);
  logStream.write(line + '\n');
}

// ---------- persistent state (token + gist) ----------

const state = fs.existsSync(STATE_FILE) ? JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) : {};
if (!state.token) state.token = randomBytes(16).toString('hex');
const saveState = () => fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
saveState();

function gh(args, input) {
  return execFileSync('gh', args, { input, encoding: 'utf8' }).trim();
}

function ensureGist() {
  if (state.gistId) return;
  const created = JSON.parse(gh(['api', '-X', 'POST', 'gists', '--input', '-'], JSON.stringify({
    description: 'cc-scripts bridge URL',
    public: false,
    files: { 'bridge.txt': { content: 'offline' } },
  })));
  state.gistId = created.id;
  state.gistOwner = created.owner.login;
  saveState();
  log('Created gist', state.gistId);
}

function publishUrl(url) {
  gh(['api', '-X', 'PATCH', `gists/${state.gistId}`, '--input', '-'],
    JSON.stringify({ files: { 'bridge.txt': { content: url } } }));
  log('Published bridge URL', url);
}

const gistRawUrl = () => `https://gist.githubusercontent.com/${state.gistOwner}/${state.gistId}/raw/bridge.txt`;
const installCommand = () => `wget run ${INSTALL_URL} ${gistRawUrl()} ${state.token}`;

// ---------- computers & jobs ----------

const computers = new Map(); // id -> { ws, status, connectedAt }
// Every computer ever connected (kept across bridge restarts): id -> { status, lastSeen }
const seen = new Map();
try { for (const c of JSON.parse(fs.readFileSync(SEEN_FILE, 'utf8'))) seen.set(c.status.id, c); } catch {}
const saveSeen = () => fs.writeFileSync(SEEN_FILE, JSON.stringify([...seen.values()], null, 2));
function touchSeen(status) {
  const prev = seen.get(status.id);
  seen.set(status.id, { status: { ...prev?.status, ...status }, lastSeen: Date.now() });
}
const jobs = new Map();      // id -> job
const pendingReqs = new Map(); // req id -> resolve
let nextJob = 1;
let nextReq = 1;

function sendTo(computer, msg) {
  computer.ws.send(JSON.stringify(msg));
}

const dashboard = createDashboard({
  computers, jobs, seen, sendTo, log, messagesFile: path.join(LOG_DIR, 'messages.json'),
  onAction: (computer, data) => {
    if (data.action === 'print') {
      printDoc(String(data.path), computer).catch((e) => toast(computer, `Print failed: ${e.message}`));
    }
  },
});
const nameOf = (id) => seen.get(id)?.status.label ?? `#${id}`;

function request(computer, msg, timeoutMs = 10000) {
  const req = nextReq++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pendingReqs.delete(req); reject(new Error(`Request ${msg.type} timed out`)); }, timeoutMs);
    pendingReqs.set(req, (reply) => { clearTimeout(timer); resolve(reply); });
    sendTo(computer, { ...msg, req });
  });
}

function finishJob(job, fields) {
  Object.assign(job, fields, { finishedAt: new Date().toISOString() });
  fs.writeFileSync(path.join(JOB_DIR, `${job.id}.json`), JSON.stringify(job, null, 2));
  log(`Job ${job.id} ${job.state}${job.error ? ': ' + job.error.split('\n')[0] : ''}`);
  for (const w of job.waiters.splice(0)) w();
  dashboard.forget(job.computer, job.id);
  if (job.type !== 'eval') {
    const what = `${nameOf(job.computer)}: ${job.program ?? 'job'}`;
    dashboard.event(job.state === 'ok' ? `${what} finished` : `${what} ${job.state}: ${(job.error ?? '').split('\n')[0]}`);
  }
}

function handleAgentMessage(ws, msg) {
  if (msg.type === 'hello') {
    const id = msg.status.id;
    ws.computerId = id;
    computers.set(id, { ws, status: msg.status, connectedAt: new Date().toISOString() });
    touchSeen(msg.status);
    saveSeen();
    log(`Computer ${id} (${msg.status.label ?? 'no label'}) connected`);
    dashboard.event(`${nameOf(id)} connected`);
    return;
  }
  const computer = computers.get(ws.computerId);
  if (!computer) return;

  if (msg.req && pendingReqs.has(msg.req)) {
    pendingReqs.get(msg.req)(msg);
    pendingReqs.delete(msg.req);
  }

  // Jobs the agent started on its own (autorun) are tracked from their first message.
  if (msg.job && msg.job !== 'ipc' && !jobs.has(msg.job) && ['started', 'output', 'done', 'from_job'].includes(msg.type)) {
    const job = { id: msg.job, computer: computer.status.id, type: 'autorun', program: msg.program, state: 'running', createdAt: new Date().toISOString(), output: [] };
    Object.defineProperty(job, 'waiters', { value: [], enumerable: false });
    jobs.set(job.id, job);
    log(`Job ${job.id} reported by computer ${job.computer}`);
  }

  const job = msg.job && jobs.get(msg.job);
  switch (msg.type) {
    case 'ping':
      if (msg.fuel !== undefined && msg.fuel !== computer.status.fuel) {
        computer.status.fuel = msg.fuel;
        touchSeen({ id: computer.status.id, fuel: msg.fuel });
        dashboard.schedule();
      } else {
        touchSeen({ id: computer.status.id });
      }
      break;
    case 'from_job': dashboard.fromJob(computer, msg.job, msg.data); break;
    case 'status': computer.status = msg.status; touchSeen(msg.status); break;
    case 'started': if (job) { job.state = 'running'; job.startedAt = new Date().toISOString(); } break;
    case 'output':
      if (job) {
        job.output.push({ stream: msg.stream, text: msg.text });
        if (job.output.length > 1000) job.output.splice(0, job.output.length - 1000);
        if (job.type !== 'eval') dashboard.schedule();
      }
      break;
    case 'done':
      computer.status = msg.status;
      touchSeen(msg.status);
      if (job) finishJob(job, { state: msg.ok ? 'ok' : 'error', result: msg.result ?? null, error: msg.error ?? null, ms: msg.ms, statusAfter: msg.status });
      break;
  }
}

const agentServer = http.createServer((req, res) => { res.writeHead(200); res.end('cc-scripts bridge'); });
const wss = new WebSocketServer({ noServer: true });

agentServer.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname !== '/ws' || url.searchParams.get('token') !== state.token) {
    log('Rejected websocket connection (bad path or token)');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.on('message', (data) => {
      try { handleAgentMessage(ws, JSON.parse(data.toString())); }
      catch (e) { log('Bad message from agent:', e.message); }
    });
    ws.on('close', () => {
      const id = ws.computerId;
      if (id === undefined || computers.get(id)?.ws !== ws) return;
      computers.delete(id);
      touchSeen({ id });
      saveSeen();
      dashboard.forget(id);
      log(`Computer ${id} disconnected`);
      dashboard.event(`${nameOf(id)} went offline`);
      for (const job of jobs.values()) {
        if (job.computer === id && (job.state === 'queued' || job.state === 'running')) {
          finishJob(job, { state: 'lost', error: 'Computer disconnected before the job finished' });
        }
      }
    });
  });
});

// ---------- API helpers ----------

function pickComputer(id) {
  if (id !== undefined && id !== null && id !== '') {
    const c = computers.get(Number(id));
    if (!c) throw new Error(`Computer ${id} is not connected`);
    return c;
  }
  if (computers.size === 1) return [...computers.values()][0];
  if (computers.size === 0) throw new Error('No computers connected');
  throw new Error(`Several computers connected (${[...computers.keys()].join(', ')}); pass a computer id`);
}

function listFiles(dir, prefix = '') {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const rel = prefix ? `${prefix}/${e.name}` : e.name;
    return e.isDirectory() ? listFiles(path.join(dir, e.name), rel) : [rel];
  });
}

// Copies every file under srcDir to destPrefix on the computer.
async function syncDir(computer, srcDir, destPrefix = '') {
  const files = listFiles(srcDir);
  for (const rel of files) {
    const content = fs.readFileSync(path.join(srcDir, rel), 'utf8');
    const reply = await request(computer, { type: 'put', path: destPrefix + rel, content });
    if (!reply.ok) throw new Error(`Agent refused to write ${destPrefix + rel}`);
  }
  log(`Synced ${files.length} file(s) from ${path.basename(srcDir)}/ to computer ${computer.status.id}`);
  return files;
}
const syncPrograms = (computer) => syncDir(computer, PROGRAMS_DIR);

// ---------- docs (Claude OS on pocket computers) and printing ----------

const pockets = () => [...computers.values()].filter((c) => c.status.pocket);
const toast = (c, text) => sendTo(c, { type: 'push', event: 'toast', data: { text } });

function readDoc(relPath) {
  const full = path.resolve(DOCS_DIR, relPath);
  if (!full.startsWith(DOCS_DIR + path.sep) || !fs.existsSync(full)) throw new Error(`No such doc: ${relPath}`);
  return fs.readFileSync(full, 'utf8');
}
const docTitle = (content, fallback) => (content.match(/^# (.+)$/m)?.[1] ?? fallback).trim();

async function syncDocs(computer) {
  const files = await syncDir(computer, DOCS_DIR, 'docs/');
  sendTo(computer, { type: 'push', event: 'docs', data: { files } });
  dashboard.event(`Docs synced to ${nameOf(computer.status.id)} (${files.length})`);
  return files;
}

// Sends one doc to every pocket computer with a note (used when printing fails).
async function sendDocToPockets(relPath, note) {
  const content = readDoc(relPath);
  const targets = pockets();
  for (const c of targets) {
    await request(c, { type: 'put', path: `docs/${relPath}`, content });
    sendTo(c, { type: 'push', event: 'docs', data: { files: [relPath] } });
    toast(c, note);
  }
  return targets.length;
}

// Prints a doc on whichever computer has a printer; falls back to pockets.
async function printDoc(relPath, requester) {
  const content = readDoc(relPath);
  const title = docTitle(content, relPath);
  const printerComputer = [...computers.values()].find((c) => (c.status.peripherals ?? []).includes('printer'));
  let problem = null;
  if (!printerComputer) {
    problem = 'Printer offline';
  } else {
    await request(printerComputer, { type: 'put', path: 'prints/_doc.txt', content });
    const job = await waitForJob(startJob(printerComputer, { type: 'run', program: 'printlist', args: ['_doc'] }), 30000);
    if (job.state !== 'ok') problem = (job.error ?? `print ${job.state}`).split('\n')[0];
  }
  if (problem) {
    const n = await sendDocToPockets(relPath, `${problem}. '${title}' is on your pocket instead.`);
    dashboard.event(`Print of '${title}' failed (${problem}); sent to ${n} pocket(s)`);
    return { printed: false, problem, sentToPockets: n };
  }
  if (requester) toast(requester, `Printed '${title}'`);
  dashboard.event(`Printed '${title}'`);
  return { printed: true, title };
}

function startJob(computer, fields) {
  const job = {
    id: `${Date.now().toString(36)}-${nextJob++}`,
    computer: computer.status.id,
    state: 'queued',
    createdAt: new Date().toISOString(),
    output: [],
    waiters: [],
    ...fields,
  };
  Object.defineProperty(job, 'waiters', { enumerable: false });
  jobs.set(job.id, job);
  sendTo(computer, { type: job.type, id: job.id, program: job.program, args: job.args, code: job.code });
  log(`Job ${job.id} ${job.type} on computer ${job.computer}: ${job.program ?? job.code}`);
  return job;
}

function waitForJob(job, timeoutMs) {
  if (!['queued', 'running'].includes(job.state)) return Promise.resolve(job);
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(job), timeoutMs);
    job.waiters.push(() => { clearTimeout(timer); resolve(job); });
  });
}

const routes = {
  'GET /info': () => ({ installCommand: installCommand(), gist: gistRawUrl(), tunnelUrl }),
  'GET /computers': () => [...computers.values()].map((c) => ({ ...c.status, connectedAt: c.connectedAt })),
  'POST /sync': async (b) => ({ synced: await syncPrograms(pickComputer(b.computer)) }),
  'POST /run': async (b) => {
    const c = pickComputer(b.computer);
    if (b.sync !== false) await syncPrograms(c);
    const job = startJob(c, { type: 'run', program: b.program, args: (b.args ?? []).map(String) });
    return waitForJob(job, (b.timeout ?? 60) * 1000);
  },
  'POST /eval': async (b) => {
    const job = startJob(pickComputer(b.computer), { type: 'eval', code: b.code });
    return waitForJob(job, (b.timeout ?? 30) * 1000);
  },
  'POST /wait': (b) => {
    const job = jobs.get(b.job);
    if (!job) throw new Error(`Unknown job ${b.job}`);
    return waitForJob(job, (b.timeout ?? 60) * 1000);
  },
  'POST /docs': async (b) => {
    const targets = b.computer !== undefined ? [pickComputer(b.computer)] : pockets();
    if (targets.length === 0) throw new Error('No pocket computers connected');
    const out = {};
    for (const c of targets) out[c.status.id] = await syncDocs(c);
    return out;
  },
  'POST /print': (b) => printDoc(String(b.path)),
  'POST /say': (b) => { if (!b.text) throw new Error('Nothing to say'); dashboard.say(String(b.text)); return { ok: true }; },
  'GET /dashboard': () => dashboard.snapshot(),
  'GET /jobs': () => [...jobs.values()].slice(-20).map(({ output, ...j }) => ({ ...j, lastOutput: output.slice(-5).map((o) => o.text).join('') })),
  'POST /autorun': async (b) => {
    const c = pickComputer(b.computer);
    if (b.program && b.sync !== false) await syncPrograms(c);
    await request(c, { type: 'autorun', program: b.program ?? null, args: (b.args ?? []).map(String), start: !!b.start });
    return { ok: true, autorun: b.program ?? null, started: !!b.start };
  },
  'POST /stop': (b) => { sendTo(pickComputer(b.computer), { type: 'stop', job: b.job }); return { ok: true }; },
  'POST /reboot': (b) => { sendTo(pickComputer(b.computer), { type: 'reboot' }); return { ok: true }; },
  'POST /update-agent': async (b) => {
    const content = fs.readFileSync(path.join(ROOT, 'cc', 'agent.lua'), 'utf8');
    await request(pickComputer(b.computer), { type: 'self_update', content });
    return { ok: true, note: 'Agent updated; computer is rebooting' };
  },
};

const apiServer = http.createServer(async (req, res) => {
  let body = '';
  for await (const chunk of req) body += chunk;
  const route = routes[`${req.method} ${new URL(req.url, 'http://x').pathname}`];
  res.setHeader('Content-Type', 'application/json');
  if (!route) { res.writeHead(404); res.end(JSON.stringify({ error: 'Not found' })); return; }
  try {
    const result = await route(body ? JSON.parse(body) : {});
    res.end(JSON.stringify(result));
  } catch (e) {
    res.writeHead(400);
    res.end(JSON.stringify({ error: e.message }));
  }
});

// ---------- tunnel ----------

let tunnelUrl = null;

function startTunnel() {
  if (process.env.BRIDGE_URL) {
    tunnelUrl = process.env.BRIDGE_URL;
    publishUrl(tunnelUrl);
    return;
  }
  // ngrok's free plan gives each account a fixed dev domain, which plain
  // `ngrok http` uses. Set NGROK_URL to pick a different reserved domain.
  const wingetLink = path.join(process.env.LOCALAPPDATA ?? '', 'Microsoft', 'WinGet', 'Links', 'ngrok.exe');
  const exe = fs.existsSync(wingetLink) ? wingetLink : 'ngrok';
  const args = ['http', String(WS_PORT), '--log=stdout', '--log-format=json'];
  if (process.env.NGROK_URL) args.push(`--url=${process.env.NGROK_URL}`);
  const proc = spawn(exe, args);
  proc.on('error', (e) => log('Could not start ngrok:', e.message, '- install it with: winget install --id Ngrok.Ngrok'));
  let buffered = '';
  proc.stdout.on('data', (data) => {
    buffered += data.toString();
    const lines = buffered.split('\n');
    buffered = lines.pop();
    for (const line of lines) {
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      if (entry.lvl === 'eror' || entry.lvl === 'crit') log('ngrok error:', entry.err ?? entry.msg);
      if (entry.msg === 'started tunnel' && entry.url && entry.url !== tunnelUrl) {
        tunnelUrl = entry.url;
        log('Tunnel up at', tunnelUrl);
        publishUrl(tunnelUrl);
      }
    }
  });
  proc.stderr.on('data', (data) => log('ngrok:', data.toString().trim()));
  proc.on('exit', (code) => log('ngrok exited with code', code));
  // The ngrok dev domain is fixed, so the published URL stays valid across
  // restarts; leaving it lets agents reconnect the moment the bridge is back.
  const cleanup = () => { proc.kill(); process.exit(0); };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
}

ensureGist();
agentServer.listen(WS_PORT, () => log(`Agent websocket on :${WS_PORT}`));
apiServer.listen(API_PORT, '127.0.0.1', () => log(`API on 127.0.0.1:${API_PORT}`));
startTunnel();
log('Install on a computer with:');
log('  ' + installCommand());
