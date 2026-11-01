// The dig: everything the works occupy, cleared to air before anything is
// built, and the route an excavator turtle takes to do it.
//
// The volume is every cell any structure sets (air or block): rock stays only
// where every structure says to leave it. Walls, floors and roofs are dug too,
// so the builders only place. The lift's own column is never touched.
//
// A crew digs it: the volume is cut into wedges round the lift with equal
// numbers of blocks, one per turtle. Each flies over from the factory and
// comes down the service shaft three east of the lift to the top of the
// hall, (3, 8, 0) in site coordinates (x east, y up, z south, origin at the
// lift's bottom), and digs its wedge.
// Round the foot of the shaft is a hub any of them may dig through.
//
// Each route works down in slabs three high: the turtle walks the middle
// layer row by row, digging up and down as it goes, then digs what's left
// from the side. It only stands in cells it has dug, the hub or the shaft.

// Route ops (world directions):
//   n e s w u d   move that way, digging first if needed
//   N E S W U D   dig that way without moving
//   0 1 2 3 4 5   look n e s w u d: rock to keep is there; plug any liquid

import { STRUCTURES, SITE, SERVICE } from './structures.mjs';

const DIRS = [
  { op: 'n', dx: 0, dy: 0, dz: -1 }, { op: 'e', dx: 1, dy: 0, dz: 0 },
  { op: 's', dx: 0, dy: 0, dz: 1 }, { op: 'w', dx: -1, dy: 0, dz: 0 },
  { op: 'u', dx: 0, dy: 1, dz: 0 }, { op: 'd', dx: 0, dy: -1, dz: 0 },
];
const key = (x, y, z) => `${x},${y},${z}`;
const unkey = (k) => k.split(',').map(Number);

export function volume() {
  const cells = new Set();
  const grids = {};
  for (const p of SITE) {
    const g = grids[p.id] ??= STRUCTURES[p.id]();
    for (let y = 0; y < g.size.y; y++) for (let z = 0; z < g.size.z; z++) for (let x = 0; x < g.size.x; x++) {
      if (g.get(x, y, z) !== ' ') cells.add(key(x + p.at[0], y + p.at[1], z + p.at[2]));
    }
  }
  // The lift's column, from its bottom up: the elevator's.
  for (const k of [...cells]) {
    const [x, y, z] = unkey(k);
    if (x === 0 && z === 0 && y >= 0) cells.delete(k);
  }
  return cells;
}

// How many excavators share the dig.
export const CREW = 8;
export const START = [SERVICE[0], 8, SERVICE[2]];
const inShaft = (x, y, z) => x === SERVICE[0] && z === SERVICE[2] && y >= START[1];
const inHub = (x, y, z) => Math.max(Math.abs(x - SERVICE[0]), Math.abs(z - SERVICE[2])) <= 2 && y >= START[1] - 1;

// Splits the volume into n wedges round the service shaft, equal in blocks:
// every wedge reaches in to the shaft.
export function zones(cells, n) {
  const list = [...cells].map(unkey).map((c) => ({ c, a: Math.atan2(c[2] - SERVICE[2], c[0] - SERVICE[0]) }));
  list.sort((p, q) => p.a - q.a);
  const out = Array.from({ length: n }, () => new Set());
  list.forEach((p, i) => out[Math.floor(i * n / list.length)].add(key(...p.c)));
  return out;
}

// A route that digs every cell of `own` (part of the volume `cells`).
export function route(cells, own = cells) {
  let minY = Infinity, maxY = -Infinity;
  for (const k of own) { const y = unkey(k)[1]; minY = Math.min(minY, y); maxY = Math.max(maxY, y); }
  const lift = (x, y, z) => x === 0 && z === 0 && y >= 0;
  const done = new Set();
  // The hub may be dug on the way, by anyone: it's part of the volume.
  const hub = (k) => cells.has(k) && inHub(...unkey(k));
  const standable = (k) => done.has(k) || inShaft(...unkey(k)) || hub(k);
  let pos = [...START];
  done.add(key(...START)); // dug on the way down
  const ops = [];
  let moves = 0, looks = 0;

  const dirTo = (a, b) => DIRS.find((d) => a[0] + d.dx === b[0] && a[1] + d.dy === b[1] && a[2] + d.dz === b[2]);
  const step = (d) => { ops.push(d.op); pos = [pos[0] + d.dx, pos[1] + d.dy, pos[2] + d.dz]; done.add(key(...pos)); moves++; };

  // Walks through standable cells to one next to target; returns the
  // direction from there to the target, or null.
  function approach(target) {
    const near = dirTo(pos, target);
    if (near) return near;
    const goal = new Set(DIRS.map((d) => key(target[0] - d.dx, target[1] - d.dy, target[2] - d.dz)));
    const start = key(...pos);
    const prev = new Map([[start, null]]);
    const queue = [pos];
    let found = null;
    for (let i = 0; i < queue.length && !found; i++) {
      const c = queue[i];
      for (const d of DIRS) {
        const n = [c[0] + d.dx, c[1] + d.dy, c[2] + d.dz];
        const k = key(...n);
        if (prev.has(k) || !standable(k) || n[1] > maxY + 2) continue;
        prev.set(k, key(...c));
        if (goal.has(k)) { found = k; break; }
        queue.push(n);
      }
    }
    if (!found) return null;
    const path = [];
    for (let k = found; k !== start; k = prev.get(k)) path.push(unkey(k));
    for (const c of path.reverse()) step(dirTo(pos, c));
    return dirTo(pos, target);
  }

  // Only cells next to somewhere it can stand: the dug space is connected,
  // so it can always walk there.
  const touches = (c) => DIRS.some((d) => standable(key(c[0] + d.dx, c[1] + d.dy, c[2] + d.dz)));
  function dig(target, moveIn) {
    if (!touches(target)) return false;
    const d = approach(target);
    if (!d) return false;
    if (moveIn) step(d); else { ops.push(d.op.toUpperCase()); done.add(key(...target)); }
    return true;
  }

  // Once standing in a cell: dig above and below, and look at kept rock.
  function standHere() {
    for (const d of DIRS.slice(4)) {
      const n = [pos[0] + d.dx, pos[1] + d.dy, pos[2] + d.dz];
      if (own.has(key(...n)) && !done.has(key(...n)) && Math.abs(n[1] - slabMid) <= 1) {
        ops.push(d.op.toUpperCase()); done.add(key(...n));
      }
    }
    DIRS.forEach((d, i) => {
      const n = [pos[0] + d.dx, pos[1] + d.dy, pos[2] + d.dz];
      if (!cells.has(key(...n)) && !inShaft(...n) && !lift(...n) && !done.has(key(...n))) { ops.push(String(i)); looks++; }
    });
  }

  let slabMid = 0, slab = 0;
  const ownCells = [...own].map(unkey);
  for (let m = maxY - 1; m - 1 <= maxY && m + 1 >= minY; m -= 3, slab++) {
    slabMid = m;
    // The middle layer, row by row, snaking.
    const layer = ownCells.filter((c) => c[1] === m);
    const zs = [...new Set(layer.map((c) => c[2]))].sort((a, b) => slab % 2 ? b - a : a - b);
    // Sweeps until the layer is done: cells not yet next to dug space wait
    // for the next sweep.
    for (let todo = layer.length; todo > 0;) {
      let row = 0, progress = 0;
      for (const z of zs) {
        const xs = layer.filter((c) => c[2] === z).map((c) => c[0]).sort((a, b) => row % 2 ? b - a : a - b);
        row++;
        for (const x of xs) {
          if (done.has(key(x, m, z)) || !dig([x, m, z], true)) continue;
          standHere();
          progress++;
        }
      }
      todo = layer.filter((c) => !done.has(key(...c))).length;
      if (todo && !progress) {
        // Nothing in reach: step down into the slab's top layer, over a cell
        // of this one.
        const entry = layer.find((c) => !done.has(key(...c)) && own.has(key(c[0], m + 1, c[2])) &&
          !done.has(key(c[0], m + 1, c[2])) && touches([c[0], m + 1, c[2]]));
        if (!entry || !dig([entry[0], m + 1, entry[2]], true)) {
          throw new Error(`can't reach ${todo} cells of layer ${m}, e.g. ${key(...layer.find((c) => !done.has(key(...c))))}`);
        }
      }
    }
    // What's left of the slab, dug from beside it.
    let left = ownCells.filter((c) => Math.abs(c[1] - m) <= 1 && !done.has(key(...c)));
    while (left.length) {
      const before = left.length;
      for (const c of left) if (!done.has(key(...c))) dig(c, false);
      left = left.filter((c) => !done.has(key(...c)));
      if (left.length === before) throw new Error(`can't reach ${left.length} cells, e.g. ${key(...left[0])}`);
    }
  }
  for (const k of own) if (!done.has(k)) throw new Error(`never dug ${k}`);
  return { ops: ops.join(''), moves, looks, end: pos };
}

// Replays a route and checks it digs and enters only cells of the volume
// (or the shaft). Returns the cells it digs, with the shaft's foot.
export function check(cells, ops) {
  let p = [...START];
  const dug = new Set([key(...START)]);
  for (const ch of ops) {
    const i = 'neswud'.indexOf(ch.toLowerCase());
    if (i < 0) continue;
    const d = DIRS[i];
    const n = [p[0] + d.dx, p[1] + d.dy, p[2] + d.dz];
    const k = key(...n);
    if (!inShaft(...n) && !cells.has(k)) throw new Error(`route digs or enters ${k}, outside the works`);
    if (!inShaft(...n)) dug.add(k);
    if (ch === d.op) p = n;
  }
  return dug;
}

// Lighting --------------------------------------------------------------------
// Monsters spawn only in full darkness. Once the works are dug, a lamplighter
// sets a torch every LIGHT_STEP blocks on every floor (a cell of the works
// with rock below it and the works above, to stand in while placing).
// Op T: place a torch below.
export const LIGHT_STEP = 7;
export function lightRoute(cells) {
  const lift = (x, y, z) => x === 0 && z === 0 && y >= 0;
  const spots = [];
  for (const k of cells) {
    const [x, y, z] = unkey(k);
    if (((x % LIGHT_STEP) + LIGHT_STEP) % LIGHT_STEP || ((z % LIGHT_STEP) + LIGHT_STEP) % LIGHT_STEP) continue;
    if (cells.has(key(x, y - 1, z)) || !cells.has(key(x, y + 1, z))) continue;
    if (inShaft(x, y + 1, z) || lift(x, y + 1, z)) continue;
    spots.push([x, y, z]);
  }
  // Top floors first, then row by row, snaking.
  spots.sort((a, b) => b[1] - a[1] || a[2] - b[2] || (a[2] % 2 ? b[0] - a[0] : a[0] - b[0]));
  const open = (k) => cells.has(k) || inShaft(...unkey(k));
  let pos = [...START];
  const ops = [];
  let moves = 0;
  for (const [x, y, z] of spots) {
    const goal = key(x, y + 1, z);
    const prev = new Map([[key(...pos), null]]);
    const queue = [pos];
    for (let i = 0; i < queue.length && !prev.has(goal); i++) {
      const c = queue[i];
      for (const d of DIRS) {
        const n = [c[0] + d.dx, c[1] + d.dy, c[2] + d.dz];
        const k = key(...n);
        if (prev.has(k) || !open(k) || lift(...n)) continue;
        prev.set(k, [key(...c), d.op]);
        queue.push(n);
      }
    }
    if (!prev.has(goal)) throw new Error(`can't reach the torch spot over ${key(x, y, z)}`);
    const path = [];
    for (let k = goal; prev.get(k); k = prev.get(k)[0]) path.push(prev.get(k)[1]);
    ops.push(...path.reverse(), 'T');
    moves += path.length;
    pos = [x, y + 1, z];
  }
  return { ops: ops.join(''), moves, torches: spots.length };
}
