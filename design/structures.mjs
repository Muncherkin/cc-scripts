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

// Shared palette: Factory Blocks in dark greys with green accents, and heavy
// iron bars for railings and berth cages. Only blocks that do a job are
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
  Z: 'minecraft:iron_bars',            // railings
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
  g: 'minecraft:iron_bars',            // berth cages
  t: 'minecraft:iron_bars',            // window grilles
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

// The Stack -----------------------------------------------------------------
// A pod column: a cylinder of black circuit panels, LEVELS floors high. Eight
// pods per floor hold docked turtles facing a central spine of wired modems
// and chests, wired to it with cable under the grates. Green light glows
// between the pods.
// Doorways: in at the hall floor (north and south) and out onto the bridges
// at the third deck (every face).
const HIVE_DOORS = [
  { face: 'n', a: 5, b: 7, depth: 2 }, { face: 's', a: 5, b: 7, depth: 2 },
  ...['n', 's', 'e', 'w'].map((face) => ({ face, a: 5, b: 7, y0: 10, y1: 12, depth: 2 })),
];
export function stack({ R = 6, levels = 4, levelH = 4, doorways = HIVE_DOORS } = {}) {
  const size = 2 * R + 1;
  const H = 1 + levels * levelH + 1;
  const g = grid('stack', size, H, size);
  const c = R;
  const PODS = 8;
  // Shell, floors and spine first.
  g.each((x, y, z, d, a) => {
    if (d > R + 0.5) return; // outside: leave the rock
    if (x === c && z === c) { g.set(x, y, z, y % 2 === 0 ? 'M' : 'C'); return; } // the spine
    if (y === 0) { g.set(x, y, z, d > R - 0.5 ? 'S' : 'F'); return; }
    if (y === H - 1) {
      g.set(x, y, z, d > R - 0.5 ? 'S' : (Math.abs(d - 3) < 0.5 && spoke(a, 8, 0.2) ? 'L' : 'B'));
      return;
    }
    const ly = (y - 1) % levelH;            // 0 is the floor of a level
    if (d > R - 0.5) {                      // the shell
      if (ly === 0) g.set(x, y, z, 'W');
      else if (spoke(a, PODS, 0.16)) g.set(x, y, z, 'R');        // ribs
      else if (ly === 2 && spoke(a, PODS, 0.12, Math.PI / PODS / 2)) g.set(x, y, z, 'L'); // light slits
      else g.set(x, y, z, 'B');
    } else if (ly === 0) {                  // walkway floor, with a hatch
      g.set(x, y, z, x === c + 3 && z === c ? '.' : (d <= 1.5 ? 'K' : 'G'));
    } else {
      g.set(x, y, z, '.');
    }
  });
  // Then exactly one pod per slot: a turtle in the ring, its network port and
  // light panel in the shell behind it, glass above, cable to the spine.
  for (let k = 0; k < PODS; k++) {
    const t = (k + 0.5) * TAU / PODS;
    const at = (r) => [Math.round(c + r * Math.cos(t)), Math.round(c + r * Math.sin(t))];
    const [px, pz] = at(R - 1);
    const [wx, wz] = at(R);
    for (let lv = 0; lv < levels; lv++) {
      const y0 = 1 + lv * levelH;
      g.set(px, y0, pz, 'X');               // pod sill
      g.set(px, y0 + 1, pz, 'P');           // the turtle
      g.set(px, y0 + 2, pz, 'g');           // glass canopy
      g.set(wx, y0 + 1, wz, 'M');           // network port behind it
      g.set(wx, y0 + 2, wz, 'I');           // pod light panel
      for (let r = 2; r <= R - 2; r++) {    // cable under the grate
        const [cx, cz] = at(r);
        g.set(cx, y0, cz, 'c');
      }
    }
  }
  doors(g, doorways);
  return {
    ...g, title: 'Turtle Hive', home: { x: c, y: 1, z: -1, face: 's' },
    blurb: `A dark tower of ${levels} decks with ${levels * PODS} caged berths for turtles, round a spine of modems and chests, with bridge doors on the third deck.`,
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
// Bridges between the Hives at their third deck, ten blocks above the hall
// floor: three wide, grate underfoot, iron bars two high on both sides.
// Coordinates are the hall's own: from, to along the bridge, at the centre line.
const BRIDGES = [
  { axis: 'x', at: 12, from: 19, to: 29 }, // Hive A to Hive B
  { axis: 'x', at: 36, from: 19, to: 29 }, // Hive C to Hive D
  { axis: 'z', at: 12, from: 19, to: 29 }, // Hive A to Hive C
  { axis: 'z', at: 36, from: 19, to: 29 }, // Hive B to Hive D
];
const BRIDGE_Y = 10;

function bridge(g, { axis, at, from, to }) {
  for (let i = from; i <= to; i++) {
    for (let w = -1; w <= 1; w++) {
      const [x, z] = axis === 'x' ? [i, at + w] : [at + w, i];
      g.set(x, BRIDGE_Y, z, 'G');
      for (let h = 1; h <= 2; h++) g.set(x, BRIDGE_Y + h, z, w === 0 ? '.' : 'Z');
    }
  }
}

export function fields({ X = 49, Y = 24, Z = 49, doorways = FIELD_DOORS, bridges = BRIDGES } = {}) {
  const g = grid('fields', X, Y, Z);
  g.each((x, y, z) => {
    const edge = x === 0 || z === 0 || x === X - 1 || z === Z - 1;
    if (y === 0) {
      const lane = (x % 16 === 8) || (z % 16 === 8);
      g.set(x, y, z, edge ? 'S' : lane ? 'z' : 'p');
    } else if (y === Y - 1) {
      g.set(x, y, z, x % 6 === 3 && z % 6 === 3 ? 'L' : ' ');
    } else if (!edge) {
      g.set(x, y, z, '.');
    } else if (y % 6 === 3 && (x + z) % 8 === 0) {
      g.set(x, y, z, 'L');
    }
  });
  doors(g, doorways);
  for (const b of bridges) bridge(g, b);
  return { ...g, title: 'The Engine Hall', home: { x: 24, y: 1, z: Z, face: 'n' }, blurb: 'The great hall: grey plating with green lanes, room for four Hives and the Mainspring, and iron-railed bridges between the Hives.' };
}

// Nebuchadnezzar -------------------------------------------------------------
// The HQ bridge: a round control room with a curved wall of monitors,
// console desks, a hex-floored centre with a glowing holo table and a
// tinted window looking out over the Fields.
export function hq({ R = 8, Hh = 7, doorways = [{ face: 'w', a: 7, b: 9, depth: 2 }] } = {}) {
  const size = 2 * R + 1;
  const g = grid('hq', size, Hh, size);
  g.each((x, y, z, d, a) => {
    if (d > R + 0.5) return;
    if (y === 0) { g.set(x, y, z, d < 2.5 ? 'X' : d > R - 0.5 ? 'S' : (d > R - 2.5 ? 'F' : 'G')); return; }
    if (y === Hh - 1) { g.set(x, y, z, Math.abs(d - (R - 2)) < 0.5 && spoke(a, 10, 0.15) ? 'L' : 'B'); return; }
    if (d > R - 0.5) {
      const north = Math.abs(a + Math.PI / 2) < 0.9;     // monitor wall
      const south = Math.abs(a - Math.PI / 2) < 0.7;     // window
      if (north && y >= 2 && y <= 4) g.set(x, y, z, 'N');
      else if (south && y >= 2 && y <= 4) g.set(x, y, z, 't');
      else if (y === 1) g.set(x, y, z, 'E');
      else g.set(x, y, z, spoke(a, 12, 0.12) ? 'R' : 'B');
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
    if (wall) { g.set(x, y, z, y === 2 && x % 4 === 2 ? 'L' : 'B'); return; }
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
    if (y === Hh - 1) { g.set(x, y, z, wall ? 'S' : (x % 3 === 1 && z % 2 === 1 ? 'L' : 'B')); return; }
    if (wall) { g.set(x, y, z, z === Z - 1 && y >= 2 && y <= Hh - 3 ? 't' : 'B'); return; }
    if (y === 1) { g.set(x, y, z, z === 4 && x % 4 === 2 ? 'D' : 'G'); return; }
    g.set(x, y, z, '.');
  });
  doors(g, doorways);
  return { ...g, title: 'The Conservatory', home: { x: -1, y: 1, z: 4, face: 'e' }, blurb: 'A barred growing house: the pine farm, moved underground (once it has light).' };
}

// The Core ------------------------------------------------------------------
// A battery tower in the middle of the Fields: megacells around a green
// light column, ringed by glass and caution-striped catwalks.
export function core({ R = 4, Hh = 14, doorways = [{ face: 'n', a: 4, b: 4, depth: 2 }] } = {}) {
  const size = 2 * R + 1;
  const g = grid('core', size, Hh, size);
  g.each((x, y, z, d, a) => {
    if (d > R + 0.5) return;
    if (y === 0) { g.set(x, y, z, d > R - 0.5 ? 'H' : 'S'); return; }
    if (y === Hh - 1) { g.set(x, y, z, d < 1.5 ? 'L' : 'S'); return; }
    if (d < 0.5) { g.set(x, y, z, 'L'); return; }
    if (d < 1.5) { g.set(x, y, z, y % 4 === 0 ? 'Q' : 'Y'); return; }
    if (d > R - 0.5) { g.set(x, y, z, y % 4 === 0 ? 'Z' : (spoke(a, 6, 0.25) ? 'K' : 'g')); return; }
    g.set(x, y, z, y % 4 === 0 && !(x === R && z === R + 2) ? 'G' : '.'); // hatch south of the light column
  });
  doors(g, doorways);
  return { ...g, title: 'The Mainspring', home: { x: R, y: 1, z: -1, face: 's' }, blurb: 'A tower of fans round a central shaft, ringed by galleries behind iron bars: the heart of the Engine Hall.' };
}

export const STRUCTURES = { stack, fields, hq, archive, construct, hydroponics, core };

// The site plan: where each structure sits, relative to the factory turtle
// (x east, y up, z south). The base lies under the factory's land.
export const SITE = [
  { id: 'fields', at: [-24, -60, 8] },
  { id: 'stack', at: [-18, -59, 14], name: 'Hive A' },
  { id: 'stack', at: [6, -59, 14], name: 'Hive B' },
  { id: 'stack', at: [-18, -59, 38], name: 'Hive C' },
  { id: 'stack', at: [6, -59, 38], name: 'Hive D' },
  { id: 'core', at: [-4, -59, 28] },
  { id: 'hq', at: [-8, -44, -9] },
  { id: 'archive', at: [-37, -59, 26] },
  { id: 'hydroponics', at: [25, -59, 28] },
  { id: 'construct', at: [-5, -59, 57] },
];
