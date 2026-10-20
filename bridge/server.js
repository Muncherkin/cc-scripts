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

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const STATE_FILE = path.join(ROOT, 'bridge', '.state.json');
const PROGRAMS_DIR = path.join(ROOT, 'programs');
const LOG_DIR = path.join(ROOT, 'logs');
const JOB_DIR = path.join(LOG_DIR, 'jobs');
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
const jobs = new Map();      // id -> job
const pendingReqs = new Map(); // req id -> resolve
let nextJob = 1;
let nextReq = 1;

function sendTo(computer, msg) {
  computer.ws.send(JSON.stringify(msg));
}

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
}

function handleAgentMessage(ws, msg) {
  if (msg.type === 'hello') {
    const id = msg.status.id;
    ws.computerId = id;
    computers.set(id, { ws, status: msg.status, connectedAt: new Date().toISOString() });
    log(`Computer ${id} (${msg.status.label ?? 'no label'}) connected`);
    return;
  }
  const computer = computers.get(ws.computerId);
  if (!computer) return;

  if (msg.req && pendingReqs.has(msg.req)) {
    pendingReqs.get(msg.req)(msg);
    pendingReqs.delete(msg.req);
  }

  const job = msg.job && jobs.get(msg.job);
  switch (msg.type) {
    case 'status': computer.status = msg.status; break;
    case 'started': if (job) { job.state = 'running'; job.startedAt = new Date().toISOString(); } break;
    case 'output': if (job) job.output.push({ stream: msg.stream, text: msg.text }); break;
    case 'done':
      computer.status = msg.status;
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
      log(`Computer ${id} disconnected`);
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

function listPrograms(dir = PROGRAMS_DIR, prefix = '') {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const rel = prefix ? `${prefix}/${e.name}` : e.name;
    return e.isDirectory() ? listPrograms(path.join(dir, e.name), rel) : [rel];
  });
}

async function syncPrograms(computer) {
  const files = listPrograms();
  for (const rel of files) {
    const content = fs.readFileSync(path.join(PROGRAMS_DIR, rel), 'utf8');
    const reply = await request(computer, { type: 'put', path: rel, content });
    if (!reply.ok) throw new Error(`Agent refused to write ${rel}`);
  }
  log(`Synced ${files.length} file(s) to computer ${computer.status.id}`);
  return files;
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
  const cleanup = () => { proc.kill(); try { publishUrl('offline'); } catch {} process.exit(0); };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
}

ensureGist();
agentServer.listen(WS_PORT, () => log(`Agent websocket on :${WS_PORT}`));
apiServer.listen(API_PORT, '127.0.0.1', () => log(`API on 127.0.0.1:${API_PORT}`));
startTunnel();
log('Install on a computer with:');
log('  ' + installCommand());
