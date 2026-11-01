// The dig: everything the works occupy, cleared to air before anything is
// built, and the route an excavator turtle takes to do it.
//
// The volume is every cell any structure sets (air or block): rock stays only
// where every structure says to leave it. Walls, floors and roofs are dug too,
// so the builders only place. The lift's own column is never touched.
//
// The excavator comes down the service shaft beside the lift: placed on the
// lift's east side at the top, facing west into the shaft, it digs straight
// down until the shaft beside it ends. That is one block below the lift's
// bottom, at (1, -1, 0) in site coordinates (x east, y up, z south, origin at
// the lift's bottom), where the route starts.
//
// The route works down in slabs three high: the turtle walks the middle layer
// row by row, digging up and down as it goes, then digs what's left from the
// side. It only ever stands in cells it has dug or in the service shaft.
//
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

export function route(cells) {
  let minY = Infinity, maxY = -Infinity;
  for (const k of cells) { const y = unkey(k)[1]; minY = Math.min(minY, y); maxY = Math.max(maxY, y); }
  const [sx, , sz] = SERVICE;
  const service = (x, y, z) => x === sx && z === sz && y >= -1 && y <= maxY;
  const lift = (x, y, z) => x === 0 && z === 0 && y >= 0;
  const done = new Set();
  const standable = (k) => done.has(k) || service(...unkey(k));
  let pos = [sx, -1, sz];
  for (let y = -1; y <= maxY; y++) done.add(key(sx, y, sz)); // dug on the way down
  const ops = [];
  let moves = 0, looks = 0;

  const dirTo = (a, b) => DIRS.find((d) => a[0] + d.dx === b[0] && a[1] + d.dy === b[1] && a[2] + d.dz === b[2]);
  const step = (d) => { ops.push(d.op); pos = [pos[0] + d.dx, pos[1] + d.dy, pos[2] + d.dz]; moves++; };

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
        if (prev.has(k) || !standable(k)) continue;
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
    done.add(key(...target));
    if (moveIn) step(d); else ops.push(d.op.toUpperCase());
    return true;
  }

  // Once standing in a cell: dig above and below, and look at kept rock.
  function standHere() {
    for (const d of DIRS.slice(4)) {
      const n = [pos[0] + d.dx, pos[1] + d.dy, pos[2] + d.dz];
      if (cells.has(key(...n)) && !done.has(key(...n)) && Math.abs(n[1] - slabMid) <= 1) {
        ops.push(d.op.toUpperCase()); done.add(key(...n));
      }
    }
    DIRS.forEach((d, i) => {
      const n = [pos[0] + d.dx, pos[1] + d.dy, pos[2] + d.dz];
      if (!cells.has(key(...n)) && !service(...n) && !lift(...n) && !done.has(key(...n))) { ops.push(String(i)); looks++; }
    });
  }

  let slabMid = 0, slab = 0;
  for (let m = maxY - 1; m - 1 <= maxY && m + 1 >= minY; m -= 3, slab++) {
    slabMid = m;
    // The middle layer, row by row, snaking.
    const layer = [...cells].map(unkey).filter((c) => c[1] === m);
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
        const entry = layer.find((c) => !done.has(key(...c)) && cells.has(key(c[0], m + 1, c[2])) &&
          !done.has(key(c[0], m + 1, c[2])) && touches([c[0], m + 1, c[2]]));
        if (!entry || !dig([entry[0], m + 1, entry[2]], true)) throw new Error(`can't reach ${todo} cells of layer ${m}`);
      }
    }
    // What's left of the slab, dug from beside it.
    let left = [...cells].map(unkey).filter((c) => Math.abs(c[1] - m) <= 1 && !done.has(key(...c)));
    while (left.length) {
      const before = left.length;
      for (const c of left) if (!done.has(key(...c))) dig(c, false);
      left = left.filter((c) => !done.has(key(...c)));
      if (left.length === before) throw new Error(`can't reach ${left.length} cells, e.g. ${key(...left[0])}`);
    }
  }
  for (const k of cells) if (!done.has(k)) throw new Error(`never dug ${k}`);
  return { ops: ops.join(''), moves, looks, end: pos };
}

// Replays a route and checks it: it digs every cell of the volume and stands
// only in dug cells or the service shaft.
export function check(cells, ops) {
  const [sx, , sz] = SERVICE;
  let p = [sx, -1, sz];
  const dug = new Set();
  for (const k of cells) { const [x, y, z] = unkey(k); if (x === sx && z === sz && y >= -1) dug.add(k); } // on the way down
  for (const ch of ops) {
    const i = 'neswud'.indexOf(ch.toLowerCase());
    if (i < 0) continue;
    const d = DIRS[i];
    const n = [p[0] + d.dx, p[1] + d.dy, p[2] + d.dz];
    const k = key(...n);
    const shaft = n[0] === sx && n[2] === sz && n[1] >= -1;
    if (!shaft && !cells.has(k)) throw new Error(`route digs or enters ${k}, outside the works`);
    if (!shaft) dug.add(k);
    if (ch === d.op) p = n;
  }
  for (const k of cells) if (!dug.has(k)) throw new Error(`route misses ${k}`);
  return dug.size;
}
