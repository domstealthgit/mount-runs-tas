# TAS Runner GUI

A companion script for the **TAS Creator** by Tomato. It lets you automatically loop and cycle through your recorded TAS runs with a clean in-game interface — no need to touch the original TAS script during playback at all.

> ⚠️ This script **requires recorded runs** made with the original TAS Creator script. It cannot record anything on its own. Make sure you have saved at least one run as a `.json` file before using this.

---

## How They Work Together

**TAS Creator** is the recording tool. You use it to record a perfect run of a game, then save it as a `.json` file which lands in your executor's `workspace/TAS_Recorder/` folder.

**TAS Runner GUI** is the playback tool. Once you have one or more saved runs, you open this script separately, pick which runs you want, and it will play them back automatically in a loop — hands free, no input needed.

Think of TAS Creator as the studio and TAS Runner as the player.

---

## TAS Runner GUI — Features

- **Config checklist** — all your saved runs are listed with checkboxes. Tick as many as you want to include in the loop.
- **Multi-run cycling** — if you select multiple configs (e.g. `run_1` and `run_2`), the script plays them in order: `run_1 → run_2 → run_1 → run_2 → ...` endlessly.
- **Looping playback** — once a run finishes it automatically goes back to the start. No manual restart needed.
- **Delay between runs** — set how many seconds the character stands still at the start position before each run begins. Useful for making the loop look natural and less suspicious.
- **Pause / Resume** — freezes the character at the exact current frame. Hit it again and it continues from exactly where it stopped.
- **Start / Stop** — one button to kick everything off or kill it instantly.
- **Refresh button** — rescan the folder for new files without closing the GUI. Just drop a new `.json` in the folder and hit ↻.
- **Live status display** — shows what's currently happening: idle, running, paused, or counting down to the next run.
- **Draggable window** — move it anywhere on screen.
- **Auto folder creation** — creates `workspace/TAS_Recorder/` automatically on first run if it doesn't exist yet.

---

## TAS Creator — Features

The original script by Tomato is a full tool for creating tool-assisted runs inside Roblox. Here is everything it can do:

- **Recording** — captures your character's position, velocity and camera every frame while you play.
- **Savestates** — save a point in your run to come back to. Add multiple savestates, remove the last one, or jump back into one to edit from that point.
- **Frame advance** — step forward or backward one frame at a time for pixel-perfect movement.
- **Pause / Unpause** — freeze time during recording so you can plan your next move.
- **Save run** — saves your run to your executor's workspace folder. Hold the key for JSON format, tap it for the compact binary `.tas` format.
- **Load run** — load a previously saved run back into the tool for editing or playback.
- **In-tool playback** — play back your recorded run directly inside the TAS Creator to review it.
- **Camera playback** — optionally replays the exact camera movements you recorded.
- **Velocity visualizer** — draws a predicted trajectory curve in the world so you can see where your character is heading.
- **TAS path display** — draws the future path of the run as a cyan line during playback.
- **Extreme smoothing** — downsamples frames and interpolates between them for a cinematic look (note: can cause clipping).
- **Collision toggler** — click any part in the world to toggle its collision on or off.
- **Debug view** — recolors the entire map to make hitboxes and geometry easier to read.
- **Auto load and play** — set a file name before running the script and it will load and play that run automatically on startup.

---

## Credits

- **Tomato** — creator of the original TAS Creator script that makes all of this possible.
- **domstealthgit** — creator of TAS Runner GUI.

---

## Links

- 📥 **TAS Creator Discord** — get the original script, updates and support: https://discord.gg/kGhNB2w9fp
- Loadstring to my TAS Runner: loadstring(game:HttpGet("https://raw.githubusercontent.com/domstealthgit/mount-runs-tas/refs/heads/main/runner.lua"))()
