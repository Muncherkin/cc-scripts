# cc-scripts: notes for Claude

Lua programs for CC: Tweaked computers and turtles (Minecraft modpack: All the Mods 10, multiplayer server).

## Dev loop
- In-game programs live in `programs/`. They sync to the computer's root, so `programs/foo.lua` runs as `foo`.
- The bridge must be running (`npm run bridge`; the user may already have it in a terminal tab). Check with `node bridge/cli.js computers`.
- Test a program: `node bridge/cli.js run <program> [args] [--c id] [--timeout s]`. This syncs, runs, and prints captured print/write/printError output, the return value or traceback, and the turtle's fuel.
- Where things are: `node bridge/where.js` (live positions from each program's saved nav state + the starts in bridge/fleet.json; `where.js set <id> x y z facing [dim]` records a start). No GPS: miners have no free upgrade slot for a modem.
- Inspect world or computer state: `node bridge/cli.js eval "<lua>"`, e.g. `turtle.inspect()`, `peripheral.getNames()`, `fs.list("/")`.
- Jobs run concurrently on the agent. Long jobs: if `run` times out it prints a job id; use `wait <id>`. `jobs` lists recent jobs, and `stop [id]` aborts one (or all).
- Permanent programs (farms etc.): `autorun <program> [args] --start` makes the agent start it on every boot, and `autorun --clear` removes it. Autorun jobs show up in `jobs` once they print.
- Full job records are in `logs/jobs/*.json`, and the event log is `logs/bridge.log`.
- Basic (non-advanced) computers: the agent runs next to the shell and logs its own messages to `/.agent/log`.
- Output written with `term.write` directly is not captured. Use print/write.
- Offline tests: `npm test` runs `tests/*_test.lua` in fengari against `tests/sim.lua`, a small CC: Tweaked turtle/world simulator. Test risky turtle programs there before running them in-game, and extend the simulator when a program needs more API.
- Turtle programs act in a shared multiplayer world: ask before running anything that digs, places or moves large distances.
- Find things out in the world yourself rather than asking the player: have a turtle inspect and report (stop its job, move and come back to the exact start so its saved nav state stays right), map a layer with `survey <state file> x0 x1 z0 z1 [y]` (writes /survey.txt on the turtle), and build blocked-step logs into programs (Doorman writes /.doorman.log). Ask only when a wrong guess could break something or the choice is the player's.
- Advanced Peripherals detectors: scans of radius 8 are free; wider ones cost a lot of fuel (radius 9: 330, 11: 1233) and fail without it. Players show as displayName "Player" here; tell them apart by uuid.
- Turtles can pass notes through the bridge: `os.queueEvent("bridge_send", {action="relay", to="<name or id>", event="...", data={...}})` arrives at the other as a `bridge_push` event (don't `sleep` while waiting for one: sleep drops events).
- After changing `cc/agent.lua`: commit and push (install.lua downloads from GitHub main), then `node bridge/cli.js update-agent`.
- Repo: github.com/Muncherkin/cc-scripts (public; never commit `bridge/.state.json` or tokens).

## Docs, printing and messages
- `docs/` holds documents for the player (plans, guides, reports) in the printlist format: `# Title`, `> subtitle`, `## Section`, `- 35 Gold Ingot | note` (tickable checklist items), fenced ASCII art, plain text. Keep lines short: pockets are 26 wide, printed pages 25.
- `node bridge/cli.js docs` copies `docs/` to every connected pocket computer's `/docs` (Claude OS shows NEW badges and a toast). Update docs when plans change.
- `node bridge/cli.js print <path under docs/>` prints on whichever computer has a printer; if printing fails it sends the doc to the pockets instead.
- `node bridge/cli.js say "<text>"` posts a message to the wall dashboard and Claude OS.
- Need the player (a decision, a hand in-game, something finished they should look at)? `node bridge/cli.js attention "<text>"` puts a flashing banner on the glasses HUD, toasts Claude OS with a chime and posts the text as a message. `node bridge/cli.js attention` says whether they have seen it (the glasses hotkey acks it), `--clear` takes it down. Use it when you are waiting on the user, not for routine progress.
- Screenshots of the game: `pwsh tools/mcshot.ps1 [-Out logs/mc.png] [-Crop x,y,w,h] [-Scale 0.5]` captures the Minecraft window even behind other windows (not minimised; menus blur it). Use it to check HUD and overlay work; `node tests/run.js tests/hud_test.lua svg > logs/hud.svg` previews the HUD offline.
- Claude OS (`programs/claudeos.lua`) talks to the bridge via `os.queueEvent("bridge_send", data)`; the agent relays it.

## The fleet (as of 2026-11-01)
- Names and roles live in `bridge/fleet.json` (the bridge shows them everywhere, even for offline machines); `node bridge/cli.js names` sets matching computer labels in-game. Rusty #1, Forgemother #4, Keeper #5, Monocle #6, Pebbles #7, Juniper #8, Otis #9, Geode #10.
- #4 factory turtle (`factory run` autorun): wired network of chests and furnaces, input chest on top, output chest below, birth spot in front (disk drive with floppy under it), chunk controller. `factory birth <job>` builds and boots turtles (jobs in programs/lib/jobs.lua). The birth spot is also a fuel station. Moving the factory turtle turns its modem off: the player must right-click it.
- Where the factory is: `programs/lib/home.lua` (`at` = surface or hall); factory-born turtles keep where it stood at their birth in state.origin, and reach a hall factory down the service shaft (lib/way.lua). The move itself: docs/factory-move.md (`factory evacuate`, `factory birth mover` -> movestore.lua).
- #7 cobble turtle on top of the input chest (`cobble`), #8 pine farm east of the factory (`treefarm`), #9 elevator in a 71-deep shaft (`elevator`), #10 geo miner in the mining dimension (`geominer`) delivering through a Functional Storage ender drawer registered with `factory input`.
- Production: lib/plan.lua is the factory's planner (`factory tree <item> [n]` from stock, `recipe <item> [n] [furnaces]` from nothing: raws, smelts, fuel, time; `rank` sums raw demand over orders). lib/rates.lua turns storage snapshots and moves into items/min and advises add/slow/cut. Plans: docs/furnaces.md, docs/fleet-pipeline.md, docs/production.md.
- #5 vault door terminal (`doorboot` types `door` into the shell), #6 smart glasses with the HUD (`hud`; overlay rectangles are positioned by their centre and the first text after the first rectangle draws under it, see the top of programs/hud.lua). turtle-1 is the old branch miner, stuck in the mining dimension.
- Advanced Peripherals scanners (geo, environment) have a 2 s cooldown and radius 8 is free; scanners report world axes.
- The simulator turns the opposite way to Minecraft (right of +z is +x); tests that involve world axes mirror x.

## Fleet network (built, not placed yet)
- `fleetd` (programs/fleetd.lua, state in lib/fleetstore.lua) is an in-game hub over rednet: key-value store, fleet log, turtle records, cell reservations on leases. Clients use lib/fleet.lua (`fleet.connect()`, `fleet.occupancy()` for the movement harness, `fleet.withModem()` swaps a carried modem in for the pickaxe). Design, protocol and hardware list: docs/fleet-network.md. tests/sim.lua's `sim.newRadio()` runs several computers at once over a simulated rednet.

## The Clockworks (design)
- Underground base design: design/structures.mjs -> `node design/generate.mjs [--install]` writes programs/blueprints, Create schematics (copied into the instance's schematics folder as core_*.nbt) and render data; `node design/page.mjs` builds the design page (published artifact "The Clockworks": Factory Blocks in dark greys and green, andesite-bar railings).
- The site is anchored on the lift: origin = the elevator's bottom stop, the middle of the Mainspring's roof (71 below the lift's top). The service shaft for turtles runs one block east of the lift.
- `excavate <zone>` (`factory birth excavator <zone>`; birth args become the job's args) digs one of 8 wedges of the works (design/excavation.mjs: volume, zones, checked routes in programs/blueprints/excavation.lua; CREW sets the count). Each comes down the service shaft from beside the elevator at the top. `npm test` runs small routes; `node tests/run.js tests/excavate_test.lua full` runs the whole crew (slow). design/.textures and design/out hold game textures: never commit them.
- `builder <blueprint>` builds any blueprint (supply chest below its home, empty staging chest above). Nothing has been built in-game yet: ask before starting a builder, it digs.
- datapack/core_factory_chisel makes Factory Block variants chiselable (needs server access).
