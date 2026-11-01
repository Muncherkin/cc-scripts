// Packs the dig routes in programs/blueprints/excavation.lua so a turtle's
// files fit on the birth floppy (125 kB): a run of a repeated unit becomes
// "(unit*count)", e.g. "UDwUDwUDw" -> "(UDw*3)". excavate.lua expands them when
// it loads the plan. Routes are only letters, digits and T, so the brackets,
// star and count can't be mistaken for ops. Run after design/generate.mjs (or
// any hand edit of the blueprint); running it twice changes nothing.
// Usage: node design/packroutes.mjs
import fs from 'node:fs';

export function pack(route) {
  let out = '', i = 0;
  while (i < route.length) {
    let best = null;
    for (let len = 1; len <= 8; len++) {
      const unit = route.slice(i, i + len);
      if (unit.length < len) break;
      let n = 1;
      while (route.startsWith(unit, i + n * len)) n++;
      const saved = n * len - (len + 3 + String(n).length);
      if (n >= 2 && saved > 0 && (!best || saved > best.saved)) best = { unit, n, saved };
    }
    if (best) {
      out += `(${best.unit}*${best.n})`;
      i += best.unit.length * best.n;
    } else {
      out += route[i];
      i += 1;
    }
  }
  return out;
}

export function unpack(route) {
  return route.replace(/\(([0-9A-Za-z]+)\*(\d+)\)/g, (_, unit, n) => unit.repeat(Number(n)));
}

const FILE = 'programs/blueprints/excavation.lua';
export function packFile(file = FILE) {
  const src = fs.readFileSync(file, 'utf8');
  const crlf = src.includes('\r\n');
  let s = src.replace(/\r\n/g, '\n');
  let before = 0, after = 0;
  // Every route = table.concat({ "...", "...", }) block.
  s = s.replace(/route = table\.concat\(\{\n([\s\S]*?)\n(\s*)\}\)/g, (m, body, indent) => {
    const parts = [...body.matchAll(/"([^"]*)"/g)].map((x) => x[1]);
    const route = unpack(parts.join(''));
    const packed = pack(route);
    if (unpack(packed) !== route) throw new Error('pack does not round-trip');
    before += parts.join('').length;
    after += packed.length;
    const pad = indent + '  ';
    const chunks = packed.match(/.{1,100}/g) || [''];
    return `route = table.concat({\n${chunks.map((c) => `${pad}"${c}",`).join('\n')}\n${indent}})`;
  });
  fs.writeFileSync(file, crlf ? s.replace(/\n/g, '\r\n') : s);
  console.log(`routes ${before} -> ${after} characters`);
}
if (process.argv[1] && process.argv[1].endsWith('packroutes.mjs')) packFile();
