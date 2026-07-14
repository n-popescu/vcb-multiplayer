extends "res://src/gui/reusable_scripts/button_texture_event.gd"

# vcb-mp runtime port — script extension of the shared event-emitting texture button.
#
# The toolbar "paste" button uses this script. So a clicked paste mirrors to the right spot,
# we attach the current board cursor position to the ed_selection_paste event (matching the
# keyboard-shortcut path in the Shortcuts extension).


func _get_editor() -> Node:
	return get_tree().root.find_node("Editor", true, false)


func _get_board_cursor_pos() -> Vector2:
	var editor = _get_editor()
	if editor and editor.has_method("get"):
		return editor.get("last_mouse_pos")
	return Vector2.ZERO


func _on_button_pressed() -> void :
	var event_dictionary: Dictionary = E.get(event)
	args["p_is_pressed"] = pressed
	args["p_is_disabled"] = disabled
	if event == "ed_selection_paste":
		args[E.mi_mouse_input_on_board.p_position] = _get_board_cursor_pos()
	if is_twoway:
		E.ask(event_dictionary, args)
	else:
		E.echo(event_dictionary, args)
