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

## 5. Selection sync: the `from_mouse` contract (read before touching it)

A selection op reaches the peer over **two** channels and they must not fight:

1. **Raw board input** (`_rpc_apply_mouse_input`) — replayed on the peer's `ToolSelectionRemote`
   (`select_remote`), which lifts / moves / tiles / re-applies the pixels itself. This is what
   mirrors a **mouse gesture**.
2. **`ed_selection_area_change` / `ed_selection_image_change`** (`_rpc_apply_remote_selection_*`) —
   always refresh the green `SelectionBoxRemote`, and additionally **write** the remote tool's
   `selection_area` / `selection_tiles` / `selection_image` (and flush a floating one) **only when
   `from_mouse == false`**. During a mouse gesture `select_remote` owns those fields; writing them
   too made the moved copy drift by the last drag delta.

`from_mouse` is computed by `MPDrawSync._is_selection_mouse_active()`. It must mean **"this change is
being emitted from inside `ToolSelection.select()`"** — nothing looser. The deciding test is the
`ToolSelection` extension's `_mp_select_depth` counter (bumped by the `select()` wrapper around
`_mp_select_body`). Inferring it from ambient state (a mouse button held + `is_selecting` /
`is_dragging` / `is_tiling`) silently DROPPED whole ops on the peer:

- a **keyboard/menu op** (Ctrl+C, Ctrl+V, apply, delete, rotate) fired while a button happened to be
  held is not replayed through `select_remote` at all, so with `from_mouse = true` its area/image was
  never adopted — the paste never appeared on the peer and the auto-confirm that followed had nothing
  to stamp (the "fast copy-paste doesn't send every op" bug);
- `is_selecting` / `is_dragging` / `is_tiling` can stay **stuck true** when a release never reaches
  `select()` (`Editor` drops a release while `is_drawing` is false, e.g. a popup stole focus
  mid-gesture), which poisons every later op while any button is down.

Related trap in `ToolSelectionRemote.flush_selection()`: the degenerate-selection guard must mirror
vanilla — discard only when **both** sides are under `MIN_SELECTION_SIZE` (that's the empty sentinel
`Rect2(-1,-1,1,1)`). Requiring both sides to reach the minimum refused to stamp any **thin**
selection (a 1px-tall trace, size 1×N), so it applied locally and vanished on the peer.

Keep the selection RPC path free of per-frame `print()`: `ed_selection_area_change` fires on every
motion frame of a drag, and a synchronous stdout write per frame is pure cost.

## 6. The shared board: what makes "two people on one board" actually hold

Everything else in this mod assumes **both peers hold byte-identical layers**: strokes are mirrored as
pixel ops onto a board that is expected to match, undo/redo is a shared stack of whole-layer
snapshots, and the native engine is only deterministic for identical layers. Three rules keep that
true — don't break them:

1. **A session starts with a board handoff.** `MPDrawSync._on_game_started` → `host_push_full_board()`
   → `_push_full_board()` ships every tile of all 4 layers to the clients (the same
   `_serialize_tile` / `_rpc_apply_tiles` path as the manual consistency check, batched by tile count
   AND compressed bytes), then resets the shared undo history on every peer so nobody can undo into a
   board it never had. Any floating selection is dropped first on both sides — those pixels were
   lifted off the PRE-session board. Before this, each peer just kept whatever it had open, so the two
   were editing different boards from the first second. **Every tile is sent, including empty ones**:
   an empty tile here may be a filled tile there and has to be cleared.
2. **Replacing the board locally re-pushes it** (`_ev_fs_project_change`): New / Open / a sample
   project mid-session would otherwise silently desync the session. Only the LAYERS travel — the
   file's assembly, vmem and notes do not, so opening a project mid-session is still best done from
   one side and announced.
3. **Mirror exactly the frames the local editor acted on** (`_should_mirror_stroke_frame`). MPDrawSync
   sees the same board echo the Editor does, but the Editor drops some of them, and every dropped
   frame we still sent became a stroke on the peer that the sender never made: input while a popup is
   focused, drag frames of a press that started off the board, and — subtly — a SHIFT/CTRL-constrained
   frame that resolves to the pixel the tool last used, where vanilla `draw()`/`select()` returns
   without painting. That last one is not harmless: **with Auto-cross on, re-painting a pixel turns the
   trace just drawn into CROSS pixels**, so the peer's board ends up different. A release is only
   mirrored if we mirrored its press. `Editor._input`'s direct `select(…, is_just_released, …)` call
   (a mouse-button event outside the world frame, which `cursor_board` never echoes) is mirrored
   explicitly through `MPDrawSync.mirror_selection_release`, or the peer's `ToolSelectionRemote` stays
   stuck mid-drag.

Also: **per-player editor state must ride the payload, never be read off the local editor.** The brush,
bucket toggles, layer, ink, paint colour and ALT already do. So does the ink **filter** (`p_filter`) —
`ToolArrayPencilEraserRemote.paint_brush_pixels` used to read the local `ED.filter`, so if either
player had a filter set, the other's stroke was filtered by the wrong list and the boards drifted.
A remote stroke also echoes `fs_file_modify`, like a local one: the peer's work must mark OUR file
dirty or the autosave and the unsaved-changes prompt ignore it.

**Known remaining gap:** two players painting the SAME pixel at the same instant converge to whichever
op each machine applied last — there is no total order on pixel ops. That needs the host-relay rework;
until then the Multiplayer window's DEBUG "Recheck board sync" heals it on demand.

## 7. Remote cursor visibility vs camera zoom

`MPDrawSync` renders a peer's cursor as a Sprite in **board space** (`World/CursorRemote/Sprite`,
textured from their brush pixels), so it shrinks with the board: zoomed out, a 1px brush is a
sub-pixel speck and the other player is invisible. `_update_remote_cursor_scale()` compensates by
scaling that sprite once the camera is zoomed out past **`CURSOR_ZOOM_DETAIL_THRESHOLD = 0.072`** —
deliberately the same number as `circuit_renderer.gd`'s `INK_SYMBOLS_OVERLAY_ZOOM_THRESHOLD`, i.e.
the zoom at which the board stops drawing ink detail and becomes just colours. (Camera2D zoom GROWS
as you zoom out, so `zoom < threshold` means close in.) From there on the marker holds the apparent
size it had at that threshold (1 board px ≈ 1/0.072 ≈ 14 screen px).

Two invariants to keep: it only ever **grows** a marker (`max(1.0, target / side)`), so a large brush
keeps its true board footprint instead of ballooning across the screen; and it must be re-applied
whenever the sprite's **texture** changes (the peer's brush size is part of the equation), not only on
camera transforms. The event's `p_zoom` is UI-scale-normalized (`camera.gd::emit_transform`), which is
what the renderer's threshold is expressed in too — compare like with like.

## 8. Git / PR workflow for agents

- Branch from `origin/main` (`git fetch origin main` first).
- **Branch names MUST start with `claude/` and END WITH the current session id**, or `git push`
  fails with HTTP 403. Example: `claude/<topic>-<sessionid>`.
- Commits are auto-signed (ssh). Don't disable signing/hooks.
- Open PRs against `main`; squash-merge. Note in the PR that it's unverified in-engine and give a
  Host+Join test recipe. A merge to `main` that bumps `version_number` auto-cuts a Release.
