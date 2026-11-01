# Furnace Array
> Smelting at scale
> for the factory
Four furnaces do 24 items a minute. The station's 10,003 Factory Blocks need 2,504 smelts (1,252 stone, 1,252 iron): 1h44m on four, 13 min on 32. Every turtle needs 20 more. Smelting is the slowest step in the factory today.

## What the logs say
From the factory's stock lines on 1 Nov:
- Cobble | +60/min, 26,700 stored
- Stone | flat near 150, although the keep is 1,400
- Charcoal | 16 to 70, never builds up
- Logs | 50 to 100, flat
Cobble is not short. Smelting is, and so is fuel: one charcoal smelts 8 items, so 4 busy furnaces burn 3 logs a minute. lib/rates will show which one holds stone down.

## Furnace kinds
All of these are block inventories, so a wired modem can feed them like a chest. Check each in JEI first: ATM can change them.
- Furnace | 10 s an item, 8 cobble. Smelts everything.
- Blast Furnace | 5 s, ores and raw metal only. 5 iron, 3 smooth stone, a furnace. Same fuel per item.
- Iron Furnaces mod | faster tiers, if ATM10 has it. Upgrade kits cost iron, gold, diamond, obsidian.
- Create fans | a fan blowing through a campfire or lava smelts items on a belt or depot. No fuel at all. Needs rotation.
- Powered smelters | Mekanism, Thermal: later, once the base has power.
Iron is short, so blast furnaces and upgrades wait. Plain furnaces cost only cobble, and we have 26,700.

## The plan
- A: 32 furnaces | now, cobble only
- B: fuel | coal from Geode, more pines
- C: a fan line | stone without fuel
- D: blast furnaces | when iron flows

## A: 32 furnaces
A wall of furnaces round a spine of full-block wired modems. Each modem touches a furnace on each side and the modems above, below and beside it, so the whole wall is one network with the factory's chests.
```
 top view, one layer
 F F F F F F F F
 M M M M M M M M
 F F F F F F F F

 side view
 M M M M M M M M  y+1
 M M M M M M M M  y
 =cable to storage
```
- 32 Furnace | 256 cobble
- 16 Wired Modem Block | 128 stone, 16 redstone
- 4 Cable | to the storage wall
Two layers, 3 wide, 8 long. In the Engine Hall, beside the factory's chests (the factory move picks the spot). Right-click each modem once: 16 clicks.
Check before building all of it: two modem blocks side by side join up. If not, a cable runs along the top.

## Feeding it
The factory turtle already serves every furnace on the network. For 32 it needs four changes (code, offline-tested first):
- Push straight from the chest into the furnace, not through the turtle: one call instead of three.
- Load a stack, not 16: the shortfall is split over the furnaces, up to 64 each. A full furnace runs 10 min alone.
- Serve furnaces side by side with parallel calls: a round of 32 takes a few ticks, not seconds.
- Scan storage once a round, not once a furnace.
Each round: take out finished items (slot 3), top fuel (slot 2) up to 8, load input (slot 1) if the furnace is empty and something is below its keep.

## Fuel
A stack of 64 items burns 8 charcoal. 32 furnaces flat out burn 24 a minute: more than the pines give. So the array runs in bursts: the planner only smelts what is asked for, and the furnaces wait between jobs.
- Charcoal | from logs, 1 log each
- Coal | Geode mines coal ore
- Lava bucket | 100 items each; the empty bucket must come out of the fuel slot
- Campfire | Create fans only
The station's blocks need about 360 charcoal. How long the pines and Geode take to bring that is the first thing lib/rates should measure.

## Throughput
- 4 furnaces | 24/min, 3 charcoal/min
- 16 furnaces | 96/min, 12 charcoal/min
- 32 furnaces | 192/min, 24 charcoal/min
- 64 furnaces | 384/min, 48 charcoal/min
1,252 stone takes 52, 13, 6.5 and 3.3 minutes on those.
Past 32 the fuel, not the furnaces, sets the pace.

## C: a fan line
Cobble to stone without fuel: a chest feeds a funnel onto a belt that runs through a fan's air, blowing through a campfire; a funnel at the end fills a chest on the network. The factory fills the first chest and empties the last like any other.
```
 [in]>=belt=====>[out]
      ^ fan air ^
      [fire][fan]
```
- Measure | items a minute on one line
- Check | Ponder: fire or lava for smelting
It needs rotation (a water wheel). Build one line, measure it with lib/rates, then decide how many.

## D: blast furnaces
Eight for raw iron and gold: 96 a minute at the same fuel per item. 40 iron: build them once Geode or a second miner keeps iron coming.
