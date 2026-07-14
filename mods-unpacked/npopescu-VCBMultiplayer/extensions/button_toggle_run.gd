extends "res://src/gui/scripts/button_toggle_run.gd"

# vcb-mp runtime port — script extension of the toolbar Run/Pause button.
#
# Route the run/pause toggle through MP.request_mode_change when connected, so both peers
# switch simulation mode together (falls back to the plain signal in single-player).

func _on_button_pressed() -> void :
	var mp = get_tree().root.get_node_or_null("/root/MP")
	if mp and mp.has_method("request_mode_change"):
		mp.request_mode_change(not is_mode_sim)
	else:
		E.emit_signal("mi_mode_change_requested", not is_mode_sim)
