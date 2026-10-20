// Feeds in-game dashboard monitors. Dashboards subscribe over their agent's
// websocket (bridge.send from a job); the bridge then pushes compact status
// snapshots back: right away for messages and events, otherwise throttled,
// because everything goes through the ngrok tunnel.

import fs from 'node:fs';

const THROTTLE_MS = 15000;
const FULL_REFRESH_MS = 60000;
const MAX_EVENTS = 30;
const MAX_MESSAGES = 20;

const hhmm = (d = new Date()) => d.toTimeString().slice(0, 5);

function tailLines(job, n) {
  const text = job.output.map((o) => o.text).join('');
  return text.split('\n').map((l) => l.trimEnd()).filter(Boolean).slice(-n);
}

export function createDashboard({ computers, jobs, seen, sendTo, log, messagesFile }) {
  const subscribers = new Map(); // computer id -> job id of its dashboard program
  const events = [];
  let messages = [];
  try { messages = JSON.parse(fs.readFileSync(messagesFile, 'utf8')); } catch {}

  let pushTimer = null;
  let lastPush = 0;

  function snapshot() {
    const list = [...seen.values()].sort((a, b) => a.status.id - b.status.id).map((c) => {
      const id = c.status.id;
      const running = [...jobs.values()].filter((j) => j.computer === id && j.state === 'running' && j.type !== 'eval');
      return {
        id,
        label: c.status.label ?? `#${id}`,
        kind: c.status.turtle ? 'turtle' : c.status.pocket ? 'pocket' : 'computer',
        online: computers.has(id),
        fuel: c.status.turtle ? c.status.fuel : null,
        lastSeen: hhmm(new Date(c.lastSeen)),
        dashboard: subscribers.has(id),
        jobs: running.filter((j) => !subscribers.has(id) || j.id !== subscribers.get(id))
          .map((j) => ({ program: j.program ?? '(autorun)', tail: tailLines(j, 2) })),
      };
    });
    return { time: hhmm(), computers: list, messages: messages.slice(-8).reverse(), events: events.slice(-10).reverse() };
  }

  function pushNow() {
    pushTimer = null;
    lastPush = Date.now();
    if (subscribers.size === 0) return;
    const data = snapshot();
    for (const id of subscribers.keys()) {
      const c = computers.get(id);
      if (c) sendTo(c, { type: 'push', event: 'status', data });
    }
  }

  // urgent: messages/events go out within a moment; everything else waits
  // for the throttle window.
  function schedule(urgent = false) {
    const delay = urgent ? 300 : Math.max(0, lastPush + THROTTLE_MS - Date.now());
    if (pushTimer) {
      if (!urgent) return;
      clearTimeout(pushTimer);
    }
    pushTimer = setTimeout(pushNow, delay);
  }
  setInterval(() => schedule(false), FULL_REFRESH_MS).unref();

  function event(text) {
    events.push({ time: hhmm(), text });
    if (events.length > MAX_EVENTS) events.splice(0, events.length - MAX_EVENTS);
    schedule(true);
  }

  function say(text) {
    messages.push({ time: hhmm(), text });
    if (messages.length > MAX_MESSAGES) messages.splice(0, messages.length - MAX_MESSAGES);
    fs.writeFileSync(messagesFile, JSON.stringify(messages, null, 2));
    log('Message to dashboards:', text);
    schedule(true);
  }

  // A message a dashboard program sent with bridge.send(data).
  function fromJob(computer, jobId, data) {
    const id = computer.status.id;
    switch (data?.action) {
      case 'subscribe':
        subscribers.set(id, jobId);
        log(`Dashboard on computer ${id} subscribed`);
        schedule(true);
        break;
      case 'detail': {
        const target = seen.get(Number(data.computer));
        const forComputer = [...jobs.values()].filter((j) => j.computer === Number(data.computer) && j.type !== 'eval');
        const job = forComputer.filter((j) => j.state === 'running').pop() ?? forComputer.pop();
        sendTo(computer, {
          type: 'push', event: 'detail',
          data: {
            id: Number(data.computer),
            label: target?.status.label ?? `#${data.computer}`,
            program: job?.program ?? null,
            state: job?.state ?? null,
            lines: job ? tailLines(job, 60) : [],
          },
        });
        break;
      }
      case 'stop_all':
        for (const [cid, c] of computers) {
          if (cid !== id) sendTo(c, { type: 'stop' });
        }
        event('STOP ALL pressed on monitor');
        log(`STOP ALL from dashboard on computer ${id}`);
        break;
    }
  }

  function forget(computerId, jobId) {
    if (subscribers.has(computerId) && (jobId === undefined || subscribers.get(computerId) === jobId)) {
      subscribers.delete(computerId);
    }
  }

  return { snapshot, schedule, event, say, fromJob, forget, messages: () => messages };
}
