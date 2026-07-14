extends "res://src/editor/shortcuts.gd"

# vcb-mp runtime port — script extension of the game's Shortcuts.
#
# Two keyboard shortcuts need to be MP-aware, and both live inside _unhandled_input, so we
# override the whole handler (GDScript can't patch mid-function) and reproduce it verbatim
# with exactly the two mod edits the whole-pck build made:
#   • "mi_switch_modes" routes the run/pause toggle through MP.request_mode_change so the
#     two peers switch together;
#   • "paste" carries the board cursor position so a remote paste lands where you pasted.
#
# The Ctrl+Z / Ctrl+Y double-fire de-dupe lives at the consumption layer (History and
# MPDrawSync), not here, so both this override and the vanilla input paths collapse to one
# undo/redo per frame regardless of how many times the request is emitted.


func _get_editor() -> Node:
	return get_tree().root.find_node("Editor", true, false)


func _get_editor_last_mouse_pos() -> Vector2:
	var editor = _get_editor()
	if editor and editor.has_method("get"):
		return editor.get("last_mouse_pos")
	return Vector2.ZERO


func _unhandled_input(event: InputEvent) -> void :
	if false:
		pass
	elif BetterInput.is_input_event_action_just_pressed(event, "ui_toggle_left_sidebar"):
		E.ask(E.ui_sidebar_left_toggle_tw, {})
	elif BetterInput.is_input_event_action_just_pressed(event, "ui_toggle_right_sidebar"):
		E.ask(E.ui_sidebar_right_toggle_tw, {})
	elif BetterInput.is_input_event_action_just_pressed(event, "fs_new_project"):
		E.echo(E.fs_new_file_request, {})
	elif BetterInput.is_input_event_action_just_pressed(event, "fs_open_project"):
		E.echo(E.fs_open_file_request, {})
	elif BetterInput.is_input_event_action_just_pressed(event, "fs_save_project"):
		E.echo(E.fs_direct_save_file_request, {})
	elif BetterInput.is_input_event_action_just_pressed(event, "mi_switch_modes")\
	and is_assembly_valid\
	and is_vmem_ready:
		var mp = get_tree().root.get_node_or_null("/root/MP")
		if mp and mp.has_method("request_mode_change"):
			mp.request_mode_change(not is_simulating)
		else:
			E.emit_signal("mi_mode_change_requested", not is_simulating)
	if is_simulating:
		if BetterInput.is_input_event_action_just_pressed(event, "sm_prev_update"):
			E.echo(E.sm_prev_step_request, {})
			start_stepmode_hold(true)
		if BetterInput.is_input_event_action_just_pressed(event, "sm_next_update"):
			E.echo(E.sm_next_step_request, {})
			start_stepmode_hold(false)
		elif BetterInput.is_input_event_action_released(event, "sm_prev_update"):
			stepmode_is_hold = false
		elif BetterInput.is_input_event_action_released(event, "sm_next_update"):
			stepmode_is_hold = false
	else:
		if false:
			pass
		elif (event is InputEventMouseButton and event.button_index == BUTTON_WHEEL_DOWN and 
					event.is_pressed() and BetterInput.is_key_pressed(KEY_CONTROL) and 
					BetterInput.is_key_pressed(KEY_SHIFT)):
			get_tree().set_input_as_handled()
			E.echo(E.ed_prev_next_ink_variant_change, {
				E.ed_prev_next_ink_variant_change.p_is_next: true, })
		elif (event is InputEventMouseButton and event.button_index == BUTTON_WHEEL_UP and 
					event.is_pressed() and BetterInput.is_key_pressed(KEY_CONTROL) and 
					BetterInput.is_key_pressed(KEY_SHIFT)):
			get_tree().set_input_as_handled()
			E.echo(E.ed_prev_next_ink_variant_change, {
				E.ed_prev_next_ink_variant_change.p_is_next: false, })
		elif (event is InputEventMouseButton and event.button_index == BUTTON_WHEEL_DOWN and 
					event.is_pressed() and BetterInput.is_key_pressed(KEY_CONTROL)):
			get_tree().set_input_as_handled()
			E.echo(E.ed_prev_next_ink_change, {
				E.ed_prev_next_ink_change.p_is_next: true, })
		elif (event is InputEventMouseButton and event.button_index == BUTTON_WHEEL_UP and 
					event.is_pressed() and BetterInput.is_key_pressed(KEY_CONTROL)):
			get_tree().set_input_as_handled()
			E.echo(E.ed_prev_next_ink_change, {
				E.ed_prev_next_ink_change.p_is_next: false, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_write"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.ARRAY)
			E.echo(E.ed_indexed_color_pick, {
				E.ed_indexed_color_pick.p_indexed_color_id: C.PALETTE.WRITE.ID, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_trace"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.ARRAY)
			E.echo(E.ed_indexed_color_pick, {
				E.ed_indexed_color_pick.p_indexed_color_id: last_trace_id, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_cross"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.ARRAY)
			E.echo(E.ed_indexed_color_pick, {
				E.ed_indexed_color_pick.p_indexed_color_id: C.PALETTE.CROSS.ID, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_read"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.ARRAY)
			E.echo(E.ed_indexed_color_pick, {
				E.ed_indexed_color_pick.p_indexed_color_id: C.PALETTE.READ.ID, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_tool_array"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.ARRAY)
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_tool_pencil"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.PENCIL)
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_tool_eraser"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.ERASER)
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_tool_selection"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.SELECTION)
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_tool_bucket"):
			E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.BUCKET)
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_undo"):
			E.echo(E.ed_undo_request, {})
			start_history_hold(true)
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_redo"):
			E.echo(E.ed_redo_request, {})
			start_history_hold(false)
		elif BetterInput.is_input_event_action_released(event, "ed_undo"):
			history_is_hold = false
		elif BetterInput.is_input_event_action_released(event, "ed_redo"):
			history_is_hold = false
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_toggle_autocross"):
			E.ask(E.ed_array_autocross_toggle_tw, {})
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_rotate_left"):
			E.ask(E.ed_array_angle_change_tw, {
				E.ed_array_angle_change_tw.p_is_left: true, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_array_rotate_right"):
			E.ask(E.ed_array_angle_change_tw, {
				E.ed_array_angle_change_tw.p_is_left: false, })
		elif BetterInput.is_input_event_action_just_pressed(event, "ed_selection_rotate_right"):
			E.echo(E.ed_selection_rotate_r, {})
		elif BetterInput.is_input_event_action_just_pressed(event, "delete"):
			E.echo(E.ed_selection_delete, {})
		elif BetterInput.is_input_event_action_just_pressed(event, "apply"):
			E.echo(E.ed_selection_apply, {})
		elif BetterInput.is_input_event_action_just_pressed(event, "copy"):
			E.echo(E.ed_selection_copy, {})
		elif BetterInput.is_input_event_action_just_pressed(event, "paste"):
			E.echo(E.ed_selection_paste, {
				E.mi_mouse_input_on_board.p_position: _get_editor_last_mouse_pos(),
			})
