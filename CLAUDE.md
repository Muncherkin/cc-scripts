# cc-scripts: notes for Claude

Lua programs for CC: Tweaked computers and turtles (Minecraft modpack: All the Mods 10, multiplayer server).

## Dev loop
- In-game programs live in `programs/`. They sync to the computer's root, so `programs/foo.lua` runs as `foo`.
- The bridge must be running (`npm run bridge`; the user may already have it in a terminal tab). Check with `node bridge/cli.js computers`.
- Test a program: `node bridge/cli.js run <program> [args] [--c id] [--timeout s]`. This syncs, runs, and prints captured print/write/printError output, the return value or traceback, and the turtle's fuel.
- Inspect world or computer state: `node bridge/cli.js eval "<lua>"`, e.g. `turtle.inspect()`, `peripheral.getNames()`, `fs.list("/")`.
- Jobs run concurrently on the agent. Long jobs: if `run` times out it prints a job id; use `wait <id>`. `jobs` lists recent jobs, and `stop [id]` aborts one (or all).
- Permanent programs (farms etc.): `autorun <program> [args] --start` makes the agent start it on every boot, and `autorun --clear` removes it. Autorun jobs show up in `jobs` once they print.
- Full job records are in `logs/jobs/*.json`, and the event log is `logs/bridge.log`.
- Basic (non-advanced) computers: the agent runs next to the shell and logs its own messages to `/.agent/log`.
- Output written with `term.write` directly is not captured. Use print/write.
- Offline tests: `npm test` runs `tests/*_test.lua` in fengari against `tests/sim.lua`, a small CC: Tweaked turtle/world simulator. Test risky turtle programs there before running them in-game, and extend the simulator when a program needs more API.
- Turtle programs act in a shared multiplayer world: ask before running anything that digs, places or moves large distances.
- After changing `cc/agent.lua`: commit and push (install.lua downloads from GitHub main), then `node bridge/cli.js update-agent`.
- Repo: github.com/Muncherkin/cc-scripts (public; never commit `bridge/.state.json` or tokens).

## Docs, printing and messages
- `docs/` holds documents for the player (plans, guides, reports) in the printlist format: `# Title`, `> subtitle`, `## Section`, `- 35 Gold Ingot | note` (tickable checklist items), fenced ASCII art, plain text. Keep lines short: pockets are 26 wide, printed pages 25.
- `node bridge/cli.js docs` copies `docs/` to every connected pocket computer's `/docs` (Claude OS shows NEW badges and a toast). Update docs when plans change.
- `node bridge/cli.js print <path under docs/>` prints on whichever computer has a printer; if printing fails it sends the doc to the pockets instead.
- `node bridge/cli.js say "<text>"` posts a message to the wall dashboard and Claude OS.
- Claude OS (`programs/claudeos.lua`) talks to the bridge via `os.queueEvent("bridge_send", data)`; the agent relays it.
