extends "res://src/gui/sidepanels/circuit_editor/mouse_over_label.gd"

# vcb-mp runtime port — script extension of the side-panel "ink under cursor" readout.
#
# Local readout only: ignore the remote player's cursor, which is replayed through the same
# mi_mouse_input_on_board event in multiplayer (tagged "p_is_remote" by mp_draw_sync).

func _ev_mi_mouse_input_on_board(_mode: int, _args: Dictionary) -> void :
	if _args.get("p_is_remote", false):
		return
	._ev_mi_mouse_input_on_board(_mode, _args)
