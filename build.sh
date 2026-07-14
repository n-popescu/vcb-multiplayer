#!/usr/bin/env bash
# Build the runtime multiplayer mod into a Godot Mod Loader .zip.
#
# The zip mounts into the game's res:// under mods-unpacked/, so the Mod Loader finds the
# mod at res://mods-unpacked/npopescu-VCBMultiplayer/. Drop the resulting zip into the
# game's mods/ folder (see the launcher's "Runtime modding" tab).
set -euo pipefail
cd "$(dirname "$0")"

OUT="npopescu-VCBMultiplayer.zip"
rm -f "$OUT"

# Zip the mods-unpacked/ tree so internal paths are exactly:
#   mods-unpacked/npopescu-VCBMultiplayer/manifest.json
#   mods-unpacked/npopescu-VCBMultiplayer/mod_main.gd
#   …
zip -r "$OUT" mods-unpacked \
	-x '*.DS_Store' -x '*/.*' >/dev/null

echo "Wrote $(pwd)/$OUT"
unzip -l "$OUT" | sed -n '1,40p'
