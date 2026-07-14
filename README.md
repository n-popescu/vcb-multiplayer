# VCB Multiplayer

Cooperative peer-to-peer **multiplayer for [Virtual Circuit Board](https://store.steampowered.com/app/1885690/Virtual_Circuit_Board/)**,
running on the original game engine. Two players connect (ENet, UPnP-assisted on UDP `6777`)
and edit a shared board together in real time — drawing, selection, cursor, camera, undo/redo,
bucket fills and in-simulation latch/button presses all stay in sync.

This repository is the **open-source home of the runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader)
build** of the mod. It is **pure GDScript + assets** — it loads at runtime from the game's
`mods/` folder and **never replaces `vcb.pck`**, so it coexists with other Mod Loader mods.

> The mod only *extends* the game's own scripts (via `res://…` script extensions) and adds new
> networking scripts; it contains **none of the game's source**, which is why it can live in a
> public repo. Development also happens in a private repo (`vcb-mp`) that additionally holds the
> legacy whole-`vcb.pck` build; the two are kept in lockstep (see [`CLAUDE.md`](CLAUDE.md)).

## Install & run

1. In the [vcb-launcher](https://github.com/n-popescu/vcb-launcher), open the **Runtime
   modding** tab and click **Enable modding** (patches `vcb.pck` once with the Mod Loader).
2. Grab `npopescu-VCBMultiplayer.zip` from the [latest release](https://github.com/n-popescu/vcb-multiplayer/releases/latest),
   or build it yourself: `./build.sh`.
3. Drop that zip into the game's `mods/` folder (**📁 Mods folder** in the launcher).
4. Press **▶ Launch game**. Click **MP** in the toolbar to host or join.

## Playing

- One player hosts; hosting opens UDP port `6777` (via UPnP when the router supports it,
  otherwise forward it once or use a LAN IP). The other joins by IP.
- Both then edit the shared board — drawing, selection, cursor and camera are mirrored, and
  while simulating, latch/button presses are synced so both boards stay identical.
- Undo/redo is host-authoritative and shared. The Multiplayer window's **DEBUG** section has a
  host-only "Recheck board sync" (tiled anti-entropy) and a "Reset undo/redo history" button.

## How the mod is structured

The whole-`vcb.pck` build changed the game three ways: (a) editing stock game scripts,
(b) adding new multiplayer scripts, and (c) adding nodes + two autoloads to `main.tscn`. A
runtime mod can't edit `main.tscn` or the game's scripts directly, so this package reproduces
all three with **script extensions** + **runtime node construction**:

```
mods-unpacked/npopescu-VCBMultiplayer/
├── manifest.json          Mod Loader manifest (id = npopescu-VCBMultiplayer)
├── mod_main.gd            installs the script extensions + builds the runtime nodes/autoloads
├── scripts/               the multiplayer scripts (the MP/MPDrawSync autoloads, remote tools, GUI)
│   ├── mp_global.gd            → the MP autoload (ENet session, host/join)
│   ├── mp_draw_sync.gd         → the MPDrawSync autoload (mirrors editor + sim ops)
│   ├── tool_array_pencil_eraser_remote.gd
│   ├── tool_selection_remote.gd
│   ├── selection_box_remote.gd
│   └── gui/{btn_mp,mp_window,status_label}.gd
└── extensions/            one script extension per changed game script
    ├── editor.gd          remote-input routing
    ├── history.gd         host-authoritative shared undo/redo
    ├── shortcuts.gd       MP-aware run/pause + paste-at-cursor
    ├── tool_bucket.gd     parameterized fill + bucket_fill_remote
    ├── tool_selection.gd  paste lands at the cursor (mirrors correctly)
    ├── simulator.gd       cooperative simulation + best-effort tick alignment
    ├── simulation_controls.gd / simulation_sliders.gd   sim UI mirroring
    ├── button_texture_event.gd / button_toggle_run.gd   paste + run/pause buttons
    ├── camera.gd          trackpad pan/pinch
    └── label_mouse_position.gd / mouse_over_label.gd    side-panel readouts ignore the remote cursor
```

Each `extensions/<x>.gd` `extends "res://src/…/<x>.gd"` (the *game's* script, provided at
runtime) and re-applies only the mod's edits. `mod_main.gd` grafts the mod's `main.tscn` nodes
back on (same names/parents/scripts) and adds the `MP` / `MPDrawSync` autoloads once the Main
scene is ready.

## Building

```bash
./build.sh          # → npopescu-VCBMultiplayer.zip
```

CI (`.github/workflows/build.yml`) builds the zip on every push/PR and **auto-publishes a
GitHub Release** when the `version_number` in `mods-unpacked/npopescu-VCBMultiplayer/manifest.json`
is bumped on `main` (version-gated: it only cuts a release if the `v<version>` tag doesn't exist
yet). A manual `v*` tag push also publishes.

## Caveat — needs on-device testing

There is **no Godot binary in CI**, so GDScript here can't be parse-checked or run
automatically. Changes are written to mirror the game exactly and reviewed line-by-line, but
please verify in-game (two instances, Host + Join). Mod Loader logs are written to the game's
`user://` data dir (`ModLoader.log`).
