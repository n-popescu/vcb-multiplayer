extends Node

# --- Remote Selection Tool ---
# Full mirror of ToolSelection with separate state so two players can
# select / move / tile simultaneously without clobbering each other.
#
# This tool modifies the board just like the local ToolSelection — both
# players see the same board.
#
# Visual update flow:
# - LOCAL player selects → ToolSelection emits ed_selection_area_change →
#   mp_draw_sync broadcasts → remote peer's SelectionBoxRemote updates (green)
# - REMOTE player's input is replayed HERE via ToolSelectionRemote →
#   updates the LOCAL SelectionBoxRemote directly (green, on this machine)
#
# No RPC feedback loop: ToolSelectionRemote does NOT send RPCs back to
# the sender. It only updates the local SelectionBoxRemote node.

const MIN_SELECTION_SIZE = Vector2(2, 2)
const SELECTION_AREA_EMPTY = Rect2(Vector2(-1, -1), Vector2(1, 1))

var last_pos = Vector2(0, 0)
var selection_origin = Vector2(0, 0)
var selection_area = Rect2(Vector2(0, 0), Vector2(1, 1))
var selection_tiles = Vector2(1, 1)
var selection_image: Image = null
var selection_image_p_on: Image = null
var selection_image_p_off: Image = null
var background_image: Image = null
var first_pos = Vector2.ZERO
var is_selecting = false
var is_dragging = false
var is_tiling = false
var _selection_box_remote: Control = null
var _active_layer: int = 0
# The selection_area this tool held just BEFORE the most recent area-change RPC overwrote it.
# duplicate_selection() on the sender stamps a copy at the pre-offset position and then moves the
# floating selection away; the area RPC (which arrives before the duplicate op-event) has already
# overwritten selection_area with the offset position by the time we replay the duplicate, so we
# stamp at this saved pre-offset position instead. See mp_draw_sync.gd's duplicate handler.
var _area_before_last_rpc: Rect2 = Rect2(Vector2(-1, -1), Vector2(1, 1))
# Mirrors the SENDER's ToolSelection.is_paste_empty_cells (kept in sync by mp_draw_sync from the
# ed_selection_paste_empty_cells_toggle broadcast). When on, apply_selection clears the whole tiled
# region first, exactly like vanilla — otherwise a tiled apply with the toggle on left the gaps
# un-cleared on the remote. Per-player setting, so it is the SENDER's value (not this peer's own).
var is_paste_empty_cells: bool = false

# Clipboard state mirrored from local ToolSelection for copy/paste sync
var copy_selection_area: Rect2 = Rect2(Vector2(0, 0), Vector2(1, 1))
var copy_selection_image: Image = null
var copy_selection_image_p_on: Image = null
var copy_selection_image_p_off: Image = null

func _ready() -> void:
	selection_area = SELECTION_AREA_EMPTY
	background_image = Image.new()
	background_image.create(int(C.CIRCUIT.SIZE.x), int(C.CIRCUIT.SIZE.y), false, Image.FORMAT_RGBA8)
	_resolve_selection_box()

func _get_history() -> Node:
	# Mirror local ToolSelection: history is a sibling under Systems/Editor.
	var ED = get_parent()
	if not ED:
		return null
	return ED.get_node_or_null("History")

func set_mp_sync(_node: Node) -> void:
	# Kept for API compatibility with mp_draw_sync, but we don't use it.
	pass

func set_selection_box_remote(box: Control) -> void:
	_selection_box_remote = box

func _resolve_selection_box() -> void:
	if _selection_box_remote:
		return
	var root = get_tree().root
	var main = root.get_node_or_null("Main")
	if main:
		_selection_box_remote = main.find_node("SelectionBoxRemote", true, false)

func select_remote(pixel: Vector2, is_just_pressed: bool, is_just_released: bool,
					is_left_click: bool, active_layer: int, is_alt: bool = false) -> void:
	_active_layer = active_layer
	var ED = get_parent()
	var circuit_span = int(C.CIRCUIT.SIZE.x)
	pixel.x = clamp(pixel.x, 0, circuit_span)
	pixel.y = clamp(pixel.y, 0, circuit_span)

	if is_just_pressed:
		first_pos = pixel

	if is_just_released:
		if (selection_area.size.x < MIN_SELECTION_SIZE.x) and (selection_area.size.y < MIN_SELECTION_SIZE.y):
			is_selecting = false
			delete_selection()
			return
		if is_tiling:
			apply_selection(active_layer, true)
			delete_selection()
			is_tiling = false
		elif not is_dragging and is_selecting:
			selection_origin = selection_area.position
			# register history state on remote when a selection is captured
			# (mirrors local ToolSelection.select() release-with-capture branch).
			var history = _get_history()
			if history and history.has_method("public_register_state"):
				history.public_register_state(active_layer, true)
			_capture_selection(active_layer)
			is_selecting = false
		is_dragging = false
		return

	if is_just_pressed and is_left_click:
		if is_tiling:
			return
		is_dragging = selection_area.has_point(pixel)
		if is_dragging:
			last_pos = pixel
			# ALT-drag-to-duplicate: stamp a copy at the current position and keep dragging the
			# floating selection (mirrors local ToolSelection.select()'s ALT branch). Registers one
			# History entry, matching the sender, so the shared undo stack stays in lockstep.
			if is_alt:
				apply_selection(active_layer, false)
		else:
			# Committing a previous floating selection (or the paste) before starting a new one.
			# apply_selection already registers history at its tail.
			if selection_image != null:
				apply_selection(active_layer, true)
			selection_origin = pixel
			selection_area.position = pixel
			selection_area.size = Vector2(1, 1)
			_update_remote_box_area()
			is_selecting = true
			return

	if is_just_pressed and not is_left_click:
		if is_dragging or is_selecting:
			return
		is_tiling = selection_area.has_point(pixel)
		if is_tiling:
			last_pos = pixel

	if is_dragging:
		selection_area.position += pixel - last_pos
	elif is_tiling:
		var pos = selection_area.position
		var size = pixel - pos
		var tiles = (size / selection_area.size).floor()
		tiles.x += 2 * float(int(tiles.x) > -1) - 1
		tiles.y += 2 * float(int(tiles.y) > -1) - 1
		selection_tiles = tiles
	elif is_selecting:
		var pos = selection_origin
		var size = pixel - pos
		pos.x = pos.x if size.x > -1 else pos.x + size.x
		pos.y = pos.y if size.y > -1 else pos.y + size.y
		size.x = abs(size.x) + 1
		size.y = abs(size.y) + 1
		size.x = min(size.x, circuit_span - pos.x)
		size.y = min(size.y, circuit_span - pos.y)
		selection_area = Rect2(pos, size)

	_update_remote_box_area()
	last_pos = pixel

func _capture_selection(active_layer: int) -> void:
	var ED = get_parent()
	if not ED or not ED.images or active_layer >= ED.images.size():
		return

	selection_image = Image.new()
	selection_image.create(int(selection_area.size.x), int(selection_area.size.y), false, Image.FORMAT_RGBA8)
	selection_image.blit_rect_mask(ED.images[active_layer], ED.images[Editor.LAYER.LOGIC], selection_area, Vector2(0, 0))
	_update_remote_box_image()

	if active_layer == Editor.LAYER.LOGIC:
		selection_image_p_on = Image.new()
		selection_image_p_on.create(int(selection_area.size.x), int(selection_area.size.y), false, Image.FORMAT_RGBA8)
		selection_image_p_on.blit_rect(ED.images[Editor.LAYER.PAINT_ON], selection_area, Vector2(0, 0))
		selection_image_p_off = Image.new()
		selection_image_p_off.create(int(selection_area.size.x), int(selection_area.size.y), false, Image.FORMAT_RGBA8)
		selection_image_p_off.blit_rect(ED.images[Editor.LAYER.PAINT_OFF], selection_area, Vector2(0, 0))

	# Remove selected pixels from board (replace with background)
	ED.images[active_layer].blit_rect(background_image, Rect2(Vector2.ZERO, selection_area.size), selection_area.position)
	if active_layer == Editor.LAYER.LOGIC:
		ED.images[Editor.LAYER.PAINT_ON].blit_rect(background_image, Rect2(Vector2.ZERO, selection_area.size), selection_area.position)
		ED.images[Editor.LAYER.PAINT_OFF].blit_rect(background_image, Rect2(Vector2.ZERO, selection_area.size), selection_area.position)

	E.echo(E.fs_file_modify, {})
	E.echo(E.ed_layers_resources_change, {
		E.ed_layers_resources_change.p_layers: ED.images,
	})
	# NOTE: history is registered by the caller (select_remote) BEFORE this runs — exactly
	# once, at the pre-capture board state, mirroring the local ToolSelection.select() path.
	# Registering again here would push an extra entry and drift the shared undo stack out
	# of lockstep after a remote drag-select.

func apply_selection(active_layer: int, is_clear: bool) -> void:
	if selection_image == null:
		return
	var ED = get_parent()
	if not ED or not ED.images or active_layer >= ED.images.size():
		return

	# Mirror vanilla ToolSelection.apply_selection: when "paste empty cells" is on, clear the entire
	# tiled bounding region first so the gaps between tiles are wiped to background.
	if is_paste_empty_cells:
		var pos_tiled = selection_area.position
		var size_tiled = selection_area.size
		pos_tiled.x += (selection_tiles.x + 1) * size_tiled.x if selection_tiles.x < 0 else 0.0
		pos_tiled.y += (selection_tiles.y + 1) * size_tiled.y if selection_tiles.y < 0 else 0.0
		size_tiled.x += (abs(selection_tiles.x) - 1) * size_tiled.x
		size_tiled.y += (abs(selection_tiles.y) - 1) * size_tiled.y
		ED.images[active_layer].blit_rect(background_image, Rect2(Vector2.ZERO, size_tiled), pos_tiled)

	var signs = Vector2(sign(selection_tiles.x), sign(selection_tiles.y))
	for y in int(abs(selection_tiles.y)):
		for x in int(abs(selection_tiles.x)):
			var pos = selection_area.position
			pos += selection_area.size * Vector2(x * signs.x, y * signs.y)
			ED.images[active_layer].blit_rect_mask(selection_image, selection_image,
								Rect2(Vector2.ZERO, selection_area.size), pos)

	if active_layer == Editor.LAYER.LOGIC:
		if selection_image_p_on != null and not selection_image_p_on.is_invisible():
			for y in int(abs(selection_tiles.y)):
				for x in int(abs(selection_tiles.x)):
					var pos = selection_area.position
					pos += selection_area.size * Vector2(x * signs.x, y * signs.y)
					ED.images[Editor.LAYER.PAINT_ON].blit_rect_mask(
						selection_image_p_on, selection_image_p_on,
						Rect2(Vector2.ZERO, selection_area.size), pos)
		if selection_image_p_off != null and not selection_image_p_off.is_invisible():
			for y in int(abs(selection_tiles.y)):
				for x in int(abs(selection_tiles.x)):
					var pos = selection_area.position
					pos += selection_area.size * Vector2(x * signs.x, y * signs.y)
					ED.images[Editor.LAYER.PAINT_OFF].blit_rect_mask(
						selection_image_p_off, selection_image_p_off,
						Rect2(Vector2.ZERO, selection_area.size), pos)

	if is_clear:
		selection_image = null
		selection_image_p_on = null
		selection_image_p_off = null
		_update_remote_box_image()

	E.echo(E.fs_file_modify, {})
	E.echo(E.ed_layers_resources_change, {
		E.ed_layers_resources_change.p_layers: ED.images,
	})
	# register the post-apply state in remote history so undo stays in lockstep
	var history = _get_history()
	if history and history.has_method("public_register_state"):
		history.public_register_state(active_layer, true)
	ED.is_busy = false if is_clear else true

func delete_selection() -> void:
	selection_image = null
	selection_image_p_on = null
	selection_image_p_off = null
	selection_area = SELECTION_AREA_EMPTY
	selection_tiles = Vector2(1, 1)
	is_selecting = false
	is_dragging = false
	is_tiling = false
	_update_remote_box_area()
	_update_remote_box_image()
	var ED = get_parent()
	if ED:
		ED.is_busy = false
	# a delete is a board mutation, register a history entry.
	if ED:
		var history = _get_history()
		if history and history.has_method("public_register_state"):
			history.public_register_state(_active_layer, true)

func _update_remote_box_area() -> void:
	if not _selection_box_remote:
		_resolve_selection_box()
	if _selection_box_remote:
		_selection_box_remote.update_area(selection_area, selection_tiles)

func _update_remote_box_image() -> void:
	if not _selection_box_remote:
		_resolve_selection_box()
	if _selection_box_remote:
		_selection_box_remote.update_image(selection_image)

func clear_selection() -> void:
	delete_selection()

# Called by mp_draw_sync before overwriting our state via RPC.
# If we have a floating selection, put its pixels back on the board first.
# This handles copy/paste/re-apply on the local player's side correctly:
# the remote board must receive the pixels that the local board already got.
func flush_selection() -> void:
	if selection_image != null and selection_area.size.x >= MIN_SELECTION_SIZE.x and selection_area.size.y >= MIN_SELECTION_SIZE.y:
		apply_selection(_active_layer, true)

# paste remote replay — called by mp_draw_sync when ed_selection_paste arrives from the peer.
#
# The paste POSITION and the LOGIC-layer image are already synced by the ed_selection_area_change /
# ed_selection_image_change RPCs that precede the paste op-event (paste_selection() emits
# AREA_AND_IMAGE, and any prior floating was committed by the preceding null-image flush). Those
# RPCs do NOT carry the paint-on / paint-off decoration layers, so the only thing left to do here
# is attach the decoration from the mirrored clipboard.
#
# Deliberately do NOT flush a prior floating or recompute the position here. The old code did
# `apply_selection(true)` + re-centred the paste at a re-derived mouse position, which (a) stamped
# the freshly-pasted pixels onto the remote board a second time and (b) shifted the paste off by
# up to the last drag delta because it raced the authoritative area RPC.
func paste_remote() -> void:
	if selection_image == null:
		return
	if copy_selection_image_p_on != null and copy_selection_image_p_off != null:
		selection_image_p_on = copy_selection_image_p_on.duplicate()
		selection_image_p_off = copy_selection_image_p_off.duplicate()
	else:
		selection_image_p_on = null
		selection_image_p_off = null
	var ED = get_parent()
	if ED:
		ED.is_busy = true
