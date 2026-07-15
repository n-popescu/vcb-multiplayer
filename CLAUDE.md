# CLAUDE.md — agent context for `vcb-multiplayer`

Read this first. Dense on purpose, for an AI coding agent. If it conflicts with the code, the
code wins — but verify before assuming this file is stale.

---

## 0. What this repo is

- This is the **public, open-source home of the runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader)
  build** of the VCB cooperative multiplayer mod. It loads at runtime from the game's `mods/`
  folder and **never replaces `vcb.pck`**, so it coexists with other Mod Loader mods.
- It is **pure GDScript + assets**. It only *extends* the game's own `res://` scripts and adds
  new networking scripts — it contains **none of the original game's source**, which is exactly
  why it is safe to publish here.
- It runs on the **original, closed-source VCB engine** (stock `vcb.exe` / `vcb.x86_64`). The
  native `Transistor*` classes are provided by the game at runtime; the Godot editor's "unknown
  class" warning for them is EXPECTED — never stub or reimplement them.

## 1. ⚠️ THE ONE RULE: keep the builds in lockstep

The exact same mod is shipped from **two repositories**:

| Repo | Visibility | Contains |
|---|---|---|
| **`vcb-multiplayer` (this)** | public | the **runtime Mod Loader** build only |
| `vcb-mp` | private | the legacy whole-`vcb.pck` build (`src/`, `mp/`, `mod.json`) **and** an identical copy of the runtime build under `runtime-mod/` |

`vcb-mp` is private because it embeds decompiled original-game source. This repo is the public
place to actually develop the runtime mod. All three must **always behave identically**:

> **Any functional change here MUST be mirrored into `vcb-mp` (both its `.pck` build under
> `src/`+`mp/` and its `runtime-mod/` copy) in the same unit of work — and vice-versa. Never
> let them drift.**

Concretely:

| You change… | Here (`vcb-multiplayer`) | In `vcb-mp` |
|---|---|---|
| A **multiplayer script** (`mp_global`, `mp_draw_sync`, `tool_*_remote`, `selection_box_remote`, GUI `btn_mp`/`mp_window`/`status_label`) | update `mods-unpacked/npopescu-VCBMultiplayer/scripts/…` | update the same file under `runtime-mod/…/scripts/…` (byte-identical) **and** the original under `src/…`/`mp/…` (also byte-identical) |
| A **game script the mod modifies** (`editor`, `history`, `shortcuts`, `tool_bucket`, `tool_selection`, `button_texture_event`, `button_toggle_run`, `simulation_controls`, `simulation_sliders`, `simulator`, `label_mouse_position`, `mouse_over_label`) | update the **script extension** under `mods-unpacked/…/extensions/<file>.gd` | update the same extension under `runtime-mod/…/extensions/` **and** make the real edit in `vcb-mp`'s `src/…` |
| A **new scene node** or an **autoload** | update the runtime builder in `mod_main.gd` | mirror in `runtime-mod/…/mod_main.gd` **and** add the node to `src/main/main.tscn` / the autoload to `project.godot` |
| A **new multiplayer file** | add under `scripts/…` (+ wire into `mod_main.gd`) | mirror under `runtime-mod/…` **and** add under `src/…`/`mp/…` (+ wire into `main.tscn`/`project.godot`) |

The `mods-unpacked/` tree here MUST stay **byte-identical** to `vcb-mp`'s
`runtime-mod/mods-unpacked/` tree. (This repo's `build.sh` / `.github/` / `README` differ from
`vcb-mp` because they're repo-level plumbing, but everything under `mods-unpacked/` is shared.)

**Versioning:** every functional change bumps the mod version (semver) in the same unit of work.
The version lives in `mods-unpacked/npopescu-VCBMultiplayer/manifest.json` (`version_number`) and
MUST equal `vcb-mp`'s `runtime-mod/…/manifest.json` **and** `vcb-mp`'s `mod.json` (`version`).
Bump them all together. A version bump landing on `main` here auto-publishes a Release.

## 2. How this build works (the porting model)

The whole-`vcb.pck` build changes the game three ways, and this package reproduces each without
editing any game file:

1. **Modified game scripts → script extensions** in `extensions/`. Each `extends "res://src/…"`
   and re-applies only that file's mod edits (calling the vanilla method via `.` where it only
   wraps it). Installed by `mod_main.gd` in `_init()`.
2. **New multiplayer scripts → shipped verbatim** under `scripts/`.
3. **New `main.tscn` nodes + the `MP`/`MPDrawSync` autoloads → rebuilt at runtime** by
   `mod_main.gd` (which waits for the Main scene to appear), using the **same node names /
   parents / scripts** so every lookup elsewhere still resolves. Do **not** extend `main.gd`
   (the main-scene root script) — that crashes the Mod Loader on this game; build the nodes
   from `mod_main.gd` instead.

## 3. Engine / GDScript constraints

- **Godot 3.5.1**, GDScript 3.5 semantics — **not** Godot 4. No Godot-4 syntax.
- **Tabs, not spaces**, in every `.gd`. Quick check: `grep -nP '^\t* +\S' <file>` must be empty
  for lines you add.
- The native `Transistor*` classes are runtime-only (see §0).
- You **cannot run or parse-check GDScript** in CI here — review carefully and verify in-game
  (two instances, Host + Join). Mod Loader logs go to the game's `user://ModLoader.log`.

## 4. Layout

```
.github/workflows/build.yml   zips the package + auto-releases on version bump
build.sh                      → npopescu-VCBMultiplayer.zip
mods-unpacked/npopescu-VCBMultiplayer/
├── manifest.json             Mod Loader manifest (id = npopescu-VCBMultiplayer)
├── mod_main.gd               installs the script extensions + builds the runtime nodes/autoloads
├── scripts/                  multiplayer scripts (byte-identical to vcb-mp)
└── extensions/               one script extension per changed game script (NOT main.gd)
```

## 5. Git / PR workflow for agents

- Branch from `origin/main` (`git fetch origin main` first).
- **Branch names MUST start with `claude/` and END WITH the current session id**, or `git push`
  fails with HTTP 403. Example: `claude/<topic>-<sessionid>`.
- Commits are auto-signed (ssh). Don't disable signing/hooks.
- Open PRs against `main`; squash-merge. Note in the PR that it's unverified in-engine and give a
  Host+Join test recipe. A merge to `main` that bumps `version_number` auto-cuts a Release.
