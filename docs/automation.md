# Automation register
> How every item is made
> and what still needs you
Claude keeps this file. Each item: where it comes from, who makes it, how fast. Read before any plan; updated in the same change that adds or alters a source. "check" means not measured yet.

## Gathered
- Cobblestone | Pebbles #7, generator on the input chest. Capped by compacting over 1,024
- Pine logs | Juniper #8, pine farm. Rate: check
- Iron ore | Geode #10, mining dim. 86 an hour
- Coal | Geode. 269 ore an hour
- Diamond | Geode. 44 ore an hour
- Redstone | Geode. ~120 an hour
- Wheat, bread | farm turtle (farm.lua). Not in the fleet now: check

## Made by the factory
Forgemother #4, from storage, with 32 furnaces. Recipes: programs/lib/recipes.lua. Any tree: recipe <item> [n].
- Charcoal | logs in the furnaces; the fleet's fuel
- Stone, glass, ingots | furnaces
- Planks, sticks, chests, barrels | from logs
- Furnaces, torches, buckets | crafted
- Computers, turtles, modems | crafted; births by factory birth <job>
- Compressed cobble | over 1,024 cobble
- End Automata Cores | Ender #28 feeds endermen to Weak cores. About 10 endermen an hour

## No source yet
A plan may not lean on these in bulk until they have one.
- Ender pearls | chunk controllers, modems. Idea: Ender kills endermen in the End
- Blaze powder | chunk controllers, eyes of ender. No idea yet
- Sand | glass. check: Geode's junk, or a dig site
- Gold | ender modems, golden apples. check: Geode can target it
- Andesite | andesite alloy. check
- Sugar cane | paper for printing
- Regeneration potions | Weak cores
- Andesite bars | need a stonecutter or Create saw; a turtle can't cut

## Still needs you
Each one is a defect to remove.
- Carrying turtles to the mining dimension | fix: Ender ferries them by portal warp
- Right-click on Forgemother's modem after she moves | fix: she doesn't move; Mover clicks fresh modems
- Linked chest and drawer pairs | fix: factory crafts and pairs them: check how
- Force-loading mining chunks (FTB Chunks) | fix: chunk controllers, once pearls have a source
- Placing the fleet hub | fix: Mover places it (worker place)
- The bridge on your PC | fix: fleet network; the fleet runs without it
- Server-side datapack (chisel variants) | yours: needs server access

## Rates wanted
From docs/production.md, the next orders are short of, most first:
- Iron | more Geodes
- Logs | more pine spots
- Redstone, diamond | with the iron
