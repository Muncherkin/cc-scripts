# cc-scripts

ComputerCraft (CC: Tweaked) programs for All the Mods 10, plus a dev loop that
lets code written on the PC be pushed to in-game computers, run, and report
results back, without typing anything in Minecraft.

## How it works

```
PC                                         Minecraft server
programs/*.lua ─┐
                ├─ bridge (npm run bridge) ◄══ websocket (via ngrok tunnel)     ══► agent on CC computer
cli (npm run cc) ┘     logs/                                                     runs programs, sends output back
```

- `programs/`: the actual in-game programs. These get synced to the computer's root folder.
- `cc/agent.lua`: runs on the in-game computer and connects to the bridge.
- `cc/install.lua`: one-time installer for the agent.
- `bridge/server.js`: runs on the PC. Opens an ngrok tunnel (free dev domain) and
  publishes its URL to a secret gist, so agents can find the bridge after restarts.
- `bridge/cli.js`: controls everything from the terminal.

## Setup (once)

1. Install ngrok (`winget install --id Ngrok.Ngrok`), make a free account at ngrok.com, and run `ngrok config add-authtoken <token>`
2. `npm install`
3. `npm run bridge`. It prints an install command that starts with `wget run ...`.
4. In Minecraft, paste that command into a computer or turtle (Ctrl+V). The agent
   installs itself and starts on every boot. On advanced computers it runs in a
   background tab; on basic ones it runs quietly next to the shell.

## Daily use

Keep `npm run bridge` running, then:

```
npm run cc -- computers              # list connected computers
npm run cc -- run hello a b          # sync programs/ and run hello.lua with args
npm run cc -- eval "turtle.inspect()"  # evaluate Lua on the computer and print the result
npm run cc -- jobs                   # recent jobs and their state
npm run cc -- autorun farm --start   # run farm.lua now and on every boot
npm run cc -- stop                   # stop running jobs
npm run cc -- update-agent           # push a new cc/agent.lua and reboot
```

Use `--c <id>` when several computers are connected. Every job is saved to `logs/jobs/`.

## Programs

- `farm`: stationary wheat farm for a crafty farming turtle (diamond hoe + crafting
  table). The turtle sits on an output chest, with a buffer chest above and a crop on each side.
  It uses no fuel. See the comment at the top of `programs/farm.lua` for the layout.

## Notes

- The computer has to be in a loaded chunk to run anything.
- The token in the install command is the only thing that lets someone control
  your agents. Server admins can read it from the computer's files. At worst,
  that lets them run code on your in-game computers.
- Keep program files ASCII-only. Non-ASCII characters may get mangled in transit.
- Don't add a `startup.lua` to `programs/`. Use the `startup/` folder instead
  (the agent lives at `startup/00_agent.lua`).
