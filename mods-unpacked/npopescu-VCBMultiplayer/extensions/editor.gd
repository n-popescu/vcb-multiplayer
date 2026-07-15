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


# MP fix — editor->sim->editor "can't click": guarantee board drawing is re-enabled whenever we
# return to the editor. Toggling in and out of simulation (Tab) could leave the game's `is_focused`
# stuck false: clicks/draws are silently dropped while the hover cursor still tracks the mouse,
# because update_cursor() runs BEFORE the `if not is_in_editor or not is_focused: return` guard in
# _ev_mi_mouse_input_on_board. `is_focused` is only set true again by a popup closing
# (mn_popup_visibility = false), which is exactly why opening and dismissing the quit dialog "fixes"
# it by hand. Whenever we are confirmed back in edit mode no popup can be capturing input, so board
# input must be focused — force it here so no manual popup dance is needed.
func _on_mi_mode_change_requested(is_simulation_requested: bool) -> void :
	._on_mi_mode_change_requested(is_simulation_requested)
	if not is_simulation_requested:
		is_focused = true


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
		if remote_editor_tool in [Editor.TOOL.ARRAY, Editor.TOOL.PENCIL, Editor.TOOL.ERASER]:
			remote_tool.apply_brush_state(remote_brush_state, remote_editor_tool)
			var remote_is_drawing = bool(_args.get("p_is_drawing", false))
			if not p_is_just_released and remote_is_drawing:
				var is_draw = ((p_is_left_click) and (remote_editor_tool != Editor.TOOL.ERASER))
				remote_tool.draw_remote(p_position, p_is_just_pressed, is_draw, remote_active_layer, remote_indexed_color_id, remote_paint_color, remote_editor_tool)
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
