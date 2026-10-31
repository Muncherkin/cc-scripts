// Builds the design page: design/page.template.html plus the generated
// structure data (design/out/*.json, from generate.mjs) and the block
// textures (design/.textures, extracted from the game jars; never committed).
//
// Usage: node design/generate.mjs && node design/page.mjs
// Writes design/out/the-core.html.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { STRUCTURES, SITE } from './structures.mjs';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(DIR, 'out');
const TEX = path.join(DIR, '.textures');

// What each block looks like on the page.
//   tex: texture file (without .png); light: glows; glass: see-through;
//   scale: drawn smaller than a full block
export const LOOK = {
  'factory_blocks:bcircuit': { name: 'Black circuit', tex: 'fb_bcircuit' },
  'factory_blocks:circuit': { name: 'Circuit', tex: 'fb_circuit' },
  'factory_blocks:wireframe': { name: 'Wireframe', tex: 'fb_wireframe' },
  'factory_blocks:bwireframe': { name: 'Blue wireframe', tex: 'fb_bwireframe', light: 0.35 },
  'factory_blocks:ice': { name: 'Ice panel', tex: 'fb_ice', light: 0.55 },
  'factory_blocks:grate': { name: 'Grate', tex: 'fb_grate' },
  'factory_blocks:large_plating': { name: 'Large plating', tex: 'fb_large_plating' },
  'factory_blocks:large_pipes': { name: 'Large pipes', tex: 'fb_large_pipes' },
  'factory_blocks:cables': { name: 'Cables', tex: 'fb_cables' },
  'factory_blocks:engineer': { name: 'Engineer panel', tex: 'fb_engineer' },
  'factory_blocks:megacell': { name: 'Megacell', tex: 'fb_megacell_side' },
  'factory_blocks:vent': { name: 'Vent', tex: 'fb_vent' },
  'factory_blocks:caution': { name: 'Caution', tex: 'fb_caution' },
  'factory_blocks:hazard': { name: 'Hazard', tex: 'fb_hazard' },
  'factory_blocks:sturdy': { name: 'Sturdy', tex: 'fb_sturdy' },
  'computercraft:wired_modem_full': { name: 'Wired modem', tex: 'cc_wired_modem_face_peripheral_on', light: 0.25 },
  'computercraft:cable': { name: 'Networking cable', tex: 'cc_cable_core', scale: 0.4, low: true },
  'computercraft:monitor_advanced': { name: 'Advanced monitor', tex: 'cc_monitor_advanced_15', light: 0.3 },
  'computercraft:computer_advanced': { name: 'Advanced computer', tex: 'cc_computer_advanced_front', light: 0.2 },
  'minecraft:chest': { name: 'Chest', tex: 'mc_chest_front' },
  'minecraft:verdant_froglight': { name: 'Verdant froglight', tex: 'mc_verdant_froglight_side', light: 1 },
  'minecraft:sea_lantern': { name: 'Sea lantern', tex: 'mc_sea_lantern', light: 1 },
  'minecraft:lime_stained_glass': { name: 'Lime glass', tex: 'mc_lime_stained_glass', glass: 0.45 },
  'minecraft:tinted_glass': { name: 'Tinted glass', tex: 'mc_tinted_glass', glass: 0.7 },
  'minecraft:white_concrete': { name: 'White concrete', tex: 'mc_white_concrete' },
  'minecraft:dirt': { name: 'Dirt', tex: 'mc_dirt' },
  'minecraft:polished_deepslate': { name: 'Polished deepslate', tex: 'mc_polished_deepslate' },
  pod: { name: 'Turtle (pod)', tex: 'cc_turtle_normal_front', scale: 0.82, light: 0.15 },
  factory: { name: 'Factory turtle', tex: 'cc_turtle_normal_front' },
};

const structures = {};
for (const id of Object.keys(STRUCTURES)) {
  structures[id] = JSON.parse(fs.readFileSync(path.join(OUT, `${id}.json`), 'utf8'));
}
const bom = JSON.parse(fs.readFileSync(path.join(OUT, 'bom.json'), 'utf8'));

const textures = {};
for (const look of Object.values(LOOK)) {
  const file = path.join(TEX, look.tex + '.png');
  if (fs.existsSync(file) && !textures[look.tex]) {
    textures[look.tex] = 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
  }
}
// Swatch textures for the palette section.
for (const name of ['fb_hex', 'fb_gvent', 'fb_mosaic', 'fb_pgcircuit', 'mc_deepslate']) {
  const file = path.join(TEX, name + '.png');
  if (fs.existsSync(file)) textures[name] = 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
}

const data = { structures, site: SITE, bom, look: LOOK, textures };
const template = fs.readFileSync(path.join(DIR, 'page.template.html'), 'utf8');
const html = template.replace('/*__CORE_DATA__*/null', JSON.stringify(data));
const outFile = path.join(OUT, 'the-core.html');
fs.writeFileSync(outFile, html);
console.log(`${outFile}: ${(html.length / 1024).toFixed(0)} KB, ${Object.keys(textures).length} textures`);
