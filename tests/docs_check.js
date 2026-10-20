// Checks every doc in docs/ fits the devices that show it: pocket readers
// have 24 usable columns, printed pages 25. Art can't wrap, so it must fit.
import fs from 'node:fs';
import path from 'node:path';

const MAX_ART = 24;
let problems = 0;

function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
    if (!lines.some((l) => l.startsWith('# '))) { console.log(`  FAIL  ${p}: no "# Title" line`); problems++; }
    let art = false;
    lines.forEach((l, i) => {
      if (l.startsWith('```')) { art = !art; return; }
      if (art && l.length > MAX_ART) {
        console.log(`  FAIL  ${p}:${i + 1}: art line is ${l.length} wide (max ${MAX_ART})`);
        problems++;
      }
    });
  }
}

walk('docs');
console.log(problems ? `\n${problems} problem(s) in docs/` : 'All docs fit');
process.exit(problems ? 1 : 0);
