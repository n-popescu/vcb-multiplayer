extends "res://src/gui/sidepanels/circuit_editor/label_mouse_position.gd"

# vcb-mp runtime port — script extension of the side-panel X/Y mouse-position readout.
#
# In multiplayer the remote player's cursor is replayed through the same mi_mouse_input_on_board
# event (mp_draw_sync tags those payloads with "p_is_remote"). This readout is the LOCAL mouse
# position, so ignore remote-applied input and keep showing our own coordinates.

func _ev_mi_mouse_input_on_board(_mode: int, _args: Dictionary) -> void :
	if _args.get("p_is_remote", false):
		return
	._ev_mi_mouse_input_on_board(_mode, _args)
