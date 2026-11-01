// The Clockworks: every structure of the underground base, defined once.
//
// Each structure is a grid of characters, one per block: x east, y up,
// z south, origin at the north-west bottom corner of its bounding box.
//   ' '  leave whatever is there (natural rock)
//   '.'  clear to air
//   'P'  pod: cleared for the builder, a turtle docks here later
//   other characters map to blocks through the structure's palette
//
// Every structure has a home: the cell just outside a doorway where the
// builder turtle starts, facing in, with its supply chest right below it.
//
// generate.mjs turns these into turtle blueprints (programs/blueprints),
// render data for the design page and Create schematics (.nbt).

// Shared palette: Factory Blocks in dark greys with green accents, and Create's
// andesite bars for railings and grilles. Only blocks that do a job are
// anything else: CC modems, cables, chests, monitors and computers, and dirt
// for the planting beds. Factory Blocks give no light: the green panels stand
// where lamps would go.
export const BLOCKS = {
  B: 'factory_blocks:circuit',         // dark grey circuit: the main shell
  R: 'factory_blocks:wireframe',       // dark grid ribs
  W: 'factory_blocks:gvent',           // green-striped vents between decks
  X: 'factory_blocks:sturdy',          // berth sills
  I: 'factory_blocks:wgpanel',         // green panel behind each berth
  G: 'factory_blocks:grate',           // walkways
  F: 'factory_blocks:large_plating',   // deck plating
  K: 'factory_blocks:piping',          // pipework round the spine
  Q: 'factory_blocks:old_vents',       // vent runs
  E: 'factory_blocks:engineer',        // gauge panels
  Y: 'factory_blocks:fan',             // the Mainspring's fans
  V: 'factory_blocks:old_vents',       // vents
  Z: 'create:andesite_bars',          // railings
  z: 'factory_blocks:gvent',           // green lanes in the hall floor
  H: 'factory_blocks:wireframe',       // trim
  S: 'factory_blocks:sturdy',          // heavy frames
  M: 'computercraft:wired_modem_full', // network: modem blocks
  C: 'minecraft:chest',                // spine and rack storage
  c: 'computercraft:cable',            // networking cable in the floors
  N: 'computercraft:monitor_advanced', // the Bridge's monitor wall
  O: 'computercraft:computer_advanced',
  L: 'factory_blocks:wgpanel',         // green panels where lamps would be
  l: 'factory_blocks:wgpanel',
  g: 'create:andesite_bars',          // cages
  t: 'create:andesite_bars',          // window grilles
  w: 'factory_blocks:hex',             // the Hatchery's hex panelling
  D: 'minecraft:dirt',                 // planting beds
  p: 'factory_blocks:large_plating',   // hall floor
};

// Grid helpers ------------------------------------------------------------

function grid(name, sx, sy, sz, fill = ' ') {
  const cells = new Array(sx * sy * sz).fill(fill);
  const g = {
    name, size: { x: sx, y: sy, z: sz },
    cells,
    get(x, y, z) {
      if (x < 0 || y < 0 || z < 0 || x >= sx || y >= sy || z >= sz) return null;
      return cells[(y * sz + z) * sx + x];
    },
    set(x, y, z, ch) {
      if (x < 0 || y < 0 || z < 0 || x >= sx || y >= sy || z >= sz) return;
      cells[(y * sz + z) * sx + x] = ch;
    },
    // Calls f(x, y, z, d, angle) for every cell, d and angle around (cx, cz).
    each(f, cx = (sx - 1) / 2, cz = (sz - 1) / 2) {
      for (let y = 0; y < sy; y++)
        for (let z = 0; z < sz; z++)
          for (let x = 0; x < sx; x++)
            f(x, y, z, Math.hypot(x - cx, z - cz), Math.atan2(z - cz, x - cx));
    },
  };
  return g;
}

// Cuts doorways through a structure's outer walls. face: 'n' (z=0),
// 's' (z=max), 'w' (x=0), 'e' (x=max); a..b along the wall, y0..y1 high.
function doors(g, list = []) {
  const { x: X, z: Z } = g.size;
  for (const d of list) {
    for (let i = d.a; i <= d.b; i++) {
      for (let y = d.y0 ?? 1; y <= (d.y1 ?? 3); y++) {
        // Through the wall and one block in, so a pod ring or rack can't block it.
        for (let k = 0; k < (d.depth ?? 1); k++) {
          if (d.face === 'n') g.set(i, y, k, '.');
          if (d.face === 's') g.set(i, y, Z - 1 - k, '.');
          if (d.face === 'w') g.set(k, y, i, '.');
          if (d.face === 'e') g.set(X - 1 - k, y, i, '.');
        }
      }
    }
  }
}

const TAU = Math.PI * 2;
// True when angle a is within w radians of one of n evenly spaced spokes
// (offset by off of a spoke).
function spoke(a, n, w, off = 0) {
  const step = TAU / n;
  let r = ((a - off) % step + step) % step;
  return Math.min(r, step - r) < w;
}

// Blending -------------------------------------------------------------------
// Surfaces are mostly one block with a scattering of similar ones, picked by a
// fixed hash of the position so every build comes out the same.
function hash(x, y, z, seed = 0) {
  let h = (x * 374761393 + y * 668265263 + z * 2147483647 + seed * 144665) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}
function mix(list) {
  return (x, y, z, seed) => {
    let r = hash(x, y, z, seed);
    for (const [ch, w] of list) { if (r < w) return ch; r -= w; }
    return list[0][0];
  };
}
const SHELL = mix([['B', 0.62], ['R', 0.18], ['Q', 0.12], ['S', 0.06], ['W', 0.02]]);
const FLOOR = mix([['F', 0.7], ['S', 0.15], ['G', 0.1], ['Q', 0.05]]);
const CAP = mix([['S', 0.5], ['F', 0.3], ['B', 0.2]]);

// Bridges --------------------------------------------------------------------
// Five wide at height y0: grate underfoot, andesite bars two high along both
// edges and three wide to walk between them. A span runs along axis at `at`,
// from `from` to `to`; with `top` it starts that high and steps down a block
// a block until it reaches y0. Where spans meet, the bars give way.
const BRIDGE_Y = 10;
function bridges(g, list, y0 = BRIDGE_Y) {
  const walk = new Map(), rails = [];
  for (const { axis, at, from, to, top } of list) {
    for (let i = from; i <= to; i++) {
      const y = top ? Math.max(y0, top - (i - from)) : y0;
      for (let w = -2; w <= 2; w++) {
        const [x, z] = axis === 'x' ? [i, at + w] : [at + w, i];
        g.set(x, y, z, 'G');
        if (Math.abs(w) < 2) walk.set(x + ',' + z, y); else rails.push([x, y, z]);
      }
    }
  }
  for (const [x, y, z] of rails) {
    if (walk.has(x + ',' + z)) continue;
    for (let h = 1; h <= 2; h++) g.set(x, y + h, z, 'Z');
  }
  for (const [k, y] of walk) {
    const [x, z] = k.split(',').map(Number);
    for (let h = 1; h <= 2; h++) g.set(x, y + h, z, '.');
  }
}

// A spiral stair in the ring r0 < d <= r1 round the middle: sixteen steps a
// turn, clockwise from angle a0, one block up a step from the floor at y0 to
// the floor at y1. Headroom is cut through any floor in the way.
function spiral(g, { r0, r1, a0, y0, y1 }) {
  const step = TAU / 16;
  g.each((x, y, z, d, a) => {
    if (y !== 0 || d <= r0 || d > r1) return;
    const h = y0 + 1 + Math.floor((((a - a0) % TAU) + TAU) % TAU / step);
    if (h > y1) return;
    g.set(x, h, z, 'G');
    // Three clear above a step: room to jump to the next.
    if (h < y1) for (let k = 1; k <= 3; k++) g.set(x, h + k, z, '.');
  });
}

// The Hive -------------------------------------------------------------------
// A column of blended dark plating. Turtles sit on the outside in vertical
// strips five wide, the full height of the column; behind every turtle is a
// wired modem block in the shell, so each strip is one network, cabled to a
// spine of modems and chests inside. Nobody goes in: the Hive runs itself.
// The inside is an empty shaft round the spine, with cables out to the strips
// every four blocks, and the only way in is a port one block square at the
// foot, for the builder and for turtles.
const HIVE_PORT = [{ face: 'n', a: 8, b: 8, y0: 2, y1: 2, depth: 3 }]; // above the cable at y 1
export function stack({ R = 6, levels = 4, levelH = 4, strips = 4, stripW = 5, doorways = HIVE_PORT } = {}) {
  const c = R + 2;                          // a two-wide open ring outside the shell
  const size = 2 * c + 1;
  const H = 1 + levels * levelH + 1;
  const g = grid('stack', size, H, size);
  g.each((x, y, z, d) => {
    if (d > R + 2) return;                  // beyond the ring: leave the rock
    // An open ring round the shell, two wide so it joins up all the way round
    // (one wide, a circle only touches at corners). The turtle strips stand in
    // its inner half.
    if (d > R + 0.5) { g.set(x, y, z, '.'); return; }
    // The spine: modems on odd layers, chests between.
    if (x === c && z === c) { g.set(x, y, z, y % 2 === 1 ? 'M' : 'C'); return; }
    if (y === 0 || y === H - 1) { g.set(x, y, z, CAP(x, y, z)); return; }
    if (d > R - 0.5) { g.set(x, y, z, SHELL(x, y, z)); return; }
    g.set(x, y, z, '.');
  });
  // The turtle strips, on the diagonals (the port is on a compass point).
  const ring = [];
  g.each((x, y, z, d, a) => { if (y === 0 && d > R + 0.5 && d <= R + 1.5) ring.push({ x, z, a }); });
  ring.sort((p, q) => p.a - q.a);
  let turtles = 0;
  for (let k = 0; k < strips; k++) {
    const centre = -Math.PI + (k + 0.5) * TAU / strips;
    let best = 0;
    ring.forEach((p, i) => {
      const diff = (q) => Math.abs(Math.atan2(Math.sin(q - centre), Math.cos(q - centre)));
      if (diff(p.a) < diff(ring[best].a)) best = i;
    });
    for (let j = -Math.floor(stripW / 2); j <= Math.floor(stripW / 2); j++) {
      const p = ring[(best + j + ring.length) % ring.length];
      // The shell block touching this turtle (not just diagonally) is its modem.
      const shell = (x, z) => { const d = Math.hypot(x - c, z - c); return d > R - 0.5 && d <= R + 0.5; };
      const [bx, bz] = [[1, 0], [-1, 0], [0, 1], [0, -1]]
        .map(([dx, dz]) => [p.x + dx, p.z + dz])
        .filter(([x, z]) => shell(x, z))
        .sort((u, v) => Math.hypot(u[0] - c, u[1] - c) - Math.hypot(v[0] - c, v[1] - c))[0];
      g.set(p.x, 0, p.z, 'S');              // sill under the strip
      g.set(p.x, H - 1, p.z, 'S');          // cap over it
      for (let y = 1; y < H - 1; y++) {
        g.set(p.x, y, p.z, 'P');
        g.set(bx, y, bz, 'M');
        turtles++;
      }
    }
    // Where two of the strip's modems meet only at a corner, a modem in the
    // corner joins them: modems link face to face, like cables.
    const mods = [];
    for (let z = 0; z < size; z++) for (let x = 0; x < size; x++) {
      if (g.get(x, 1, z) === 'M' && !(x === c && z === c)) {
        const a = Math.atan2(z - c, x - c);
        if (Math.abs(Math.atan2(Math.sin(a - centre), Math.cos(a - centre))) < 0.9) mods.push({ x, z, a });
      }
    }
    mods.sort((p, q) => p.a - q.a);
    for (let i = 1; i < mods.length; i++) {
      const p = mods[i - 1], q = mods[i];
      if (Math.abs(p.x - q.x) === 1 && Math.abs(p.z - q.z) === 1) {
        // The corner nearer the middle of the column stays inside the shell.
        const [jx, jz] = [[p.x, q.z], [q.x, p.z]].sort((u, v) => Math.hypot(u[0] - c, u[1] - c) - Math.hypot(v[0] - c, v[1] - c))[0];
        for (let y = 1; y < H - 1; y++) g.set(jx, y, jz, 'M');
      }
    }
    // Every four blocks a cable from the middle turtle's modem to the spine.
    // Cables only join face to face, so it runs along x, then along z.
    const mid = ring[best];
    const [mx, mz] = [[1, 0], [-1, 0], [0, 1], [0, -1]]
      .map(([dx, dz]) => [mid.x + dx, mid.z + dz])
      .find(([x, z]) => g.get(x, 1, z) === 'M');
    for (let lv = 0; lv < levels; lv++) {
      const y = 1 + lv * levelH;
      let x = mx, z = mz;
      while (Math.abs(x - c) + Math.abs(z - c) > 1) {
        if (x !== c) x += Math.sign(c - x); else z += Math.sign(c - z);
        // Modems carry the network too: pass through them, don't replace them.
        if (!(x === c && z === c) && g.get(x, y, z) !== 'M') g.set(x, y, z, 'c');
      }
    }
  }
  // A cable riser beside the spine joins its modems.
  for (let y = 1; y < H; y++) g.set(c, y, c - 1, "c");
  doors(g, doorways);
  return {
    ...g, title: 'Turtle Hive', home: { x: c, y: 1, z: -1, face: 's' },
    blurb: `A column of blended dark plating with ${turtles} turtles on the outside, in ${strips} strips ${stripW} wide the full height, each turtle on a modem wired to a spine of modems and chests inside. Sealed: only turtles go in, through a port at the foot.`,
  };
}

// The Fields ---------------------------------------------------------------
// Doorways to the rooms around it, and the opening the HQ looks out through.
const FIELD_DOORS = [
  { face: 'w', a: 23, b: 25 },              // the Archive
  { face: 'e', a: 23, b: 25 },              // Zion Hydroponics
  { face: 's', a: 23, b: 25 },              // the Construct
  { face: 'n', a: 17, b: 31, y0: 17, y1: 21 }, // the HQ window
];
// The great hall the stacks stand in: excavated rock, a polished floor with
// caution-striped walkways, and a grid of green ceiling lights.
// One bridge, ten blocks above the hall floor: from the Mainspring's gallery
// to a stair up to the Bridge.
// Coordinates are the hall's own: from, to along the bridge, at the centre line.
// It passes between Hives A and B without touching them: the Hives are
// turtles' ground.
const BRIDGES = [
  { axis: 'z', at: 24, from: 0, to: 19, top: 16 }, // from the Bridge, a stair down, then on to the Mainspring
];

// The hall walls: plating over a sturdy plinth, ribbed every eight blocks
// (between the lamps), with a scattering of vents.
const WALL = mix([['B', 0.6], ['F', 0.22], ['Q', 0.12], ['W', 0.06]]);
function hallWall(x, y, z) {
  if (y === 1) return 'S';
  const along = x === 0 || x === 48 ? z : x;
  return along % 8 === 4 ? 'R' : WALL(x, y, z, 6);
}
// Where the lift and the service shaft pass through the hall's ceiling
// (hall cells: the Mainspring's middle, and three east of it).
const LIFT_XZ = [24, 24], SERVICE_XZ = [27, 24];

export function fields({ X = 49, Y = 24, Z = 49, doorways = FIELD_DOORS, spans = BRIDGES } = {}) {
  const g = grid('fields', X, Y, Z);
  g.each((x, y, z) => {
    const edge = x === 0 || z === 0 || x === X - 1 || z === Z - 1;
    if (y === 0) {
      const lane = (x % 16 === 8) || (z % 16 === 8);
      g.set(x, y, z, edge ? 'S' : FLOOR(x, y, z, 2));
    } else if (y === Y - 1) {
      g.set(x, y, z, x % 6 === 3 && z % 6 === 3 ? 'L' : ' ');
    } else if (!edge) {
      g.set(x, y, z, '.');
    } else if (y % 6 === 3 && (x + z) % 8 === 0) {
      g.set(x, y, z, 'L');
    } else {
      g.set(x, y, z, hallWall(x, y, z));
    }
  });
  // The lift comes down through the ceiling to the Mainspring's roof, with
  // the turtles' service shaft beside it.
  for (const [x, z] of [LIFT_XZ, SERVICE_XZ]) g.set(x, Y - 1, z, '.');
  doors(g, doorways);
  bridges(g, spans);
  return { ...g, title: 'The Engine Hall', home: { x: 24, y: 1, z: Z, face: 'n' }, blurb: 'The great hall: grey plating with green lanes and clad walls, room for four Hives and the Mainspring, and a bar-railed bridge from the Mainspring up to the Bridge.' };
}

// Nebuchadnezzar -------------------------------------------------------------
// The HQ bridge: a round control room with a curved wall of monitors,
// console desks, a hex-floored centre with a glowing holo table and a
// tinted window looking out over the Fields.
export function hq({ R = 8, Hh = 7, doorways = [{ face: 'w', a: 7, b: 9, depth: 2 }, { face: 's', a: 7, b: 9, depth: 2 }] } = {}) {
  const size = 2 * R + 1;
  const g = grid('hq', size, Hh, size);
  g.each((x, y, z, d, a) => {
    if (d > R + 0.5) return;
    if (y === 0) { g.set(x, y, z, d < 2.5 ? 'X' : d > R - 0.5 ? 'S' : (d > R - 2.5 ? 'F' : 'G')); return; }
    if (y === Hh - 1) { g.set(x, y, z, CAP(x, y, z, 3)); return; }
    if (d > R - 0.5) {
      const north = Math.abs(a + Math.PI / 2) < 0.9;     // monitor wall
      const south = Math.abs(a - Math.PI / 2) < 0.7;     // window
      if (north && y >= 2 && y <= 4) g.set(x, y, z, 'N');
      else if (south && y >= 2 && y <= 4) g.set(x, y, z, 't');
      else if (y === 1) g.set(x, y, z, 'E');
      else g.set(x, y, z, SHELL(x, y, z, 3));
      return;
    }
    // Console ring facing the monitors, and the holo table in the middle.
    if (y === 1 && Math.abs(d - (R - 2)) < 0.5 && Math.abs(a + Math.PI / 2) < 1.0) { g.set(x, y, z, 'E'); return; }
    if (y === 1 && d < 1.5) { g.set(x, y, z, x === R && z === R ? 'O' : 'Y'); return; }
    if (y === 2 && d < 1.5) { g.set(x, y, z, 'g'); return; }
    g.set(x, y, z, '.');
  });
  doors(g, doorways);
  return { ...g, title: 'The Bridge', home: { x: -1, y: 1, z: R, face: 'e' }, blurb: 'The command room: a wall of monitors in iron frames, gauge desks, a chart table and a window over the Engine Hall.' };
}

// The Archive --------------------------------------------------------------
// Server aisles: rows of racks (chests with a wired modem on top), cold
// aisles with grates over cable bundles and hot aisles with vents.
export function archive({ rows = 3, rackLen = 9, Hh = 6, doorways = [{ face: 'e', a: 5, b: 7 }] } = {}) {
  const X = rackLen + 4, Z = rows * 3 + 2;
  const g = grid('archive', X, Hh, Z);
  g.each((x, y, z) => {
    const wall = x === 0 || z === 0 || x === X - 1 || z === Z - 1;
    if (y === 0) { g.set(x, y, z, wall ? 'S' : (z % 3 === 2 ? 'Q' : 'G')); return; }
    if (y === Hh - 1) { g.set(x, y, z, wall ? 'S' : (z % 3 === 2 && x % 3 === 1 ? 'L' : 'V')); return; }
    if (wall) { g.set(x, y, z, SHELL(x, y, z, 4)); return; }
    const rack = z % 3 === 1 && x >= 2 && x < X - 2;
    if (rack && y <= 3) g.set(x, y, z, y === 3 ? 'M' : 'C');
    else if (rack && y === 4) g.set(x, y, z, 'K');
    else g.set(x, y, z, '.');
  });
  doors(g, doorways);
  return { ...g, title: 'The Ledger Room', home: { x: X, y: 1, z: 6, face: 'w' }, blurb: 'Aisles of chest racks on the factory network, under vents and pipework: storage that grows.' };
}

// The Construct ------------------------------------------------------------
// The white room where newborn turtles are loaded: white walls, a lit floor
// and a single chair-like pedestal for the birth spot.
export function construct({ S = 11, Hh = 7, doorways = [{ face: 'n', a: 4, b: 6 }] } = {}) {
  const g = grid('construct', S, Hh, S);
  g.each((x, y, z) => {
    const wall = x === 0 || z === 0 || x === S - 1 || z === S - 1;
    if (y === 0) { g.set(x, y, z, (x + z) % 4 === 0 && !wall ? 'l' : 'w'); return; }
    if (y === Hh - 1 || wall) { g.set(x, y, z, 'w'); return; }
    const mid = (S - 1) / 2;
    if (x === mid && z === mid && y === 1) { g.set(x, y, z, 'Y'); return; }
    if (x === mid && z === mid && y === 2) { g.set(x, y, z, 'P'); return; }
    g.set(x, y, z, '.');
  });
  doors(g, doorways);
  return { ...g, title: 'The Hatchery', home: { x: 5, y: 1, z: -1, face: 's' }, blurb: 'A padded room where newborn turtles are put together and wound up.' };
}

// Zion Hydroponics -----------------------------------------------------------
// The underground tree bay: dirt beds under green grow lights, behind green
// glass, for the pine farm's next home.
export function hydroponics({ X = 17, Hh = 12, Z = 9, doorways = [{ face: 'w', a: 3, b: 5 }] } = {}) {
  const g = grid('hydroponics', X, Hh, Z);
  g.each((x, y, z) => {
    const wall = x === 0 || z === 0 || x === X - 1 || z === Z - 1;
    if (y === 0) { g.set(x, y, z, wall ? 'S' : 'F'); return; }
    if (y === Hh - 1) { g.set(x, y, z, wall ? 'S' : (x % 3 === 1 && z % 2 === 1 ? 'L' : CAP(x, y, z, 5))); return; }
    if (wall) { g.set(x, y, z, z === Z - 1 && y >= 2 && y <= Hh - 3 ? 't' : SHELL(x, y, z, 5)); return; }
    if (y === 1) { g.set(x, y, z, z === 4 && x % 4 === 2 ? 'D' : 'G'); return; }
    g.set(x, y, z, '.');
  });
  doors(g, doorways);
  return { ...g, title: 'The Conservatory', home: { x: -1, y: 1, z: 4, face: 'e' }, blurb: 'A barred growing house: the pine farm, moved underground (once it has light).' };
}

// The Core ------------------------------------------------------------------
// The fan tower in the middle of the hall and its way up: a spiral stair
// from the floor to a gallery level with the bridge, and a door onto it.
const CORE_DOORS = [
  { face: 'n', a: 3, b: 5, depth: 2 }, { face: 'e', a: 3, b: 5, depth: 2 },
  { face: 'n', a: 3, b: 5, y0: 10, y1: 12, depth: 2 },
];
export function core({ R = 4, Hh = 14, doorways = CORE_DOORS } = {}) {
  const size = 2 * R + 1;
  const g = grid('core', size, Hh, size);
  g.each((x, y, z, d, a) => {
    if (d > R + 0.5) return;
    if (y === 0) { g.set(x, y, z, d > R - 0.5 ? 'H' : 'S'); return; }
    // The lift's landing: the elevator turtle stops in the middle of the roof.
    if (y === Hh - 1) { g.set(x, y, z, d < 0.5 ? 'P' : d < 1.5 ? 'L' : 'S'); return; }
    if (d < 0.5) { g.set(x, y, z, 'L'); return; }
    if (d < 1.5) { g.set(x, y, z, y % 4 === 0 ? 'Q' : 'Y'); return; }
    if (d > R - 0.5) { g.set(x, y, z, y === 5 || y === 9 ? 'Z' : (spoke(a, 6, 0.25) ? 'K' : 'g')); return; }
    g.set(x, y, z, y === 9 ? 'G' : '.');
  });
  doors(g, doorways);
  // From south-south-east round by the west to the north, so the stairwell
  // opens clear of the doors.
  spiral(g, { r0: 1.5, r1: R - 0.5, a0: 1.18, y0: 0, y1: 9 });
  return { ...g, title: 'The Mainspring', home: { x: R, y: 1, z: -1, face: 's' }, blurb: 'A tower of fans round a central shaft, with a spiral stair up to a gallery behind andesite bars and a door onto the bridge to the Bridge: the way up in the Engine Hall.' };
}

export const STRUCTURES = { stack, fields, hq, archive, construct, hydroponics, core };

// The site plan: where each structure sits, relative to the bottom of the
// lift (x east, y up, z south). The elevator turtle (Otis, turtle-9) waits
// at the top at world (3547, 71, 4754) and stops 71 blocks down its shaft,
// at world y 0, in the middle of the Mainspring's roof; the works are laid
// out round that point. The service shaft for turtles runs down three
// blocks east of the lift, from world y 77; above y 60 nothing else is dug.
// Turtles come from the factory turtle (Forgemother), facing north.
export const LIFT = { depth: 71, at: [3547, 0, 4754] };
export const SERVICE = [3, 0, 0];
export const SERVICE_TOP = 77;
export const FACTORY = [3559, 74, 4763];
export const SITE = [
  { id: 'fields', at: [-24, -14, -24] },
  { id: 'stack', at: [-20, -13, -20], name: 'Hive A' },
  { id: 'stack', at: [4, -13, -20], name: 'Hive B' },
  { id: 'stack', at: [-20, -13, 4], name: 'Hive C' },
  { id: 'stack', at: [4, -13, 4], name: 'Hive D' },
  { id: 'core', at: [-4, -13, -4] },
  { id: 'hq', at: [-8, 2, -41] },
  { id: 'archive', at: [-37, -13, -6] },
  { id: 'hydroponics', at: [25, -13, -4] },
  { id: 'construct', at: [-5, -13, 25] },
];
