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
  'factory_blocks:rust_plates': { name: 'Rust plates', tex: 'fb_rust_plates' },
  'factory_blocks:rust_bplates': { name: 'Bolted rust plates', tex: 'fb_rust_bplates' },
  'factory_blocks:gears': { name: 'Gears', tex: 'fb_gears', light: 0.12 },
  'factory_blocks:metalbox': { name: 'Metal box', tex: 'fb_metalbox_side' },
  'factory_blocks:gcircuit': { name: 'Brass circuit', tex: 'fb_gcircuit', light: 0.2 },
  'factory_blocks:rgrate': { name: 'Rusty grate', tex: 'fb_rgrate' },
  'factory_blocks:grate': { name: 'Grate', tex: 'fb_grate' },
  'factory_blocks:rust': { name: 'Rust', tex: 'fb_rust' },
  'factory_blocks:vrust': { name: 'Vented rust', tex: 'fb_vrust' },
  'factory_blocks:large_pipes': { name: 'Large pipes', tex: 'fb_large_pipes' },
  'factory_blocks:small_pipes': { name: 'Small pipes', tex: 'fb_small_pipes' },
  'factory_blocks:engineer': { name: 'Engineer panel', tex: 'fb_engineer' },
  'factory_blocks:old_vents': { name: 'Old vents', tex: 'fb_old_vents' },
  'factory_blocks:rusty_scaffold': { name: 'Rusty scaffold', tex: 'fb_rusty_scaffold' },
  'factory_blocks:wopanel': { name: 'Orange panel', tex: 'fb_wopanel', light: 0.45 },
  'factory_blocks:insulation': { name: 'Insulation', tex: 'fb_insulation' },
  'computercraft:wired_modem_full': { name: 'Wired modem', tex: 'cc_wired_modem_face_peripheral_on', light: 0.2 },
  'computercraft:cable': { name: 'Networking cable', tex: 'cc_cable_core', scale: 0.4, low: true },
  'computercraft:monitor_advanced': { name: 'Advanced monitor', tex: 'cc_monitor_advanced_15', light: 0.3 },
  'computercraft:computer_advanced': { name: 'Advanced computer', tex: 'cc_computer_advanced_front', light: 0.2 },
  'minecraft:chest': { name: 'Chest', tex: 'mc_chest_front' },
  'minecraft:dirt': { name: 'Dirt', tex: 'mc_dirt' },
  pod: { name: 'Turtle (berth)', tex: 'cc_turtle_normal_front', scale: 0.82, light: 0.1 },
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
for (const name of ['fb_piping', 'fb_sturdy', 'fb_srust']) {
  const file = path.join(TEX, name + '.png');
  if (fs.existsSync(file)) textures[name] = 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
}

const data = { structures, site: SITE, bom, look: LOOK, textures };
const template = fs.readFileSync(path.join(DIR, 'page.template.html'), 'utf8');
const html = template.replace('/*__CORE_DATA__*/null', JSON.stringify(data));
const outFile = path.join(OUT, 'the-core.html'); // kept: the published page lives at this path
fs.writeFileSync(outFile, html);
console.log(`${outFile}: ${(html.length / 1024).toFixed(0)} KB, ${Object.keys(textures).length} textures`);
