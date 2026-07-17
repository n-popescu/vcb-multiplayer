extends "res://src/editor/shortcuts.gd"

# vcb-mp runtime port — script extension of the game's Shortcuts.
#
# One keyboard shortcut needs to be MP-aware, and it lives inside _unhandled_input, so we override
# the whole handler (GDScript can't patch mid-function) and reproduce it verbatim with exactly the
# one mod edit the whole-pck build makes:
#   • "mi_switch_modes" routes the run/pause toggle through MP.request_mode_change so the two peers
#     switch together.
#
# NOTE: "paste" is deliberately left byte-identical to vanilla (E.echo(E.ed_selection_paste, {})).
# An earlier build injected Editor.last_mouse_pos into the paste event; that overwrote
# ToolSelection's live-tracked mouse_pos_on_board with a value that only updates on board CLICKS
# (not hover), so Ctrl+V pasted off-board and the next paste stamped the stray selection onto the
# board (the "Ctrl+V pastes on the board AND floats a box" bug). Vanilla already tracks the cursor
# for the local paste position, and the remote paste position rides the selection-area RPC, so no
# injection is needed.
#
# The Ctrl+Z / Ctrl+Y double-fire de-dupe lives at the consumption layer (History and
# MPDrawSync), not here, so both this override and the vanilla input paths collapse to one
# undo/redo per frame regardless of how many times the request is emitted.


# Runtime Mod Loader double-input guard. Under the Mod Loader the same input event is dispatched to
# _unhandled_input twice in one frame (a vanilla and a modded path both deliver it — the same
# double-emit History/MPDrawSync de-dupe downstream). That doubles every keyboard shortcut below:
# double undo/redo/paste/delete/step, and _tw toggles (sidebars, auto-cross) that flip twice and
# cancel themselves out. Collapse an exact-duplicate KEY event within a single frame to its first
# occurrence. Only key events are guarded — mouse/wheel pass through so fast wheel-scroll (ink
# change) keeps every notch — and distinct keys / later frames are never touched, so no real input
# is dropped. Fixes the whole class at the source, including any shortcut added here later.
var _input_dedup_frame: int = -1
var _input_dedup_seen: Dictionary = {}


func _is_duplicate_mod_input(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var frame: int = Engine.get_frames_drawn()
	if frame != _input_dedup_frame:
		_input_dedup_frame = frame
		_input_dedup_seen = {}
	var sig: String = "%d.%d.%d.%d.%d.%d" % [event.scancode, int(event.pressed), int(event.control), int(event.shift), int(event.alt), int(event.meta)]
	if _input_dedup_seen.has(sig):
		return true
	_input_dedup_seen[sig] = true
	return false


func _unhandled_input(event: InputEvent) -> void :
	if _is_duplicate_mod_input(event):
		return
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
			E.echo(E.ed_selection_paste, {})
