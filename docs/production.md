# Production
> What we need, how fast
> it comes, what to add
How the fleet works out what any item takes, which gatherer to add next, and how it keeps inputs and use in balance.

## Recipe trees
Ask for any item and get the whole way there: raw materials, smelts, fuel, crafts and a time.
- recipe <item> [n] [furnaces] | from nothing, on any computer or pocket
- factory tree <item> [n] | from what is in storage, on these furnaces
Both use lib/plan, the factory's own planner. Example, recipe chunky_mining_turtle:
```
Raw materials:
  11 raw_iron
  7 cobblestone
  6 sand
  5 redstone
  3 birch_log
  3 diamond
  1 blaze_powder
  1 ender_pearl
Smelt: 24, fuel 3
Time: 1m18s (4 furn.)
```

## What to gather next
The next big orders, ranked by raw demand after what is in storage (1 Nov stock):
- 10,003 Factory Block | the station
- 32 Furnace | the array
- 20 Modem Block | array and bays
- 8 chunky turtle | a crew
- 64 Torch
Raw shortfall, biggest first:
- 1,340 Raw Iron | 1,252 for the blocks
- 380 Logs | charcoal for 2,658 smelts
- 60 Redstone
- 24 Diamond
- 20 Logs | chests, sticks
- 16 Coal | torches
- 8 Ender Pearl | chunk controllers
- 8 Blaze Powder | chunk controllers
- 0 Cobble | 26,700 in stock
So, in order:
- 1 Iron | a second Geode, or Create crushing for more per ore
- 2 Fuel | coal from Geode, more pines, or a fan line that needs none
- 3 Cobble | none: cap it. 26,700 is about 16 chests
The ranking is planner.rank(orders, stock, rates); it can run in-game on the same orders queue.

## Rates
lib/rates measures each item in items a minute:
- net | the trend of storage counts, a snapshot a minute over 30 min
- in | what the factory took in (intake, furnace outputs)
- out | what it took out (crafts, smelting, gifts)
- runway | minutes until it runs out at the trend
Net alone hides a busy item: cobble going in at 60 and out to the furnaces at 60 looks still. So the factory records each move as well as the snapshots.

## The balancing rule
For each raw item, per minute:
need = use + (keep - stock) / 60
use comes from what is being made: Rates.need turns "64 Factory Blocks a minute" into 8 iron, 8 cobble, 16 smelts (2.7 furnaces) and 2.3 logs of charcoal.
- in < 90% of need, a gatherer exists | add ceil(gap / one gatherer's rate)
- in < 90% of need, none exists | slow the users to in / need
- stock over cap, in > use | cut gatherers
- else | ok
The same rule sizes the furnaces: smelts a minute times 10 s over 60 is how many must be busy.
Decisions go to you first (an attention banner) until they have proved right; then the factory may queue births itself.

## On the screens
Wall dashboard: a flow table (numbers made up).
```
FLOW /min  in  out  net
cobble     62   24  +38
stone      18   20   -2
iron        3    8   -5
logs        4    4    0
charcoal    3    3    0
```
Glasses HUD: the two worst only.
```
! iron 5/min short
  add 3 miners
! cobble 26.7k, cut
```
Claude OS: a Rates page with the whole table and each item's runway.

## Build first
- 1 Rates in the factory | snapshot a minute, moves as flows, save to /.factory/rates
- 2 Rates line | dashboard and HUD read it
- 3 Faster furnace service | direct pushes, stacks, parallel
- 4 Cobble cap | Pebbles pauses over 5,000
- 5 Furnace wall | 16 first, then 32
- 6 Loading bays | then the order queue
- 7 Second iron source | as the ranking says
