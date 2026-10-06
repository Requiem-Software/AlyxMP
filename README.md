# Alyx Multiplayer

Online co-op for Half-Life: Alyx. One player hosts, friends join, and everyone plays the campaign together.
Other players show up as Alyx with walk/run/crouch animations, their actual weapon in hand, muzzle flashes,
gunshot sounds and a name tag. Works with a VR headset or without one through
[HLA NoVR](https://github.com/HLANoVR/HLA-NoVR), which the installer can set up for you.

## Install

1. Run `AlyxMP-Setup.exe`. Windows SmartScreen may warn about an unknown publisher (the exe isn't
   code-signed): **More info → Run anyway**.
2. It finds your Half-Life: Alyx folder by itself (or press **Browse...**).
3. Leave **Install HLA NoVR** ticked if you want to play with mouse and keyboard. It downloads NoVR
   (about 140 MB) from its official GitHub repository.
4. Press **INSTALL**, then **PLAY**.

Everyone in the game needs the same Alyx MP version, the same game version and, if they use it, NoVR.
SteamVR must be installed (the game needs it even without a headset).

## Play

**Host:** open *Alyx Multiplayer*, type your name, press **START HOSTING**. The game starts. Send your
friends the address shown under the button (the **Copy** button copies it). The first time, Windows will
ask whether *AlyxMP* may use the network: allow it.

- *Open the port on my router automatically (UPnP)* works on most home routers. If it can't, forward TCP
  port 27420 to your PC in your router, or play over a VPN such as Tailscale, ZeroTier or Radmin VPN and
  share that address instead.
- Optional password: friends type the same one when joining.

**Join:** type your name, paste the host's address, press **JOIN**. Your game starts and loads the host's
world, and you appear next to them.

**In game**
- Other players appear as Alyx (moving with the Combine soldiers' animations: setting off, running, stopping,
  crouching, with the steps matched to how fast they move) with their name above them. Their flashlight shows
  when they turn it on. The top-left corner lists who's playing and how far away they are.
- **Loading zones:** when you get within a couple of metres of a level exit, it fades in, outlined on the floor
  and marked *LOADING ZONE*. The next area only loads once everybody is standing inside it, and the screen says
  who it's waiting for. Whoever finishes loading
  first waits, paused, until everyone is in.
- If you die, you respawn next to the host from the host's world.
- If someone's world gets out of step, press **RESYNC MY WORLD** (or **SEND MY WORLD TO ALL** as the host).
- Chat: press **Y** in game to open the chat line (Enter sends, Esc cancels), or type in the launcher
  window. Messages show up on the left side of everyone's screen.
- A dot appears in the middle of the crosshair when E would do something with what you're looking at.
- **F10** opens the settings menu: auto reload, the Half-Life 2 HUD, name tags, the interaction dot, the player
  list, chat messages and loading zone outlines. The first two change game files and apply the next time the
  game starts; the rest apply at once.
- The game saves itself every 5 minutes and whenever everyone has made it into a new level (the host's
  autosave, which is the world everyone comes back to).
- The HUD, menus and messages use Half-Life: Alyx's own typeface (Raju) and look.

## How it works

Every player runs their own copy of the game. The launcher is the network part: it links to the game through
the game's built-in VConsole port, sends your position, animation state and shots to the host, and receives
everyone else's. The in-game half (Lua in `scripts/vscripts/alyxmp/`) draws the other players and handles
loading zones. The host is in charge:

- When you join, die, or fall out of step, the host's save file is sent to you and loaded, so you're in
  exactly the host's world (same level, enemies, doors, story progress).
- Level changes happen together.
- Objects someone moves, throws or carries move in everyone's game (smoothed); items someone picks up
  disappear for everyone; anything someone breaks breaks for everyone.
- Story triggers, buttons, levers, doors, hacking puzzles, combine consoles, wire (toner) puzzles and
  story items (Russell's headset, the gravity gloves, batteries, keycards, weapons) that one player uses are
  replayed in everyone's game, so doors open, cutscenes start and items are handed out for all: when one
  player takes a gun (like the shotgun off the hanging zombie), everyone gets it. Anything you press E on goes
  through NoVR's own interaction script, and the launcher adds one line to it
  (`scripts/vscripts/useextra.lua`) so the others run the same thing.
- Wheels, cranks, levers and sliding doors that you work with your hands (the winch in front of the
  shotgun, the greenhouse door after Eli's call) move in everyone's game as you turn them.
- Bars and pipes wedged through door handles: pulling one out frees the door for everyone.
- Drawing on windows/boards with the markers shows up for everyone (the marker's strokes are replayed).
- Enemies: the host's game is the reference for their health and position; damage anyone deals counts on
  the host, and when anyone kills an enemy it dies in everyone's game. Enemies go after every player, not
  just the one whose game they're in (each player's avatar carries an invisible target for them), and
  objects that enemies or explosions knock around are moved by the host's game for everyone.
- Shots show for everyone with muzzle flash, sound, tracer and impact.

### VR and NoVR together

VR and NoVR players can share a session. A NoVR host's save has no VR hands in it, so a VR player who
joins (or respawns) doesn't load it: their game loads the same level fresh and replays everything that
already happened there (story triggers, uses, pickups, breaks, kills, where objects ended up), then puts
them next to the host. VR games also skip the "Press trigger to start" screen after loads.

### Limits

- Each world still runs its own AI: an enemy attacks the players in each game on its own and is pulled back
  in line with the host's copy, so the details of a fight can differ a little between players.
- Objects are matched between games by what they are and where they were first seen (stamped into the
  save), so things spawned mid-level (e.g. crate loot) can still differ per player.
- VR players appear with full-body animation; their real hand movements aren't mirrored yet.
- Name tags and the HUD use the game's debug overlay, which shows on monitors (NoVR), not inside a headset.
- The game's VConsole port (29000) is opened by the game itself; don't forward it on your router.

## Files it changes

- `game/hlvr/scripts/vscripts/alyxmp/`: the mod's Lua
- `game/hlvr/cfg/skill_manifest.cfg`: adds `script_reload_code alyxmp/main` so it loads on every map
- `AlyxMP/` in the game folder: the launcher
- With NoVR: NoVR's files, plus its search paths added to `game/hlvr/gameinfo.gi` (a backup is kept as
  `gameinfo.gi.alyxmp_backup`)

### Changes to NoVR

Alyx MP uses a slightly modified NoVR. NoVR's own files stay as they are; the changes sit next to them and
are undone on uninstall:

- one line at the top of `game/hlvr/scripts/vscripts/useextra.lua`, NoVR's interaction script, that tells the
  mod what you used
- `game/alyxmp_hud/`: Half-Life 2's HUD layout, colours and fonts for NoVR's HUD (with Half-Life 2's own
  number font if Half-Life 2 is installed), mounted ahead of NoVR (settings menu: *Half-Life 2 HUD*)
- `game/alyxmp_autoreload/`: NoVR's gun scripts without the "never reload by yourself" flag, mounted ahead of
  NoVR (settings menu: *Auto reload*)
- Joined sessions save into `SAVE/amp_mp/`, separate from your own saves

Uninstall by running `AlyxMP-Setup.exe` again and pressing **Uninstall**. Your saves are not touched.

## Build from source

Requires the .NET SDK (any version that can target .NET Framework 4.8, which ships with Windows).

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

This produces `dist/AlyxMP-Setup.exe`. `tools/` has the dev helpers used during development (VConsole client,
fake peers, screenshot capture).

Fan-made mod, not affiliated with Valve. HLA NoVR is made by the HLA NoVR team (GPL-3.0) and is downloaded
from their repository at install time.
