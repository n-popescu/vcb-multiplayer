extends "res://src/world/camera.gd"

# vcb-mp runtime port — script extension of the world Camera.
#
# Adds trackpad two-finger pan + pinch-to-zoom on top of the stock mouse/keyboard camera
# controls (this shipped alongside the multiplayer mod). The gesture branches live inside
# _unhandled_input, so we override the handler in full, in the same branch order as the mod.

# PAN_SPEED scales the pan-gesture delta into world units; PINCH_SENSITIVITY converts the
# per-event magnify factor into zoom-index steps. Tunable if the feel is off on a trackpad.
const TRACKPAD_PAN_SPEED: = 2.0
const TRACKPAD_PINCH_SENSITIVITY: = 6.0

var _trackpad_pinch_accumulator: = 0.0

func _unhandled_input(event: InputEvent) -> void :
	if event is InputEventMouseMotion:
		if BetterInput.is_action_pressed_non_exclusively("ot_camera_pan_cursor"):
			target_translation -= event.relative * zoom.x
			clamp_translation_to_board()
			emit_transform(MOUSE_MOVEMENT)
	elif event is InputEventPanGesture:
		# Trackpad two-finger scroll -> pan the board (editor context only).
		if is_world_frame_context and not is_changing_mode:
			target_translation += event.delta * TRACKPAD_PAN_SPEED * zoom.x
			clamp_translation_to_board()
			emit_transform(MOUSE_MOVEMENT)
	elif event is InputEventMagnifyGesture:
		# Trackpad pinch -> zoom about the gesture point. Accumulate the per-event factor
		# and step the shared zoom index once it crosses a level, matching wheel zoom.
		if is_world_frame_context and not is_changing_mode:
			_trackpad_pinch_accumulator += (event.factor - 1.0) * TRACKPAD_PINCH_SENSITIVITY
			if abs(_trackpad_pinch_accumulator) >= 1.0:
				current_zoom_index += int(round(_trackpad_pinch_accumulator))
				_trackpad_pinch_accumulator = 0.0
				current_zoom_index = int(clamp(current_zoom_index, 0, zoom_levels.size() - 1))
				var zm = zoom_index_to_vector(current_zoom_index)
				zoom_at_point(zm, event.position)
				emit_transform(MOUSE_MOVEMENT)
	elif event is InputEventMouseButton:
		if event.is_pressed() and not event.is_echo():
			var mouse_position = event.position
			var dir: = 0
			dir += int(event.button_index == BUTTON_WHEEL_UP)
			dir -= int(event.button_index == BUTTON_WHEEL_DOWN)
			if (dir == 0) or BetterInput.is_action_pressed_non_exclusively("ot_camera_pan_cursor"):
				return
			current_zoom_index += dir
			current_zoom_index = int(clamp(current_zoom_index, 0, zoom_levels.size() - 1))
			var zm = zoom_index_to_vector(current_zoom_index)
			zoom_at_point(zm, mouse_position)
			emit_transform(MOUSE_MOVEMENT)
