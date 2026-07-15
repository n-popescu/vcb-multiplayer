extends "res://src/main/input_blocker.gd"

# MP/ModLoader fix — editor<->sim Tab lock-up. Under the runtime Mod Loader a vanilla and a modded
# input path both echo mi_mode_change_requested in the SAME frame (the same double-emit History
# de-dupes). Two overlapping copies of the vanilla _on_mi_mode_change_requested then race the single
# is_confirmed handshake: the first clears it, the second sees it cleared and latches
# is_consume_input = true with no mi_mode_change_confirmed left to release it, so InputBlocker keeps
# consuming ALL input after a Tab in/out of simulation (clicks/draws AND the toolbar stop
# responding, while the cursor sprite still tracks in _process — which is why it looks like "hover
# still works"). This override fully REPLACES the vanilla handler (the fragile part) with a per-frame
# de-dupe so at most one request is processed per frame — the same fix applied inline in the .pck
# build's src/main/input_blocker.gd. A real second toggle is always more than one frame apart.

var _last_request_frame: int = -1


func _on_mi_mode_change_requested(_is_simulation_requested) -> void:
	var frame: int = Engine.get_frames_drawn()
	if frame == _last_request_frame:
		return
	_last_request_frame = frame
	show()
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	if not is_confirmed:
		is_consume_input = true
	else:
		is_confirmed = false
