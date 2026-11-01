// Turns the scout's map (logs/scout.txt, pulled from the scout) into
// programs/blueprints/wet.lua: per zone, the cells of the works that are
// wet (water or lava) or still have something standing in them (leftover
// plugs), and cells of the works next to water in the walls. Drainers
// (excavate drain <zones>) visit them. Usage: node design/wet.mjs
import fs from 'node:fs';
const s = fs.readFileSync('programs/blueprints/excavation.lua', 'utf8');
const zs = s.split('route = table.concat({').slice(1).map((z) => [...z.split('})')[0].matchAll(/"([^"]*)"/g)].map((m) => m[1]).join(''));
const OPS = { n: [0, 0, -1], e: [1, 0, 0], s: [0, 0, 1], w: [-1, 0, 0], u: [0, 1, 0], d: [0, -1, 0] };
const zoneOf = new Map();
zs.slice(0, 8).forEach((r, zi) => {
  let p = [3, 8, 0];
  for (const ch of r) {
    const o = OPS[ch] || OPS[ch.toLowerCase()];
    if (!o) continue;
    const n = [p[0] + o[0], p[1] + o[1], p[2] + o[2]];
    const k = n.join(',');
    if (!zoneOf.has(k)) zoneOf.set(k, zi + 1);
    if (OPS[ch]) p = n;
  }
});
const cell = new Map();
for (const line of fs.readFileSync('logs/scout.txt', 'utf8').split('\n')) {
  const m = line.trim().split(' ');
  if (m.length < 5) continue;
  cell.set(m.slice(0, 3).join(','), { name: m[3], where: m[4] });
}
const visit = {};
const add = (zn, k) => ((visit[zn] ??= new Set()).add(k));
for (const [k, v] of cell) {
  if (v.name.startsWith('computercraft:')) continue;
  if (v.where === 'in') { add(zoneOf.get(k), k); continue; }
  if (!/water|lava/.test(v.name)) continue;
  const [x, y, z] = k.split(',').map(Number);
  for (const o of Object.values(OPS)) {
    const n = [x + o[0], y + o[1], z + o[2]].join(',');
    if (zoneOf.has(n)) add(zoneOf.get(n), n);
  }
}
let out = '-- Made by design/wet.mjs from the scout\'s map: cells of the works to drain, by zone.\nreturn {\n';
for (const zn of Object.keys(visit).sort()) {
  out += `  [${zn}] = { ${[...visit[zn]].map((k) => `"${k}"`).join(', ')} },\n`;
  console.log(`zone ${zn}: ${visit[zn].size} cells`);
}
fs.writeFileSync('programs/blueprints/wet.lua', out + '}\n');
