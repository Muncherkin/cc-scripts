# Fleet network
> One hub in the game that every turtle talks to

Today every computer runs the agent and talks to the bridge on the PC through ngrok. Turtles pass notes to each other the same way. The fleet network moves the turtles' own coordination into the game: one hub computer at the base, fleetd, that every computer can get from and put to. It holds a shared key-value store, the fleet log, each turtle's last position and state, and reservations of cells, so two turtles never meet face to face in a one-wide passage.

It runs next to the bridge. Nothing in the running fleet changes until a program chooses to use it.

## Shopping list
- 1 Computer | the hub, any kind
- 1 Ender Modem | on the hub
- 1 Wireless Modem | per turtle that joins
- 1 Wireless Modem | per pocket that joins
- 1 Wired Modem | hub on the factory cable (optional)

Recipes: ender modem = 8 gold ingots round an eye of ender. Wireless modem = 8 stone round an ender pearl. Wired modem = 8 stone round redstone.

Put the hub in a chunk that is always loaded: the factory turtle's chunk (its chunk controller keeps it loaded), or a chunk force-loaded with FTB Chunks.

Start it with: autorun fleetd --start (on the hub, through the bridge), or type fleetd.

Turtles with full upgrade slots (pickaxe + chunk controller) carry their wireless modem in an inventory slot and swap it with the pickaxe to talk (see Turtles with no free slot). Wireless modems are enough for the clients as long as the hub has an ender modem: test this with one turtle before buying more.

## What reaches what
Wireless modem: 64 blocks below y=96, growing to 384 at build height (server config, defaults). Same dimension only. Storms don't shrink it with the default config.

Ender modem: any distance, any dimension. In CC: Tweaked a packet crosses dimensions and distance when either end is an ender modem. So one ender modem on the hub lets cheap wireless modems on the clients reach it from the mining dimension too. This is from reading CC: Tweaked's code (WirelessNetwork.tryTransmit); confirm it in-game with Geode before relying on it.

Wired modem + networking cable: everything on the same cable, any length, but every chunk the cable runs through must be loaded. The factory's network is wired: a wired modem on the hub on that cable reaches the factory turtle with no wireless at all. Moving the factory turtle turns its modem off until the player right-clicks it.

Rednet runs on any of these. It needs the bios's rednet.run (always there in the shell) and rednet.open on the modem side.

Chunk loading: a computer in an unloaded chunk is not running and hears nothing; messages to it are lost, not queued. Miners carry chunk controllers. Farms near the base are loaded while the player is near or by the factory controller. The hub must always be loaded, or every client goes offline (they cope: see Offline).

Turtles: two upgrade slots. Miners and excavators (chunky mining turtles) are full: pickaxe + chunk controller. Others (cobble, pine farm, lift) need checking one by one; any with a free slot can wear a modem for good.

Pocket computers: take a wireless or ender modem as their upgrade (craft pocket + modem). Claude OS could then read the fleet directly.

The factory turtle: already on a wired network. A wired modem on the hub on the same cable gives it the fleet with nothing new on the turtle.

## Turtles with no free slot
A miner keeps a wireless modem in one inventory slot. fleet.withModem(fn) equips it in place of the pickaxe, runs fn (connect, report, reserve...) and puts the pickaxe back, just like geominer's scanner swap. Never the chunk controller's side: its chunks would unload. A swap costs two equip calls (a tick or so each).

A turtle walking dug passages doesn't need its pickaxe: it can keep the modem on for the whole walk and swap back when it has to dig. That suits the excavator crew coming down the service shaft.

## The hub: fleetd
programs/fleetd.lua on the hub, with its state in programs/lib/fleetstore.lua (pure: it is tested offline without a radio). It hosts rednet protocol "fleet" as "fleetd" and refuses to start if another hub already does.

It holds:
- a key-value store: any serialisable value per string key, with a version number per key for compare-and-set
- the fleet log: numbered entries (seq, time, sender, text, data); the last 500 in memory, all of them in /fleetd/log on the hub
- the fleet: each computer's record (id, name, last seen, quiet) and what it last reported: pos, dim, facing, fuel, status, role, job, note
- cells: who holds which block position

State is saved to /fleetd/state at most every 5 s (with lib/state, so a cut-off save never loses it). After a restart every saved client gets a fresh lease, so a hub reboot doesn't free cells under moving turtles.

Key names, by convention:
- site/... places: lift, chests, the fuel station
- world/<dim>/... facts: water, ores, dug zones
- job/... claims on work: job/zone/3 = who digs it (put with ver 0 claims it only if nobody has)
- turtle/<name>/... a turtle's own notes

## Cells and leases
A cell is a block position x,y,z plus dim. A client holds:
- the cell it last said it stands in (here)
- the cells it reserved, each until released, replaced or 2 minutes pass without renewing

Reserve is all or nothing: a turtle asks for the next cells of its path, and gets all of them or is told who holds the first one in the way. With replace, a new reservation drops its old ones, so a turtle just reserves the next two or three cells on every step.

Leases: every message renews the sender's lease. A client silent for 30 s goes quiet: its reservations end and it is logged. Its last cell stays blocked (stale) for 10 minutes, because a stopped turtle is still a block in the passage. When it speaks again it is back.

If a turtle reports standing in a cell someone else reserved, the one that is really there wins and the clash is logged.

Deadlock: when A is refused a cell held by B, and B was last refused a cell held by A, the reply says deadlock. Rule for the harness: the turtle with the higher computer id gives way (backs into a siding or the way it came) and the other goes on. Tested in tests/fleetd_test.lua with two turtles in a one-wide passage.

## Protocol
Rednet protocol "fleet". A request is a table {op=..., rid=..., name=...} sent to the hub; the reply is a table with re=rid and ok. rid is unique per client (it starts at the clock), so a resent request gets the hub's cached reply and is never done twice. Every request carries the sender's name, so there is no hello.

Ops:
- ping: the hub's clock
- get key: value, ver (0: unset)
- put key value [ver]: value nil deletes; with ver only if still at ver, else conflict + current ver/value
- keys prefix: sorted key list
- append text [data]: seq
- log [since] [limit]: entries after since, or the latest limit (50)
- report fields: updates the record; pos also holds that cell
- fleet: every record
- reserve cells [replace] [here] [hold]: ok + exp, or ok=false with by, name, cell, here or stale, deadlock
- release [cells] [here]: the given cells or all reservations (never the cell it stands in)
- who cells: the holder of each, or false
- subscribe topic [prefix] / unsubscribe [topic]

Pushes: subscribers get {ev=topic, ...} as rednet messages: kv (key, value, ver, by), log (entry), fleet (rec), cells (cell, by). Subscriptions end when the subscriber goes quiet, so subscribers ping at least every 15 s.

Local: programs on the hub itself queue os event fleet_local with a request and get fleet_local_reply (and fleet_local_push). fleet.connect{local=true} does this.

## Client library
programs/lib/fleet.lua:

local fleet = require("lib.fleet")

local f, err = fleet.connect(opts): nil and "no modem" or "no fleet server in range". opts: name (default the label), server (an id; else the fleet.server setting, else a rednet lookup), timeout (2 s), local.

f:get(key), f:put(key, v, ver), f:del(key, ver), f:update(key, fn) (compare-and-set with retries), f:keys(prefix), f:append(text, data), f:log(since, limit), f:report{pos=..., fuel=...}, f:fleet(), f:reserve(cells, {replace, here, hold}), f:release(cells, here), f:who(cells), f:subscribe(topic, prefix), f:unsubscribe(topic), f:ping().

Waiting for a reply never drops other events: anything else that arrives meanwhile is queued again (so bridge_push events survive). Pushes that arrive during a call come back as fleet_event events; outside a call, fleet.push(os.pullEvent()) tells a push from other events.

fleet.withModem(fn, {side}): the pickaxe swap above.

## Offline
A call with no answer tries once more, then returns nil, "offline", and the client doesn't try again for 30 s (calls during that time return at once). So a dead hub costs a turtle 4 s once, not on every step.

Occupancy claims succeed while offline: turtles can't move into each other anyway (turtle.forward just fails), so the network only saves them from waiting face to face. Programs must still cope with a blocked move.

## The movement harness
programs/lib/move.lua (being written in another session) asks an occupancy object before each step:

local occ = fleet.occupancy(fleet.connect(), {dim="overworld"})

- occ.claim(cells): reserve these cells (the next 2-3 of the path) instead of the last claim; true, or false and who is in the way (info.by, info.name, info.stale, info.deadlock). Offline or no client: true with info.offline.
- occ.moved(cell): now standing here. Sent with the next claim; on its own at most every 5 s, to keep the lease.
- occ.release(): done moving; drops every claim but keeps the cell it stands in.
- occ.who(cells): who holds them.

Cells are world positions. lib/nav works relative to the program's start, so the harness turns nav positions into world ones with the start in bridge/fleet.json (where.js) or a saved origin, and adds dim.

One round trip per step: a claim is one rednet message each way, a tick or two, while a move takes 8 ticks.

## The bridge
Stays as it is for now: Claude's access to the game (run, eval, docs, say, attention, jobs) goes through the agent on every computer, ngrok and the bridge on the PC. Turtles' relay notes still work.

Claude can already read the hub through the bridge: an eval on the hub can queue fleet_local requests (or read /fleetd/state and /fleetd/log). A small cli command (fleet get/put/log/where) would wrap that.

Later the hub can be the only computer that talks to the bridge: one agent and one websocket on the hub. Commands for other computers (run, eval, sync files) travel over rednet from the hub: an exec op, with chunks of files for sync. The bridge then needs one tunnel and one connection, works for computers in the mining dimension and for turtles that can't reach the internet. That needs a small agent for the other computers that listens on rednet instead of a websocket. Until then the two run side by side.

## Not done yet
- Nothing placed or run in-game.
- No program uses the fleet yet; the harness will be first.
- Range and ender behaviour: from CC: Tweaked's code and defaults, not tried on this server.
- No security: any computer in range can put and reserve. Fine on a friendly server; a shared secret per message would stop pranks.
