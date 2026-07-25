extends "res://src/editor/editor.gd"

# vcb-mp runtime port — script extension of the game's Editor.
#
# The whole-pck build injected a "remote input" branch into _ev_mi_mouse_input_on_board,
# AFTER update_cursor and the is_in_editor/is_focused guard and BEFORE the local drawing
# flow. Because the change is in the middle of the function, we reproduce the whole handler
# verbatim (with the branch in the exact same spot) rather than call the vanilla one. When
# MPDrawSync replays another player's board input it sets is_processing_remote_input, so we
# route to the *Remote tools (children of Editor added at runtime by the mod).

var is_processing_remote_input: = false


# Vanilla ends a selection gesture whose mouse-button event lands OUTSIDE the world frame by calling
# ToolSelection.select() directly (cursor_board only echoes events inside the frame). That direct call
# is invisible to MPDrawSync, so the peer's ToolSelectionRemote never learned the drag ended and stayed
# stuck with is_dragging / is_selecting set — its next press was then mis-read as a drag of a selection
# that no longer existed. Reproduce vanilla and mirror the release.
func _input(event: InputEvent) -> void :
	if event is InputEventMouseButton:
		if not is_world_frame_context and (editor_tool == TOOL.SELECTION):
			var is_left_click: bool = event.button_index == BUTTON_LEFT
			$ToolSelection.select(last_mouse_pos, false, true, is_left_click)
			var draw_sync = get_tree().root.get_node_or_null("/root/MPDrawSync")
			if draw_sync != null and draw_sync.has_method("mirror_selection_release"):
				draw_sync.mirror_selection_release(last_mouse_pos, is_left_click)


func _ev_mi_mouse_input_on_board(_mode: int, _args: Dictionary) -> void :
	var p_position: Vector2 = _args[E.mi_mouse_input_on_board.p_position]
	var p_is_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_pressed]
	var p_is_just_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_just_pressed]
	var p_is_just_released: bool = _args[E.mi_mouse_input_on_board.p_is_just_released]
	var p_is_left_click: bool = _args[E.mi_mouse_input_on_board.p_is_left_click]
	update_cursor(p_position, p_is_pressed, p_is_just_pressed, p_is_just_released, p_is_left_click)
	if not is_in_editor or not is_focused:
		return
	# Remote input bypasses local drawing state checks.
	if is_processing_remote_input:
		# Remote drawing has its own state, skip local is_drawing guards
		var remote_tool = $ToolArrayPencilEraserRemote
		var remote_selection_tool = $ToolSelectionRemote
		var remote_editor_tool = int(_args.get("p_editor_tool", editor_tool))
		var remote_active_layer = int(_args.get("p_active_layer", active_layer))
		var remote_indexed_color_id = String(_args.get("p_indexed_color_id", indexed_color_id))
		var remote_paint_color = _args.get("p_paint_color", paint_color) as Color
		var remote_brush_state = _args.get("p_brush_state", {})
		# The ink filter is the SENDER's (per-player editor state, like the brush) — never ours.
		var remote_filter = _args.get("p_filter", [])
		if remote_editor_tool in [Editor.TOOL.ARRAY, Editor.TOOL.PENCIL, Editor.TOOL.ERASER]:
			remote_tool.apply_brush_state(remote_brush_state, remote_editor_tool)
			var remote_is_drawing = bool(_args.get("p_is_drawing", false))
			if not p_is_just_released and remote_is_drawing:
				var is_draw = ((p_is_left_click) and (remote_editor_tool != Editor.TOOL.ERASER))
				remote_tool.draw_remote(p_position, p_is_just_pressed, is_draw, remote_active_layer, remote_indexed_color_id, remote_paint_color, remote_editor_tool, remote_filter)
			elif p_is_just_released:
				# register remote stroke in history so undo works for remote ops
				$History.public_register_state(remote_active_layer, false)
		elif remote_editor_tool == Editor.TOOL.SELECTION:
			var remote_is_alt = bool(_args.get("p_is_alt", false))
			remote_selection_tool.select_remote(p_position, p_is_just_pressed, p_is_just_released, p_is_left_click, remote_active_layer, remote_is_alt)
		elif remote_editor_tool == Editor.TOOL.BUCKET:
			# remote bucket fill (single-click op): reproduce the other player's fill using
			# THEIR layer/color/bucket settings, then register a History entry so the fill is
			# undoable on this board too (symmetric with the local bucket path below).
			if p_is_just_pressed:
				var remote_bucket_state = _args.get("p_bucket_state", {})
				$ToolBucket.bucket_fill_remote(p_position, p_is_left_click, remote_active_layer, remote_indexed_color_id, remote_paint_color, remote_bucket_state)
				$History.public_register_state(remote_active_layer, false)
		return
	if p_is_pressed and not is_drawing and not p_is_just_pressed:
		return
	if p_is_just_released and not is_drawing:
		return
	if not p_is_pressed and not p_is_just_pressed and not p_is_just_released:
		return
	if p_is_just_pressed:
		is_drawing = true
	if p_is_just_released:
		is_drawing = false
	last_mouse_pos = p_position
	if editor_tool in [Editor.TOOL.ARRAY, Editor.TOOL.PENCIL, Editor.TOOL.ERASER]:
		if not p_is_just_released and is_drawing:
			self.is_busy = true
			var is_draw = ((p_is_left_click) and (editor_tool != Editor.TOOL.ERASER))
			$ToolArrayPencilEraser.draw(p_position, p_is_just_pressed, is_draw)
		else:
			self.is_busy = false
			$History.public_register_state(active_layer, false)
	elif editor_tool == Editor.TOOL.SELECTION:
		self.is_busy = true
		$ToolSelection.select(p_position, p_is_just_pressed, p_is_just_released, p_is_left_click)
	elif editor_tool == Editor.TOOL.COLOR_PICKER:
		if p_is_just_pressed:
			$ToolColorPicker.pick_color(p_position)
	elif editor_tool == Editor.TOOL.BUCKET:
		if p_is_just_pressed:
			$ToolBucket.bucket_fill(p_position, p_is_left_click)
			$History.public_register_state(active_layer, false)
