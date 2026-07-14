extends Node

var editor = null
var mp = null
var log_label = null
var _is_applying_remote_input = false
var _queued_remote_inputs = []
var _remote_cursor_sprite: Sprite = null
var _last_synced_cursor_pos: Vector2 = Vector2(-1, -1)
var _cursor_board: Node2D = null  # for _process cursor sync
var _remote_selection_box: Control = null  # remote selection box renderer
var _remote_selection_tool: Node = null  # remote selection tool (ToolSelectionRemote)
var _simulator: Node = null  # the Systems/Simulator node (for tick alignment)
# MP tick-alignment (best-effort "pause/step on the same tick"). When the simulation PAUSES, the
# host is the tick authority: it broadcasts its paused tick once, and each client fast-forwards its
# own engine to match (forward-only — a free-running engine keeps no snapshots to rewind, and the
# catch-up is bounded). Stepping then stays aligned because both boards advance the same
# skip_tick_step. A peer already AHEAD of the host can't be pulled back, so the two won't ALWAYS
# land on the exact same tick; that's an accepted limitation. Off during free-run — each peer
# free-runs there.
var _sim_is_paused: bool = false
var _last_align_tick: int = -1  # last paused tick the host broadcast (-1 = none this pause)
var _local_sim_tick: int = 0    # our engine's last-seen tick (from sm_telemtry_change)
# Board-state consistency check (tiled anti-entropy) — triggered MANUALLY by the host from the
# Multiplayer window's DEBUG section (never automatic, so it can't fight an in-progress edit).
# On demand the host hashes each of the 4 layers in fixed tiles and broadcasts the compact
# tile-hash vector; a client compares its own tiles and pulls back only the DIFFERING ones from
# the host (the authority). The whole board is never sent.
const _DIGEST_TILE: = 256               # tile edge in pixels (2048/256 = 8 tiles per axis)
const _DIGEST_MAX_TILES_PER_REQ: = 64   # cap tiles pulled per check (bounds a pathological diff)
var _tiles_x: = 0
var _tiles_y: = 0
var _tiles_per_layer: = 0
var _tile_total: = 0


func _ready():
	yield(get_tree(), "idle_frame")
	_find_log_label()
	editor = _find_editor()
	mp = get_node_or_null("/root/MP")
	if mp:
		mp.connect("player_connected", self, "_on_player_connected")
		mp.connect("player_disconnected", self, "_on_player_disconnected")
	E.follow_events(self, [E.mi_mouse_input_on_board])
	# Also sync cursor brush pixels, tool changes, and camera transform
	E.follow_events(self, [E.ed_cursor_board_pixels_change])
	E.follow_events(self, [E.ot_camera_transform])
	# NOTE: array tool settings (repeat/amount, spacing, angle, auto-cross, multicolored)
	# are intentionally NOT synced. They are per-player brush settings — the other player's
	# strokes already carry their brush state per-stroke (p_brush_state in the mouse payload)
	# and their brush *preview* is mirrored via ed_cursor_board_pixels_change. Broadcasting
	# the setting-change events instead mutated the remote peer's OWN array tool, so changing
	# your repeat to 2 also changed theirs. Keep these local.
	E.follow_events(self, [
		E.ed_selection_area_change,
		E.ed_selection_image_change,
		E.ed_selection_paste_empty_cells_toggle,
		E.ed_selection_apply,
		E.ed_selection_copy,
		E.ed_selection_paste,
		E.ed_selection_delete,
		E.ed_selection_duplicate,
		E.ed_undo_request,
		E.ed_redo_request,
	])
	# Sync simulation events
	# Note: mi_mode_change_requested is already synced by mp_global.gd via RPC
	E.follow_events(self, [
		E.sm_speed_change,
		E.sm_pause_continue_toggle_tw,
		E.sm_next_step_request,
		E.sm_prev_step_request,
		E.sm_skip_iterations_step_change,
		E.sm_telemtry_change,
	])
	# Sync SHARED circuit/project settings. Clock interval, timer interval and the random
	# seed/mode feed the deterministic engine at build time (simulator.gd stores them and
	# passes them to TE.set_clock_timer_intervals / set_random_seed), so both peers must agree
	# or their engines diverge. The LED palette is a shared display/project setting (the remote
	# circuit_renderer recolours LEDs from it). These are GLOBAL, unlike the current draw
	# ink/paint colour which stays PER-PLAYER (carried per-stroke in the mouse payload).
	E.follow_events(self, [
		E.ed_clock_interval_change,
		E.ed_timer_interval_change,
		E.ed_random_seed_change,
		E.ed_random_is_time_seed_change,
		E.ed_led_palette_change,
		E.vd_vinput_value_change,
	])
	_resolve_remote_cursor_sprite()
	_resolve_remote_selection_nodes()
	_flush_queued_remote_inputs()
	_log("Initialized")


# Process-based cursor sync
func _process(_delta):
	# Broadcast cursor position every frame when connected (even before game_started)
	if mp == null or get_tree().network_peer == null or not mp.is_connected:
		return
	if not _cursor_board:
		_cursor_board = get_tree().root.find_node("CursorBoard", true, false)
	if not _cursor_board:
		return
	var mouse_pos = _cursor_board.get_global_mouse_position().floor()
	_maybe_sync_remote_cursor(mouse_pos)


# ==== Board-state consistency check (manual, host-initiated from the DEBUG section) =========
func _ensure_digest_init() -> bool:
	if _tile_total > 0:
		return true
	if not _ensure_editor():
		return false
	var w = int(C.CIRCUIT.SIZE.x)
	var h = int(C.CIRCUIT.SIZE.y)
	if w <= 0 or h <= 0:
		return false
	_tiles_x = int(ceil(float(w) / float(_DIGEST_TILE)))
	_tiles_y = int(ceil(float(h) / float(_DIGEST_TILE)))
	_tiles_per_layer = _tiles_x * _tiles_y
	_tile_total = _tiles_per_layer * 4
	return true


func _reset_digest() -> void:
	_tile_total = 0  # forces re-init on next session


func _editor_busy() -> bool:
	# True while an editor op is mid-flight — most importantly a FLOATING SELECTION lifted off
	# the board but not yet committed. A manual check skips a peer that is busy, so it never
	# clobbers an in-progress edit.
	return editor != null and editor.is_busy


# Host-only, invoked by the "Recheck board sync" DEBUG button: hash our authoritative board and
# broadcast the tile digest so every client can pull back any tiles that differ.
func host_run_consistency_check() -> void:
	if mp == null or not mp.is_host or not _has_network_peer():
		return
	if not _ensure_digest_init():
		return
	var hashes = _compute_all_tile_hashes()
	var peer_ids = _get_remote_peer_ids()
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_board_digest", hashes)
	_log("Consistency check: sent board digest to " + str(peer_ids.size()) + " client(s)")


func _compute_all_tile_hashes() -> PoolIntArray:
	# One synchronous full sweep. This is a manual, one-off action, so a brief hitch is fine.
	var hashes: = PoolIntArray()
	hashes.resize(_tile_total)
	for index in range(_tile_total):
		hashes[index] = _hash_tile(index)
	return hashes


func _hash_tile(index: int) -> int:
	var coords = _tile_coords(index)
	var img = editor.images[coords[0]]
	if img == null or img.get_width() <= 0:
		return 0
	var tile_img = img.get_rect(_tile_rect(coords[1], coords[2], img))
	return hash(tile_img.get_data())


func _tile_coords(index: int) -> Array:
	# -> [layer, tx, ty]
	var layer = index / _tiles_per_layer
	var within = index % _tiles_per_layer
	var ty = within / _tiles_x
	var tx = within % _tiles_x
	return [layer, tx, ty]


func _tile_rect(tx: int, ty: int, img: Image) -> Rect2:
	var x = tx * _DIGEST_TILE
	var y = ty * _DIGEST_TILE
	var w = int(min(_DIGEST_TILE, img.get_width() - x))
	var h = int(min(_DIGEST_TILE, img.get_height() - y))
	return Rect2(x, y, w, h)


remote func _rpc_board_digest(host_hashes: PoolIntArray) -> void:
	# Client side: the host ran a consistency check. Compare our tiles against the host's and
	# pull back any that differ. Skipped while WE have an edit in flight (a floating selection /
	# stroke) so a manual check never clobbers an in-progress edit.
	if not _ensure_digest_init() or _editor_busy():
		return
	if host_hashes.size() != _tile_total:
		return  # layout mismatch (different circuit size) — nothing sensible to do
	var mine = _compute_all_tile_hashes()
	var diffs = []
	for i in range(_tile_total):
		if host_hashes[i] != mine[i]:
			diffs.append(i)
	if diffs.empty():
		return
	if diffs.size() > _DIGEST_MAX_TILES_PER_REQ:
		diffs.resize(_DIGEST_MAX_TILES_PER_REQ)  # rest heal on a subsequent check
	_log("Consistency check: " + str(diffs.size()) + " tile(s) differ from host - pulling")
	if get_tree().network_peer != null:
		rpc_id(1, "_rpc_request_tiles", PoolIntArray(diffs))


remote func _rpc_request_tiles(indices: PoolIntArray) -> void:
	# Host side (authority): ship back only the requested tiles.
	if mp == null or not mp.is_host or not _ensure_digest_init():
		return
	var sender = get_tree().get_rpc_sender_id()
	var payloads = []
	for idx in indices:
		var p = _serialize_tile(int(idx))
		if not p.empty():
			payloads.append(p)
	if not payloads.empty():
		rpc_id(sender, "_rpc_apply_tiles", payloads)
		_log("Sent " + str(payloads.size()) + " authoritative tile(s) to peer " + str(sender))


remote func _rpc_apply_tiles(payloads: Array) -> void:
	# Client side: blit the host's authoritative tiles into place.
	if not _ensure_editor() or not _ensure_digest_init():
		return
	var applied = 0
	for p in payloads:
		if _apply_tile(p):
			applied += 1
	if applied > 0:
		E.echo(E.fs_file_modify, {})
		E.echo(E.ed_layers_resources_change, {
			E.ed_layers_resources_change.p_layers: editor.images, })
		_log("Applied " + str(applied) + " authoritative tile(s) from host")


func _serialize_tile(index: int) -> Array:
	if index < 0 or index >= _tile_total:
		return []
	var coords = _tile_coords(index)
	var img = editor.images[coords[0]]
	if img == null or img.get_width() <= 0:
		return []
	var rect = _tile_rect(coords[1], coords[2], img)
	var raw = img.get_rect(rect).get_data()
	var comp = raw.compress(File.COMPRESSION_ZSTD)
	return [index, comp, raw.size(), int(rect.size.x), int(rect.size.y)]


# ==== Shared undo/redo history reset (manual DEBUG button, affects everyone) ================
func reset_shared_history() -> void:
	# Clear the shared undo/redo history on EVERY peer, so a corrupted/desynced stack can be
	# recovered. Anyone may trigger it; a client routes through the host so all peers are hit.
	if mp == null or not _has_network_peer():
		_clear_local_history()  # not in a session — just clear our own
		return
	if mp.is_host:
		_clear_local_history()
		rpc("_rpc_reset_history")  # fan out to all clients
	else:
		rpc_id(1, "_rpc_host_reset_history")  # ask the host to fan out to everyone
	_log("Requested shared undo/redo history reset")


func _clear_local_history() -> void:
	var history = _get_history()
	if history != null and history.has_method("public_clear_history"):
		history.public_clear_history()


remote func _rpc_host_reset_history() -> void:
	# Host only: a client asked to reset everyone's history. Clear ours and fan out to all.
	if mp == null or not mp.is_host:
		return
	_clear_local_history()
	rpc("_rpc_reset_history")


remote func _rpc_reset_history() -> void:
	_clear_local_history()


func _apply_tile(p) -> bool:
	if p == null or typeof(p) != TYPE_ARRAY or p.size() < 5:
		return false
	var index = int(p[0])
	if index < 0 or index >= _tile_total:
		return false
	var comp = p[1] as PoolByteArray
	var dsize = int(p[2])
	var w = int(p[3])
	var h = int(p[4])
	if w <= 0 or h <= 0 or dsize <= 0 or comp.size() == 0:
		return false
	var coords = _tile_coords(index)
	var dst = editor.images[coords[0]]
	if dst == null:
		return false
	var raw = comp.decompress(dsize, File.COMPRESSION_ZSTD)
	var tile_img = Image.new()
	tile_img.create_from_data(w, h, false, Image.FORMAT_RGBA8, raw)
	dst.blit_rect(tile_img, Rect2(0, 0, w, h), Vector2(coords[1] * _DIGEST_TILE, coords[2] * _DIGEST_TILE))
	return true


func _find_editor():
	var root = get_tree().root
	var main = root.get_node_or_null("Main")
	if main:
		return main.find_node("Editor", true, false)
	return null


func _ensure_editor():
	if editor and is_instance_valid(editor):
		return true
	editor = _find_editor()
	return editor != null


func _find_log_label():
	var btn_logs = get_tree().root.find_node("BtnLogs", true, false)
	if btn_logs:
		var text_edit = btn_logs.find_node("TextEdit", true, false)
		if text_edit:
			log_label = text_edit


func _log(msg: String):
	if log_label:
		log_label.text += "[Sync] " + msg + "\n"
		log_label.scroll_vertical = log_label.get_line_count()


func _ev_mi_mouse_input_on_board(_mode: int, args: Dictionary):
	if _is_applying_remote_input:
		return
	# Always sync cursor position, even if not drawing
	if not args.has(E.mi_mouse_input_on_board.p_position):
		return
	_maybe_sync_remote_cursor(args[E.mi_mouse_input_on_board.p_position])
	# In simulation, board clicks are mouse OVERRIDES (interacting with the live circuit), not
	# draws. Mirror them on their own path carrying the sender's interaction mode, and DON'T fall
	# through to the drawing sync (which would replay the click with the peer's OWN mode, and
	# could even leak the click onto the peer's board as a remote stroke).
	if _is_simulating():
		_maybe_broadcast_sim_override(args)
		return
	if not _should_sync_input(args):
		return
	if not _is_sync_tool():
		return
	if not _has_network_peer():
		return
	if not _ensure_editor():
		return
	_broadcast_mouse_input(_build_mouse_payload(args))


func _should_sync_input(args: Dictionary) -> bool:
	if args == null:
		return false
	if not args.has(E.mi_mouse_input_on_board.p_position):
		return false
	return bool(args.get(E.mi_mouse_input_on_board.p_is_pressed, false)) or \
		bool(args.get(E.mi_mouse_input_on_board.p_is_just_pressed, false)) or \
		bool(args.get(E.mi_mouse_input_on_board.p_is_just_released, false))


func _build_mouse_payload(args: Dictionary) -> Dictionary:
	if not _ensure_editor():
		return {}
	var position = args.get(E.mi_mouse_input_on_board.p_position, Vector2.ZERO)
	var brush_state = _get_brush_state()
	var is_just_pressed = bool(args.get(E.mi_mouse_input_on_board.p_is_just_pressed, false))
	var is_just_released = bool(args.get(E.mi_mouse_input_on_board.p_is_just_released, false))
	var is_pressed = bool(args.get(E.mi_mouse_input_on_board.p_is_pressed, false))
	# Determine drawing state at send time, not from editor.is_drawing
	# is_drawing is true when pressed or just_pressed (stroke in progress)
	# is_drawing is false when just_released (stroke ended)
	var is_drawing_now = is_pressed or is_just_pressed
	# On a motion frame, broadcast the position the LOCAL tool actually used this frame (its
	# constrained last_pos) instead of the raw pointer position, so vanilla's SHIFT-straight /
	# CTRL-diagonal axis constraints reproduce on the remote (ToolSelection for the selection tool,
	# ToolArrayPencilEraser for pencil/array/eraser). Both set last_pos to the (possibly constrained)
	# pixel at the tail of select()/draw(); MPDrawSync runs after Editor, so that has already run.
	# On press/release last_pos isn't refreshed and the position isn't constrained anyway (raw used
	# then), and last_pos == the raw pixel whenever no modifier is held, so this is inert otherwise.
	if is_pressed and not is_just_pressed and not is_just_released:
		var _tool = int(editor.editor_tool)
		var constrain_src = null
		if _tool == Editor.TOOL.SELECTION:
			constrain_src = editor.get_node_or_null("ToolSelection")
		elif _tool == Editor.TOOL.PENCIL or _tool == Editor.TOOL.ARRAY or _tool == Editor.TOOL.ERASER:
			constrain_src = editor.get_node_or_null("ToolArrayPencilEraser")
		if constrain_src:
			position = constrain_src.last_pos
	return {
		E.mi_mouse_input_on_board.p_position: Vector2(int(position.x), int(position.y)),
		E.mi_mouse_input_on_board.p_is_pressed: is_pressed,
		E.mi_mouse_input_on_board.p_is_just_pressed: is_just_pressed,
		E.mi_mouse_input_on_board.p_is_just_released: is_just_released,
		E.mi_mouse_input_on_board.p_is_left_click: bool(args.get(E.mi_mouse_input_on_board.p_is_left_click, false)),
		"p_editor_tool": int(editor.editor_tool),
		"p_active_layer": int(editor.active_layer),
		"p_indexed_color_id": String(editor.indexed_color_id),
		"p_paint_color": editor.paint_color,
		"p_brush_state": brush_state,
		"p_bucket_state": _get_bucket_state(),
		"p_is_drawing": is_drawing_now,
		"p_is_remote": false,
		# ALT held while pressing on an existing selection = drag-to-duplicate (mirrors the local
		# ToolSelection.select() ALT branch). Ambient key state, so it must ride the payload for the
		# remote to reproduce it; inert unless ALT is actually down.
		"p_is_alt": BetterInput.is_key_pressed(KEY_ALT),
	}


# bucket settings are PER-PLAYER (like the array/pencil brush). They are
# carried per-op in the mouse payload so the remote reproduces our fill exactly WITHOUT
# mutating their own ToolBucket toggles.
func _get_bucket_state() -> Dictionary:
	if not editor:
		return {}
	var bucket_tool = editor.get_node_or_null("ToolBucket")
	if not bucket_tool:
		return {}
	return {
		"p_is_adjacent": bool(bucket_tool.is_adjacent),
		"p_is_pass_crosses": bool(bucket_tool.is_pass_crosses),
		"p_is_ignore_empty": bool(bucket_tool.is_ignore_empty),
	}


func _get_brush_state() -> Dictionary:
	var brush_tool = _get_brush_tool()
	if not brush_tool:
		return {}
	return {
		"p_pencil_size": int(brush_tool.pencil_size),
		"p_pencil_shape": int(brush_tool.pencil_shape),
		"p_array_amount": int(brush_tool.array_amount),
		"p_array_angle": int(brush_tool.array_angle),
		"p_array_space": brush_tool.array_angles_list[brush_tool.array_angle] if brush_tool.array_angles_list.size() > brush_tool.array_angle else Vector2.ZERO,
		"p_is_auto_cross": bool(brush_tool.is_auto_cross),
		"p_is_multicolored_traces": bool(brush_tool.is_multicolored_traces),
		"p_is_filter": bool(brush_tool.is_filter),  # sync filter state
	}


func _get_brush_tool():
	if not editor:
		return null
	return editor.get_node_or_null("ToolArrayPencilEraser")


func _get_remote_brush_tool():
	if not editor:
		return null
	return editor.get_node_or_null("ToolArrayPencilEraserRemote")


func _has_network_peer() -> bool:
	return mp != null and get_tree().network_peer != null and mp.is_connected and mp.is_game_started


func _get_remote_peer_ids() -> Array:
	var peer_ids = []
	if not mp:
		return peer_ids
	if mp.is_host:
		for peer_id in mp.connected_players:
			if int(peer_id) != 1:
				peer_ids.append(int(peer_id))
	else:
		peer_ids.append(1)
	return peer_ids


func _broadcast_mouse_input(payload: Dictionary):
	var peer_ids = _get_remote_peer_ids()
	if peer_ids.empty():
		return
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_mouse_input", payload)


func _broadcast_event(event_name: String, payload: Dictionary = {}):
	var peer_ids = _get_remote_peer_ids()
	if peer_ids.empty():
		return
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_event", event_name, payload)


remote func _rpc_apply_mouse_input(payload: Dictionary):
	if not _is_valid_mouse_payload(payload):
		return
	if not _ensure_editor():
		_queued_remote_inputs.append(payload.duplicate(true))
		return
	payload["p_sender_peer_id"] = get_tree().get_rpc_sender_id()
	_apply_remote_mouse_input(payload)


remote func _rpc_apply_event(event_name: String, payload: Dictionary):
	if not _is_valid_remote_event(event_name, payload):
		return
	_apply_remote_event(event_name, payload)


func _is_valid_mouse_payload(payload: Dictionary) -> bool:
	if payload == null or not payload.has(E.mi_mouse_input_on_board.p_position):
		return false
	var tool = int(payload.get("p_editor_tool", -1))
	return tool == Editor.TOOL.PENCIL or tool == Editor.TOOL.ARRAY or tool == Editor.TOOL.ERASER or tool == Editor.TOOL.SELECTION or tool == Editor.TOOL.BUCKET


func _is_sync_tool() -> bool:
	return editor != null and editor.editor_tool in [Editor.TOOL.PENCIL, Editor.TOOL.ARRAY, Editor.TOOL.ERASER, Editor.TOOL.SELECTION, Editor.TOOL.BUCKET]


func _is_valid_remote_event(event_name: String, payload: Dictionary) -> bool:
	return payload != null


func _apply_remote_mouse_input(payload: Dictionary):
	# Route all drawing/selection tools through remote tools
	var remote_tool_type = int(payload.get("p_editor_tool", -1))
	
	if remote_tool_type in [Editor.TOOL.PENCIL, Editor.TOOL.ARRAY, Editor.TOOL.ERASER, Editor.TOOL.SELECTION, Editor.TOOL.BUCKET]:
		_is_applying_remote_input = true
		editor.is_processing_remote_input = true
		if payload.has(E.mi_mouse_input_on_board.p_position):
			var remote_pos = payload[E.mi_mouse_input_on_board.p_position] as Vector2
			if _remote_cursor_sprite:
				_remote_cursor_sprite.position = remote_pos.floor()
				_remote_cursor_sprite.visible = true
		
		# Mark this as remote-applied so local-only UI (e.g. the mouse-position readout)
		# can ignore it and keep showing the *local* cursor. The board-editing consumers
		# don't look at this flag, so they still apply the remote stroke.
		payload["p_is_remote"] = true
		E.echo(E.mi_mouse_input_on_board, payload)
		
		editor.is_processing_remote_input = false
		_is_applying_remote_input = false


func _apply_remote_event(event_name: String, payload: Dictionary):
	var previous_editor_tool = editor.editor_tool
	if payload.has("p_editor_tool"):
		editor.editor_tool = int(payload["p_editor_tool"])
	_is_applying_remote_input = true
	# Route selection events to the remote tool, not the local ToolSelection
	# (which would bail because editor_tool is wrong). Apply on the SENDER's active layer
	# (carried in p_active_layer), not ours — otherwise a paste/apply lands on the wrong
	# layer when the two players are on different layers.
	var sel_layer = int(payload.get("p_active_layer", editor.active_layer))
	if event_name == "ed_selection_apply":
		var remote_sel = editor.get_node_or_null("ToolSelectionRemote")
		if remote_sel:
			remote_sel._active_layer = sel_layer
			# The preceding ed_selection_image_change(null) RPC already flushed (stamped) the
			# floating selection here via flush_selection(). If it didn't (arrived out of order, or
			# the selection was sub-minimum so the flush size-guard skipped it), commit it now.
			# ALWAYS delete_selection() afterwards so this peer registers the SAME two History
			# entries the sender did (apply_selection + delete_selection) — otherwise the shared
			# undo stack drifts one entry out of lockstep after every keyboard apply.
			if remote_sel.selection_image != null:
				remote_sel.apply_selection(sel_layer, true)
			remote_sel.delete_selection()
		_is_applying_remote_input = false
		editor.editor_tool = previous_editor_tool
		return
	if event_name == "ed_selection_paste":
		var remote_sel = editor.get_node_or_null("ToolSelectionRemote")
		if remote_sel:
			remote_sel._active_layer = sel_layer
			# Position + logic image were already applied by the area/image RPCs; paste_remote only
			# attaches the paint-on/off decoration layers from the mirrored clipboard.
			remote_sel.paste_remote()
		_is_applying_remote_input = false
		editor.editor_tool = previous_editor_tool
		return
	if event_name == "ed_selection_delete":
		var remote_sel = editor.get_node_or_null("ToolSelectionRemote")
		if remote_sel:
			remote_sel._active_layer = sel_layer
			remote_sel.delete_selection()
		_is_applying_remote_input = false
		editor.editor_tool = previous_editor_tool
		return
	if event_name == "ed_selection_duplicate":
		var remote_sel = editor.get_node_or_null("ToolSelectionRemote")
		if remote_sel and remote_sel.selection_image != null:
			# Reproduce vanilla duplicate_selection(): stamp a copy at the CURRENT (pre-offset)
			# position, keep the floating selection, and leave it at the offset position.
			# The ed_selection_area_change RPC for this duplicate arrived first and already moved
			# selection_area to the offset (P'), saving the pre-offset position (P) in
			# _area_before_last_rpc. Stamp at P, then restore P' so the floating ends up where the
			# sender's does. (Previously we stamped at the already-offset P', so the original
			# location was never re-filled — it looked like duplicate deleted the copy on the remote.)
			remote_sel._active_layer = sel_layer
			var offset_area = remote_sel.selection_area
			remote_sel.selection_area = remote_sel._area_before_last_rpc
			remote_sel.apply_selection(sel_layer, false)
			remote_sel.selection_area = offset_area
			remote_sel._update_remote_box_area()
		_is_applying_remote_input = false
		editor.editor_tool = previous_editor_tool
		return
	if event_name == "ed_selection_paste_empty_cells_toggle":
		# This is a PER-PLAYER setting. Store the sender's value on ToolSelectionRemote (used when we
		# replay their applies) instead of letting it fall through to E.emit_signal, which would
		# toggle THIS peer's own ToolSelection.is_paste_empty_cells — a per-player-setting leak.
		var remote_sel = editor.get_node_or_null("ToolSelectionRemote")
		if remote_sel:
			remote_sel.is_paste_empty_cells = bool(payload.get("p_is_enabled", false))
		_is_applying_remote_input = false
		editor.editor_tool = previous_editor_tool
		return
	# Toggle/tweakable (_tw) events must be replayed as ORDER, not the generic ECHO. Their handlers
	# gate on ASK_OR_ORDER and deliberately ignore ECHO (ECHO is the "resolved state" a handler emits
	# AFTER it acts). Replaying them as ECHO updated the remote's pause BUTTON but never set the
	# remote engine's is_continue — one peer kept free-running while the other was in step mode; and
	# because a step only takes effect while paused, next/prev step were dropped on the peer too.
	# ORDER carries the sender's confirmed p_is_pressed, so both peers converge; the target then
	# echoes to refresh its own UI. This generalizes the pause fix (#46) to every _tw event still
	# broadcast here (now just the pause toggle). The mouse-override-mode toggle is no longer
	# broadcast: the sim interaction mode is per-player, carried per click (see _rpc_apply_sim_click).
	if event_name.ends_with("_tw"):
		E.emit_signal(event_name, E.ORDER, payload)
	else:
		E.emit_signal(event_name, E.ECHO, payload)
	_is_applying_remote_input = false
	editor.editor_tool = previous_editor_tool


func _ev_ed_selection_area_change(_mode: int, args: Dictionary) -> void:
	if _is_applying_remote_input or not _has_network_peer():
		return
	# Broadcast local selection area to remote peer so they see our selection box
	var area = args.get(E.ed_selection_area_change.p_selection_area, Rect2())
	var tiles = args.get(E.ed_selection_area_change.p_selection_tiles, Vector2(1, 1))
	var from_mouse = _is_selection_mouse_active()
	var peer_ids = _get_remote_peer_ids()
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_remote_selection_area", area, tiles, from_mouse)


func _ev_ed_selection_image_change(_mode: int, args: Dictionary) -> void:
	if _is_applying_remote_input or not _has_network_peer():
		return
	# Broadcast local selection image to remote peer so they see our selection content.
	# Also carry the paint-on/off decoration layers: the image RPC used to send only the LOGIC
	# image, so a flip/rotate of a decorated LOGIC selection left the remote's decoration layers
	# un-transformed and committed mismatched paint. _local_selection_paint_layers() returns them
	# (empty off the LOGIC layer / with no decoration).
	var img = args.get(E.ed_selection_image_change.p_selection_image, null)
	var from_mouse = _is_selection_mouse_active()
	var paint = _local_selection_paint_layers()
	var peer_ids = _get_remote_peer_ids()
	if img == null:
		for peer_id in peer_ids:
			rpc_id(peer_id, "_rpc_apply_remote_selection_image", PoolByteArray(), 0, 0, from_mouse,
				paint[0], paint[1], paint[2], paint[3], paint[4], paint[5])
		return
	var img_data = img.get_data()
	var img_width = img.get_width()
	var img_height = img.get_height()
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_remote_selection_image", img_data, img_width, img_height, from_mouse,
			paint[0], paint[1], paint[2], paint[3], paint[4], paint[5])


# Serialize the local floating selection's paint-on/off decoration layers as
# [p_on_data, p_on_w, p_on_h, p_off_data, p_off_w, p_off_h]. Only LOGIC-layer selections carry
# decoration; everything else returns empties.
func _local_selection_paint_layers() -> Array:
	var res := [PoolByteArray(), 0, 0, PoolByteArray(), 0, 0]
	if not editor:
		return res
	var local_sel = editor.get_node_or_null("ToolSelection")
	if not local_sel:
		return res
	if local_sel.selection_image_p_on != null:
		res[0] = local_sel.selection_image_p_on.get_data()
		res[1] = local_sel.selection_image_p_on.get_width()
		res[2] = local_sel.selection_image_p_on.get_height()
	if local_sel.selection_image_p_off != null:
		res[3] = local_sel.selection_image_p_off.get_data()
		res[4] = local_sel.selection_image_p_off.get_width()
		res[5] = local_sel.selection_image_p_off.get_height()
	return res


# True only while the LOCAL player is mid BOARD selection gesture (marquee / move / tile) with the
# selection tool. In that case the very same selection change is ALSO mirrored to the remote as raw
# mouse input and replayed there on ToolSelectionRemote.select_remote(), which lifts / moves /
# re-applies the pixels itself and OWNS the remote tool's selection_area / selection_tiles /
# selection_image — so the area/image RPCs must then only refresh the green SelectionBoxRemote and
# must NOT touch those fields (writing them raced select_remote: the area RPC arrives first, set the
# tool to the post-move value, and select_remote then added the frame delta on top → the moved copy
# drifted; the drag-vs-new-select test was poisoned so the original pixels were never lifted).
#
# A held mouse button ALONE is not enough: left-clicking a blueprint in the library panel fires
# ed_selection_paste_blueprint_string with the button down, but that is NOT a board gesture and is
# NOT replayed through select_remote — so it must be treated as from_mouse=false or the area/image
# RPCs skip writing the remote tool state and the pasted blueprint never appears on the remote.
# Requiring an active gesture flag (is_selecting/is_dragging/is_tiling, set by select()) also keeps
# the release/capture behaviour unchanged (the button is already up on release → from_mouse false).
func _is_selection_mouse_active() -> bool:
	if not (Input.is_mouse_button_pressed(BUTTON_LEFT) or Input.is_mouse_button_pressed(BUTTON_RIGHT)):
		return false
	if not editor:
		return false
	var local_sel = editor.get_node_or_null("ToolSelection")
	if not local_sel:
		return false
	return local_sel.is_selecting or local_sel.is_dragging or local_sel.is_tiling


func _ev_ed_selection_paste_empty_cells_toggle(_mode: int, args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	_broadcast_event("ed_selection_paste_empty_cells_toggle", {
		"p_is_enabled": bool(args.get(E.ed_selection_paste_empty_cells_toggle.p_is_enabled, false)),
	})


func _ev_ed_selection_apply(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	if not _ensure_editor():
		return
	_broadcast_event("ed_selection_apply", {"p_active_layer": int(editor.active_layer)})


func _ev_ed_selection_copy(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	# Broadcast the clipboard so the remote can mirror it for paste.
	if not _ensure_editor():
		return
	if editor.editor_tool != Editor.TOOL.SELECTION:
		return
	var local_sel = editor.get_node_or_null("ToolSelection")
	# Read the *clipboard* (copy_selection_*), NOT the floating selection_image:
	# ToolSelection.copy_selection() clears selection_image (apply + delete) before this
	# handler runs, so reading selection_image here would always be null and the remote
	# clipboard would never sync — which is why pasted selections only appeared locally.
	if not local_sel or local_sel.copy_selection_image == null:
		return
	var img = local_sel.copy_selection_image
	var img_data = img.get_data()
	var img_w = img.get_width()
	var img_h = img.get_height()
	var area = local_sel.copy_selection_area
	var active_layer = int(editor.active_layer)
	# Also send paint layers if on LOGIC
	var p_on_data = PoolByteArray()
	var p_on_w = 0
	var p_on_h = 0
	var p_off_data = PoolByteArray()
	var p_off_w = 0
	var p_off_h = 0
	if active_layer == Editor.LAYER.LOGIC and local_sel.copy_selection_image_p_on != null:
		p_on_data = local_sel.copy_selection_image_p_on.get_data()
		p_on_w = local_sel.copy_selection_image_p_on.get_width()
		p_on_h = local_sel.copy_selection_image_p_on.get_height()
	if active_layer == Editor.LAYER.LOGIC and local_sel.copy_selection_image_p_off != null:
		p_off_data = local_sel.copy_selection_image_p_off.get_data()
		p_off_w = local_sel.copy_selection_image_p_off.get_width()
		p_off_h = local_sel.copy_selection_image_p_off.get_height()
	var peer_ids = _get_remote_peer_ids()
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_remote_copy", img_data, img_w, img_h, area, active_layer,
			p_on_data, p_on_w, p_on_h, p_off_data, p_off_w, p_off_h)


remote func _rpc_apply_remote_copy(img_data: PoolByteArray, img_w: int, img_h: int,
		area: Rect2, active_layer: int,
		p_on_data: PoolByteArray, p_on_w: int, p_on_h: int,
		p_off_data: PoolByteArray, p_off_w: int, p_off_h: int) -> void:
	if not _ensure_editor():
		return
	if not _remote_selection_tool:
		_resolve_remote_selection_nodes()
	if not _remote_selection_tool:
		return
	# Store the clipboard on the remote tool. Guard against 0×0 or missing data.
	if img_w <= 0 or img_h <= 0 or img_data.size() == 0:
		push_warning("[MPDrawSync] _rpc_apply_remote_copy: invalid image dimensions or empty data; ignoring")
		return
	var img = Image.new()
	var err = img.create_from_data(img_w, img_h, false, Image.FORMAT_RGBA8, img_data)
	if err != OK:
		push_warning("[MPDrawSync] _rpc_apply_remote_copy: create_from_data failed (err=%d); ignoring" % err)
		return
	_remote_selection_tool.copy_selection_area = area
	_remote_selection_tool.copy_selection_image = img
	if active_layer == Editor.LAYER.LOGIC and p_on_w > 0 and p_on_h > 0 and p_on_data.size() > 0:
		var p_on = Image.new()
		var err_on = p_on.create_from_data(p_on_w, p_on_h, false, Image.FORMAT_RGBA8, p_on_data)
		if err_on == OK:
			_remote_selection_tool.copy_selection_image_p_on = p_on
	if active_layer == Editor.LAYER.LOGIC and p_off_w > 0 and p_off_h > 0 and p_off_data.size() > 0:
		var p_off = Image.new()
		var err_off = p_off.create_from_data(p_off_w, p_off_h, false, Image.FORMAT_RGBA8, p_off_data)
		if err_off == OK:
			_remote_selection_tool.copy_selection_image_p_off = p_off
	# copy_selection() commits the copied floating on the sender (apply_selection(true) followed by
	# delete_selection()). The preceding ed_selection_image_change(null) RPC already flushed
	# (stamped) it here; if it hasn't yet (the copy RPC raced ahead), flush now. Then ALWAYS
	# delete_selection() so this peer registers the SAME trailing History entry the sender did —
	# otherwise a copy leaves the shared undo stack one entry longer on the sender than here.
	# (delete_selection() does not touch copy_selection_*, so the clipboard set above survives for
	# a later paste to reproduce the decoration layers.)
	if _remote_selection_tool.selection_image != null:
		_remote_selection_tool.flush_selection()
	_remote_selection_tool.delete_selection()


func _ev_ed_selection_paste(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		print("[MPDrawSync] _ev_ed_selection_paste: skipped (applying=", _is_applying_remote_input, " peer=", _has_network_peer(), ")")
		return
	if not _ensure_editor():
		return
	# Only the active layer is needed: paste position + logic image ride the area/image change
	# RPCs, and the decoration layers ride the clipboard (ed_selection_copy).
	_broadcast_event("ed_selection_paste", {"p_active_layer": int(editor.active_layer)})


func _ev_ed_selection_delete(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	if not _ensure_editor():
		return
	_broadcast_event("ed_selection_delete", {"p_active_layer": int(editor.active_layer)})


func _ev_ed_selection_duplicate(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	if not _ensure_editor():
		return
	# Duplicate = apply current floating + offset to a new position.
	# The new area/image will be synced via ed_selection_area_change + ed_selection_image_change.
	# Just tell the remote to apply the old floating and set up the new one.
	_broadcast_event("ed_selection_duplicate", {"p_active_layer": int(editor.active_layer)})


# === Host-authoritative shared undo/redo ===================================================
# The old design broadcast a raw ed_undo_request/ed_redo_request event and let each peer pop
# its OWN stack. That relies on both stacks being byte-identical AND on both peers reacting
# in the same order — which breaks under concurrency (simultaneous presses, a draw racing an
# undo, redo-invalidation races) and can underflow one stack but not the other. Collaborative
# editors avoid this by imposing a single TOTAL ORDER on shared-stack operations; a
# serialization protocol like that is what guarantees the replicas converge.
#
# Here the host is that serializer. A non-host client defers its local undo/redo (see
# History._is_network_controlled_client) and asks the host; the host performs the op on its
# own board (the ordering authority), and only if the op actually moved the stack does it fan
# the authorized op back out to every peer in one global order. An empty-stack press is a
# no-op that is never broadcast, so a client can never pop a phantom entry.
const _HIST_OP_UNDO: = 0
const _HIST_OP_REDO: = 1
# Per-frame de-dupe of the LOCAL undo/redo routing, mirroring History's guard. One physical
# press routes at most one op per frame (a host broadcast, or a client->host request), even if
# ed_undo_request / ed_redo_request is emitted twice in a single frame (e.g. under the runtime
# Mod Loader). RPC-applied ops (_rpc_apply_history_op) and the host's arbitration of a client's
# request (_rpc_request_history_op) go through separate paths and are never gated here, so two
# peers' ops can still legitimately land in the same frame.
var _last_undo_route_frame: int = -1
var _last_redo_route_frame: int = -1


func _ev_ed_undo_request(_mode: int, _args: Dictionary):
	_handle_local_history_request(_HIST_OP_UNDO)


func _ev_ed_redo_request(_mode: int, _args: Dictionary):
	_handle_local_history_request(_HIST_OP_REDO)


func _handle_local_history_request(op: int) -> void:
	var frame: int = Engine.get_frames_drawn()
	if op == _HIST_OP_UNDO:
		if frame == _last_undo_route_frame:
			return
		_last_undo_route_frame = frame
	else:
		if frame == _last_redo_route_frame:
			return
		_last_redo_route_frame = frame
	if _is_applying_remote_input or not _has_network_peer():
		return
	if not _ensure_editor():
		return
	var history = _get_history()
	if history == null:
		return
	if mp.is_host:
		# History ran first (it subscribed before this autoload) and already performed the op
		# locally. Fan it out only if it moved the stack.
		if op == _HIST_OP_UNDO and history.last_history_action == history.HA_UNDID:
			_broadcast_history_op(_HIST_OP_UNDO)
		elif op == _HIST_OP_REDO and history.last_history_action == history.HA_REDID:
			_broadcast_history_op(_HIST_OP_REDO)
	else:
		# Client deferred locally; ask the host to arbitrate.
		_send_history_request(op)


func _get_history():
	if not _ensure_editor():
		return null
	return editor.get_node_or_null("History")


func _broadcast_history_op(op: int) -> void:
	var peer_ids = _get_remote_peer_ids()
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_history_op", op)


func _send_history_request(op: int) -> void:
	# Clients route requests to the host (peer id 1).
	if get_tree().network_peer == null:
		return
	rpc_id(1, "_rpc_request_history_op", op)


remote func _rpc_apply_history_op(op: int) -> void:
	# Authorized by the host: apply on this peer, in the host's global order.
	var history = _get_history()
	if history == null:
		return
	if op == _HIST_OP_UNDO:
		history.perform_undo()
	else:
		history.perform_redo()


remote func _rpc_request_history_op(op: int) -> void:
	# Host only: arbitrate a client's undo/redo. Perform on the host, then fan the authorized
	# op out to all peers (including the requester) if it actually moved the stack.
	if mp == null or not mp.is_host:
		return
	var history = _get_history()
	if history == null:
		return
	if op == _HIST_OP_UNDO:
		history.perform_undo()
		if history.last_history_action == history.HA_UNDID:
			_broadcast_history_op(_HIST_OP_UNDO)
	else:
		history.perform_redo()
		if history.last_history_action == history.HA_REDID:
			_broadcast_history_op(_HIST_OP_REDO)


# Simulation event sync

func _ev_sm_speed_change(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var speed = float(_args.get(E.sm_speed_change.p_speed, 0.0))
	_broadcast_event("sm_speed_change", {E.sm_speed_change.p_speed: speed})


func _ev_sm_pause_continue_toggle_tw(_mode: int, _args: Dictionary):
	# Act on the CONFIRMED state only (the ECHO the simulator emits after it toggles is_continue),
	# not the ASK/ORDER request whose payload is empty.
	if not _mode & E.ECHO:
		return
	var is_pressed = bool(_args.get(E.sm_pause_continue_toggle_tw.p_is_pressed, false))
	# Track paused state on EVERY peer (this ECHO also fires when a REMOTE pause is applied), so the
	# host knows when to broadcast its authoritative tick for alignment. Reset the align sentinel on
	# unpause so the next pause re-broadcasts.
	_sim_is_paused = is_pressed
	if not is_pressed:
		_last_align_tick = -1
	# Mirror the pause to the peer. The remote applies it as ORDER (see _apply_remote_event) because
	# the simulator ignores ECHO on this event — that was why a pause never crossed to the peer.
	if _is_applying_remote_input or not _has_network_peer():
		return
	_broadcast_event("sm_pause_continue_toggle_tw", {E.sm_pause_continue_toggle_tw.p_is_pressed: is_pressed})


func _ev_sm_telemtry_change(_mode: int, _args: Dictionary):
	# Track our own engine's tick every frame (used to compute how far to catch up). Then, HOST
	# ONLY: broadcast our tick ONCE per pause (on entry) so clients fast-forward to match. We do NOT
	# re-broadcast after each step: step deltas are already synced (both advance the same
	# skip_tick_step via the mirrored next/prev-step + step-size), so once aligned at pause they stay
	# aligned through stepping — and re-aligning mid-step could double-advance a client that is also
	# applying the mirrored step. Ignored during free-run; peers free-run independently there.
	_local_sim_tick = int(_args.get(E.sm_telemtry_change.p_current_tick, 0))
	if _is_applying_remote_input or mp == null or not mp.is_host or not _has_network_peer():
		return
	if not _sim_is_paused or _last_align_tick != -1:
		return
	_last_align_tick = _local_sim_tick
	for peer_id in _get_remote_peer_ids():
		rpc_id(peer_id, "_rpc_align_tick", _local_sim_tick)


remote func _rpc_align_tick(target_tick: int) -> void:
	# Client side: the host reported its authoritative paused tick. Advance our engine by the
	# difference to catch up (bounded + forward-only + paused-only, all enforced in mp_advance_ticks).
	var sim = _get_simulator()
	if sim != null and sim.has_method("mp_advance_ticks"):
		sim.mp_advance_ticks(int(target_tick) - _local_sim_tick)


func _get_simulator():
	if _simulator and is_instance_valid(_simulator):
		return _simulator
	var main = get_tree().root.get_node_or_null("Main")
	if main:
		_simulator = main.find_node("Simulator", true, false)
	return _simulator


func _ev_sm_next_step_request(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	_broadcast_event("sm_next_step_request", {})


func _ev_sm_prev_step_request(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	_broadcast_event("sm_prev_step_request", {})


func _ev_sm_skip_iterations_step_change(_mode: int, _args: Dictionary):
	# Step Mode "ticks to advance per step" — shared, so a synced next/prev step advances the
	# SAME number of ticks on both boards and the deterministic engines stay in lockstep.
	if _is_applying_remote_input or not _has_network_peer():
		return
	var step = int(_args.get(E.sm_skip_iterations_step_change.p_step, 1))
	_broadcast_event("sm_skip_iterations_step_change", {E.sm_skip_iterations_step_change.p_step: step})


# === Simulation mouse-override (in-sim board clicks) =======================================
# While the sim runs, a board click is a "mouse override": it toggles / presses a latch in the LIVE
# circuit rather than drawing. VCB has two interaction modes (toggle vs press-and-hold) and that mode
# is a PER-PLAYER preference, so the click carries the SENDER's mode and the peer applies it with
# that mode (see Simulator.apply_remote_sim_click): a toggle-mode player's click toggles on both
# boards, a press-mode player's press/release forces the latch on/off on both, regardless of the
# other player's own mode. Both boards then hold the same override_set, so the deterministic engines
# stay in lockstep. (The mode toggle itself is no longer broadcast; it is per-player, carried per
# click.)
func _is_simulating() -> bool:
	var sim = _get_simulator()
	return sim != null and sim.is_run


func _maybe_broadcast_sim_override(args: Dictionary) -> void:
	if _is_applying_remote_input or not _has_network_peer():
		return
	var is_just_pressed = bool(args.get(E.mi_mouse_input_on_board.p_is_just_pressed, false))
	var is_just_released = bool(args.get(E.mi_mouse_input_on_board.p_is_just_released, false))
	# Only a press (both modes) or a release (press mode's momentary-off) changes an override.
	if not is_just_pressed and not is_just_released:
		return
	var sim = _get_simulator()
	if sim == null:
		return
	var position = args.get(E.mi_mouse_input_on_board.p_position, Vector2.ZERO)
	var payload = {
		E.mi_mouse_input_on_board.p_position: Vector2(int(position.x), int(position.y)),
		E.mi_mouse_input_on_board.p_is_just_pressed: is_just_pressed,
		E.mi_mouse_input_on_board.p_is_just_released: is_just_released,
		"p_is_toggle_mode": bool(sim.is_override_toggle_mode),
	}
	for peer_id in _get_remote_peer_ids():
		rpc_id(peer_id, "_rpc_apply_sim_click", payload)


remote func _rpc_apply_sim_click(payload: Dictionary) -> void:
	if payload == null or not payload.has(E.mi_mouse_input_on_board.p_position):
		return
	var sim = _get_simulator()
	if sim == null or not sim.has_method("apply_remote_sim_click"):
		return
	var sender = get_tree().get_rpc_sender_id()
	var position = payload[E.mi_mouse_input_on_board.p_position] as Vector2
	var is_just_pressed = bool(payload.get(E.mi_mouse_input_on_board.p_is_just_pressed, false))
	var is_just_released = bool(payload.get(E.mi_mouse_input_on_board.p_is_just_released, false))
	var is_toggle_mode = bool(payload.get("p_is_toggle_mode", true))
	# Surface where the remote is interacting (reuses the green remote cursor sprite).
	if not _remote_cursor_sprite:
		_resolve_remote_cursor_sprite()
	if _remote_cursor_sprite:
		_remote_cursor_sprite.position = position.floor()
		_remote_cursor_sprite.visible = true
	sim.apply_remote_sim_click(sender, position, is_just_pressed, is_just_released, is_toggle_mode)


# Shared circuit/project component settings (clock/timer/random feed the deterministic engine;
# LED palette is a shared display setting). Broadcast so both boards build identical simulations
# and render LEDs the same. The remote applies these through the generic _apply_remote_event
# path, so its simulator/renderer pick them up; the guard stops the applied event re-broadcasting.

func _ev_ed_clock_interval_change(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var interval = int(_args.get(E.ed_clock_interval_change.p_interval, 1))
	_broadcast_event("ed_clock_interval_change", {E.ed_clock_interval_change.p_interval: interval})


func _ev_ed_timer_interval_change(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var interval = int(_args.get(E.ed_timer_interval_change.p_interval, 500))
	_broadcast_event("ed_timer_interval_change", {E.ed_timer_interval_change.p_interval: interval})


func _ev_ed_random_seed_change(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var seed_value = int(_args.get(E.ed_random_seed_change.p_seed, 1))
	_broadcast_event("ed_random_seed_change", {E.ed_random_seed_change.p_seed: seed_value})


func _ev_ed_random_is_time_seed_change(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var is_time_seed = bool(_args.get(E.ed_random_is_time_seed_change.p_is_time_seed, false))
	_broadcast_event("ed_random_is_time_seed_change", {E.ed_random_is_time_seed_change.p_is_time_seed: is_time_seed})


func _ev_ed_led_palette_change(_mode: int, _args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var palette = _args.get(E.ed_led_palette_change.p_led_palette, [])
	_broadcast_event("ed_led_palette_change", {E.ed_led_palette_change.p_led_palette: palette})


func _ev_vd_vinput_value_change(_mode: int, _args: Dictionary):
	# The virtual-input register value is produced by LOCAL keyboard bindings (vinput_processor) and
	# fed into the deterministic engine, so any circuit that reads virtual input diverges between the
	# boards unless both simulators see the same value. Mirror it (last-writer-wins; the intended use
	# is one player driving the inputs — see the handoff note on the both-players-typing edge case).
	if _is_applying_remote_input or not _has_network_peer():
		return
	var value = int(_args.get(E.vd_vinput_value_change.p_value, 0))
	_broadcast_event("vd_vinput_value_change", {E.vd_vinput_value_change.p_value: value})




func _flush_queued_remote_inputs():
	if _queued_remote_inputs.empty():
		return
	if not _ensure_editor():
		return
	var queued_inputs = _queued_remote_inputs.duplicate(true)
	_queued_remote_inputs.clear()
	for payload in queued_inputs:
		if not payload.has("p_sender_peer_id"):
			payload["p_sender_peer_id"] = 1  # assume host if unknown
		_apply_remote_mouse_input(payload)


func _on_player_connected(id: int):
	_log("Player " + str(id) + " connected")
	_flush_queued_remote_inputs()


func _on_player_disconnected(id: int):
	_log("Player " + str(id) + " disconnected")
	_set_remote_cursor_visibility(false)
	_last_synced_cursor_pos = Vector2(-1, -1)
	# reset the consistency-check + tick-alignment state for the next session
	_reset_digest()
	_sim_is_paused = false
	_last_align_tick = -1


# === Remote cursor relay ===

# Sync cursor brush preview (pixels + size) to remote
func _ev_ed_cursor_board_pixels_change(_mode: int, args: Dictionary):
	if _is_applying_remote_input or not _has_network_peer():
		return
	var pixels = args.get(E.ed_cursor_board_pixels_change.p_pixels, [])
	var size = args.get(E.ed_cursor_board_pixels_change.p_size, Vector2(1, 1))
	var peer_ids = _get_remote_peer_ids()
	if peer_ids.empty():
		return
	# Convert pixels to a simpler format for RPC
	var flat_pixels = []
	for px in pixels:
		flat_pixels.append([int(px[0]), int(px[1])])
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_cursor_pixels", flat_pixels, size)


remote func _rpc_apply_cursor_pixels(flat_pixels: Array, size: Vector2):
	if not _remote_cursor_sprite:
		_resolve_remote_cursor_sprite()
	if not _remote_cursor_sprite:
		return
	var size_x = int(size.x)
	var size_y = int(size.y)
	var new_img = Image.new()
	new_img.create(size_x, size_y, false, Image.FORMAT_RGBA8)
	new_img.lock()
	for px in flat_pixels:
		var px_x = int(px[0]) + (size_x / 2)
		var px_y = int(px[1]) + (size_y / 2)
		if px_x >= 0 and px_x < size_x and px_y >= 0 and px_y < size_y:
			new_img.set_pixel(px_x, px_y, Color.white)
	new_img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(new_img, 0)
	_remote_cursor_sprite.texture = tex
	_remote_cursor_sprite.offset = Vector2(-int(size_x / 2), -int(size_y / 2))

func _resolve_remote_cursor_sprite() -> void:
	var cursor_remote = get_tree().root.find_node("CursorRemote", true, false)
	if cursor_remote:
		_remote_cursor_sprite = cursor_remote.get_node_or_null("Sprite")
		if _remote_cursor_sprite:
			# distinct color for remote cursor
			_remote_cursor_sprite.modulate = Color(0.3, 1.0, 0.3, 0.55)  # greenish tint
			_remote_cursor_sprite.visible = false
			return
	# Fallback: create the node structure if missing
	_make_remote_cursor_node()


func _make_remote_cursor_node() -> void:
	var world = get_tree().root.find_node("World", true, false)
	if not world:
		return
	var cursor_remote = Node2D.new()
	cursor_remote.name = "CursorRemote"
	cursor_remote.z_index = 10
	world.add_child(cursor_remote)
	_remote_cursor_sprite = Sprite.new()
	_remote_cursor_sprite.name = "Sprite"
	_remote_cursor_sprite.centered = false
	cursor_remote.add_child(_remote_cursor_sprite)
	# greenish tint for remote cursor
	_remote_cursor_sprite.modulate = Color(0.3, 1.0, 0.3, 0.55)
	_remote_cursor_sprite.visible = false
	# Set a default 1x1 texture
	var img = Image.new()
	img.create(1, 1, false, Image.FORMAT_RGBA8)
	img.lock()
	img.set_pixel(0, 0, Color.white)
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	_remote_cursor_sprite.texture = tex
	_remote_cursor_sprite.offset = Vector2(0, 0)


func _make_remote_cursor_texture() -> ImageTexture:
	var img = Image.new()
	img.create(4, 4, false, Image.FORMAT_RGBA8)
	img.lock()
	for x in 4:
		for y in 4:
			var cx = 1.5
			var cy = 1.5
			var dist = sqrt(pow(x - cx, 2) + pow(y - cy, 2))
			if dist < 1.5:
				img.set_pixel(x, y, Color(1, 1, 1, 0.8))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _set_remote_cursor_visibility(is_visible: bool) -> void:
	if _remote_cursor_sprite:
		_remote_cursor_sprite.visible = is_visible


func _maybe_sync_remote_cursor(pos: Vector2) -> void:
	# Only require connection, not game_started, for cursor hover
	if mp == null or get_tree().network_peer == null or not mp.is_connected:
		return
	if pos == _last_synced_cursor_pos:
		return
	if not _remote_cursor_sprite:
		_resolve_remote_cursor_sprite()
	if not _remote_cursor_sprite:
		return
	_last_synced_cursor_pos = pos
	var peer_ids = _get_remote_peer_ids()
	if peer_ids.empty():
		return
	for peer_id in peer_ids:
		rpc_id(peer_id, "_rpc_apply_cursor_pos", pos)


remote func _rpc_apply_cursor_pos(pos: Vector2) -> void:
	if not _remote_cursor_sprite:
		_resolve_remote_cursor_sprite()
	if not _remote_cursor_sprite:
		return
	# Hide cursor if out of bounds
	if pos.x < 0 or pos.y < 0 or pos.x >= 2048 or pos.y >= 2048:
		_remote_cursor_sprite.visible = false
		return
	_remote_cursor_sprite.position = pos.floor()
	_remote_cursor_sprite.visible = true


# Remote selection box sync
func _resolve_remote_selection_nodes() -> void:
	var root = get_tree().root
	var main = root.get_node_or_null("Main")
	if main:
		_remote_selection_box = main.find_node("SelectionBoxRemote", true, false)
	if editor:
		_remote_selection_tool = editor.get_node_or_null("ToolSelectionRemote")

func _ev_ot_camera_transform(_mode: int, args: Dictionary) -> void:
	# Forward zoom to remote selection box so dashed line scales correctly
	if _remote_selection_box:
		var zoom = args.get(E.ot_camera_transform.p_zoom, 1.0)
		_remote_selection_box.update_zoom(zoom)

# These RPCs are received from the OTHER peer's mp_draw_sync when their
# local ToolSelection emits ed_selection_area_change / ed_selection_image_change.
# We update our SelectionBoxRemote to show the other player's selection (green).
remote func _rpc_apply_remote_selection_area(area: Rect2, tiles: Vector2, from_mouse: bool = false) -> void:
	print("[MPDrawSync] _rpc_apply_remote_selection_area: area=", area, " tiles=", tiles)
	if not _remote_selection_box:
		_resolve_remote_selection_nodes()
	if _remote_selection_box:
		_remote_selection_box.update_area(area, tiles)
	# During a sender mouse gesture select_remote already reproduces this selection (lift / move /
	# tile / apply) and owns the remote tool's area + tiles — writing them here fought that path and
	# left the original pixels un-lifted and the moved copy off by the last drag delta. Only adopt
	# the sender's area/tiles for NON-mouse selections (paste / blueprint / dropped image / rotate),
	# which select_remote does not replay. Save the previous area first so the duplicate op-event
	# (whose area RPC carries the post-offset position) can still stamp at the pre-offset position.
	if _remote_selection_tool and not from_mouse:
		_remote_selection_tool._area_before_last_rpc = _remote_selection_tool.selection_area
		_remote_selection_tool.selection_area = area
		_remote_selection_tool.selection_tiles = tiles

remote func _rpc_apply_remote_selection_image(img_data: PoolByteArray, width: int, height: int, from_mouse: bool = false,
		p_on_data: PoolByteArray = PoolByteArray(), p_on_w: int = 0, p_on_h: int = 0,
		p_off_data: PoolByteArray = PoolByteArray(), p_off_w: int = 0, p_off_h: int = 0) -> void:
	print("[MPDrawSync] _rpc_apply_remote_selection_image: w=", width, " h=", height, " data_size=", img_data.size())
	if not _remote_selection_box:
		_resolve_remote_selection_nodes()
	var img: Image = null
	if width > 0 and height > 0:
		img = Image.new()
		img.create_from_data(width, height, false, Image.FORMAT_RGBA8, img_data)
	if _remote_selection_box:
		_remote_selection_box.update_image(img)
	# During a sender mouse gesture select_remote captures / lifts / re-applies the pixels itself and
	# owns selection_image; writing it here (or flushing) fought that path. Only adopt the sender's
	# image for NON-mouse selections (paste / blueprint / dropped image / flip / rotate). The
	# null-image flush stays gated the same way: it commits a floating selection applied WITHOUT a
	# board mouse event (e.g. the sender switched tools), which select_remote cannot observe.
	if _remote_selection_tool and not from_mouse:
		# Only flush if the new image is different from current (avoid double-apply)
		if _remote_selection_tool.selection_image != null and img == null:
			_remote_selection_tool.flush_selection()
		_remote_selection_tool.selection_image = img
		# Keep the paint-on/off decoration layers in lockstep so a flip/rotate of a decorated LOGIC
		# selection commits identically on both peers (the image RPC used to carry only the logic
		# image). Cleared when the selection is (img == null).
		if img == null:
			_remote_selection_tool.selection_image_p_on = null
			_remote_selection_tool.selection_image_p_off = null
		else:
			var p_on: Image = null
			if p_on_w > 0 and p_on_h > 0 and p_on_data.size() > 0:
				p_on = Image.new()
				p_on.create_from_data(p_on_w, p_on_h, false, Image.FORMAT_RGBA8, p_on_data)
			var p_off: Image = null
			if p_off_w > 0 and p_off_h > 0 and p_off_data.size() > 0:
				p_off = Image.new()
				p_off.create_from_data(p_off_w, p_off_h, false, Image.FORMAT_RGBA8, p_off_data)
			_remote_selection_tool.selection_image_p_on = p_on
			_remote_selection_tool.selection_image_p_off = p_off
