# The Fleet Pipeline
> From a request to
> turtles at work
Today one spot in front of Forgemother does everything: births, kits, fuel and the porter's loads. Each waits for the last. This plan splits the spot up, loads turtles over the network, and lets work be shared out to a crew.

## The pipe
- 1 Request | an order joins the queue
- 2 Plan | the tree from stock
- 3 Gather | wait for raw materials
- 4 Build | craft the turtle
- 5 Birth | place, boot, move off
- 6 Load | kit and fuel at a bay
- 7 Work | then back for fuel
Each step hands on to the next and never waits on a turtle standing in the way.

## 1 Request
An order says what and how many: "3 excavators for zones 2 4 6", "64 torches", "Porter: the station's blocks". Orders come from you (Claude OS, the bridge), from a program (the porter asks for its next load) or from the balancer (lib/rates says iron is short: one more Geode). They wait in a queue on the fleet store, oldest first, one at a time per kind.

## 2 Plan
The factory asks lib/plan for the tree from stock: what is missing, what to smelt, what to craft, and how long it takes. An order that is short of something it can't make waits, says what it needs, and that need counts toward the gathering ranking (see Production).

## 3 Gather
Short items it can make go to the furnaces and the crafter first. Raw items wait for the gatherers. The order shows an estimate from lib/rates: "iron 40 short, 13 min at 3/min".

## 4 Build
Crafts as now, kit items first. Nothing is placed until everything for the turtle, its kit and its fuel is in storage, so a birth never stops halfway.

## 5 Birth
The birth spot is for births only. The new turtle boots from the floppy and moves off at once to a loading bay. The spot is free again within a minute.

## 6 Loading bays
A row of spots along a wall of wired modem blocks. A turtle parked against a modem shows on the network (turtle_12, say), and storage pushes items straight into it: Forgemother never moves and never turns. Four bays load four turtles at once.
```
 top view
   in  out
   |    ^
 [W][W] |    W: waiting
   v    |    B: bay
 [B1][B2][B3][B4]
 [M ][M ][M ][M ]
 ===storage net===
```
Bays serve:
- Newborns | kit and fuel for their job
- Fuel | turtles back from work
- Loads | the porter, builders
- Unloading | storage pulls a turtle's haul
Check first: a modem block picks up a turtle that parks next to it after it was switched on.

## Moving through
One way round: in from the lane above, out the side. A turtle asks for a bay (a note through the bridge); the factory answers with a bay number or "wait at W1". Waiting spots are a single file, one block apart, so nobody digs or pushes past. A turtle that doesn't answer for 2 minutes loses its bay.
Births and fuel never share a spot again, so a turtle asking for fuel can't be taken for a newborn.

## What each turtle needs
Each job says what it takes, worked out from its work, not guessed:
- kit | fixed items: a bucket, a scanner
- fuel | from the route: a zone is about 4,500 fuel, 56 charcoal
- load | big jobs in trips: the porter takes 13 stacks a trip until the station is full
A ledger on the fleet store keeps what each order has been given, like /.station does now, so a reboot never gives twice.

## Sharing out work
A job split over n turtles takes about T/n, but each extra turtle costs its build: materials (gathered at today's rates) and a birth. Add one more while it saves more than it costs:
T/n - T/(n+1) > build time
The excavation does this already: 8 wedges. For a 4 hour job and 8 minute builds: a 5th turtle saves 12 min, a 6th 8, a 7th 5.7. So 5 or 6. Faster builds (iron in stock) make bigger crews pay.
Rules for splitting:
- Parts that never cross | wedges, layers, rows
- One lane to share | the service shaft is single file
- Same program | the part is an argument
- A turtle finishing early | helps the slowest (excavate help)

## Order of building
- Bays | 4 modem blocks, a wall
- Queue | orders on the fleet store
- Birth then bay | newborn moves off
- Ledger | per order, per turtle
- Crew sizing | from the rule above
