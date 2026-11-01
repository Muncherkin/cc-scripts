// The chest station: plain Factory Blocks for every variant the Clockworks
// needs (design/out/bom.json), packed into chests along the back wall of the
// station room (zone 9 of the dig: site x -3..4, y 12..14, z -5..-1).
// Chests stand in columns at x -3, -1, 1, 3 (gaps: side by side they'd join),
// three high, against the wall at z -5; the porter fills them from z -4.
// Writes programs/blueprints/station.lua and docs/station.md.
// Usage: node design/station.mjs
import fs from 'node:fs';
const bom = JSON.parse(fs.readFileSync('design/out/bom.json', 'utf8'));
const need = {};
for (const s of Object.values(bom)) {
  for (const [k, v] of Object.entries(s.counts || {})) if (k.startsWith('factory_blocks:')) need[k] = (need[k] || 0) + v;
}
const STACK = 64, SLOTS = 27;
const nice = (k) => k.replace('factory_blocks:', '').replace(/_/g, ' ');
// Big ones get their own chests; the small ones share.
const list = Object.entries(need).sort((a, b) => b[1] - a[1]);
const chests = [];
let shared = null;
for (const [k, n] of list) {
  const stacks = Math.ceil(n / STACK);
  if (stacks >= 6) {
    let left = n;
    while (left > 0) { const take = Math.min(left, SLOTS * STACK); chests.push({ parts: [[k, take]] }); left -= take; }
  } else {
    if (!shared || shared.stacks + stacks > SLOTS) { shared = { parts: [], stacks: 0 }; chests.push(shared); }
    shared.parts.push([k, n]); shared.stacks += stacks;
  }
}
const spots = [];
for (const x of [-3, -1, 1, 3]) for (const y of [12, 13, 14]) spots.push([x, y, -5]);
if (chests.length > spots.length) throw new Error(`${chests.length} chests, room for ${spots.length}`);
let lua = '-- Made by design/station.mjs: the chest station\'s chests and what goes in them.\n';
lua += '-- Each chest: where it stands (site), how many plain Factory Blocks, and for which variants.\n';
lua += 'return {\n  item = "factory_blocks:factory",\n  chests = {\n';
let md = '# Chest station\n> Plain Factory Blocks, by variant\n\n';
md += 'Columns of chests on the back\nwall, 1-4 from the west,\nbottom to top. Take a chest,\nturn it at the Mason Table\ninto the variants listed.\n\n';
let total = 0;
chests.forEach((c, i) => {
  const [x, y, z] = spots[i];
  const n = c.parts.reduce((a, p) => a + p[1], 0);
  total += n;
  lua += `    { x = ${x}, y = ${y}, z = ${z}, n = ${n}, for_ = { ${c.parts.map(([k, v]) => `{ "${k}", ${v} }`).join(', ')} } },\n`;
  const col = [-3, -1, 1, 3].indexOf(x) + 1, tier = y - 11;
  md += `## Chest ${col}-${tier}\n`;
  for (const [k, v] of c.parts) md += `- ${v} ${nice(k)} | ${Math.floor(v / STACK)} st + ${v % STACK}\n`;
  md += '\n';
});
lua += '  },\n}\n';
md += `Total: ${total} blocks\n(${Math.ceil(total / STACK)} stacks).\n`;
fs.writeFileSync('programs/blueprints/station.lua', lua);
fs.writeFileSync('docs/station.md', md);
console.log(`${chests.length} chests, ${total} blocks`);
chests.forEach((c, i) => console.log(spots[i].join(','), c.parts.map(([k, v]) => `${nice(k)} ${v}`).join(' + ')));
