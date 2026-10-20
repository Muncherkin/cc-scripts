# cc-scripts: notes for Claude

Lua programs for CC: Tweaked computers and turtles (Minecraft modpack: All the Mods 10, multiplayer server).

## Dev loop
- In-game programs live in `programs/`. They sync to the computer's root, so `programs/foo.lua` runs as `foo`.
- The bridge must be running (`npm run bridge`; the user may already have it in a terminal tab). Check with `node bridge/cli.js computers`.
- Test a program: `node bridge/cli.js run <program> [args] [--c id] [--timeout s]`. This syncs, runs, and prints captured print/write/printError output, the return value or traceback, and the turtle's fuel.
- Inspect world or computer state: `node bridge/cli.js eval "<lua>"`, e.g. `turtle.inspect()`, `peripheral.getNames()`, `fs.list("/")`.
- Long jobs: if `run` times out it prints a job id; use `wait <id>`. Use `stop` to abort.
- Full job records are in `logs/jobs/*.json`, and the event log is `logs/bridge.log`.
- Output written with `term.write` directly is not captured. Use print/write.
- Turtle programs act in a shared multiplayer world: ask before running anything that digs, places or moves large distances.
- After changing `cc/agent.lua`: commit and push (install.lua downloads from GitHub main), then `node bridge/cli.js update-agent`.
- Repo: github.com/Muncherkin/cc-scripts (public; never commit `bridge/.state.json` or tokens).
