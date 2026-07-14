extends "res://src/gui/scripts/simulation_sliders.gd"

# vcb-mp runtime port — script extension of the simulation speed slider.
#
# Mirrors the other player's speed slider/spinbox so both peers see the same slider position
# for the same simulation speed. While the local user is dragging the slider we defer remote
# values (so it doesn't snap out from under them), applying the latest one on release. An
# echo guard prevents a programmatic remote apply from re-broadcasting.

var _is_applying_remote_speed: bool = false
var _is_local_dragging: bool = false
var _last_remote_speed: float = -1.0  # sentinel; real values are 0..1

func _ready():
	L.sig = $Target.connect("value_changed", self, "_on_value_changed")
	# Subscribe to the speed-change event so we can mirror remote changes
	# (and also the spinbox's changes, which go through the same event).
	# NOTE: follow_events() returns void, so it must NOT be assigned to L.sig
	# (L.sig's setter is typed int; assigning null throws "Invalid set index 'sig'").
	E.follow_events(self, [E.sm_speed_change])
	# Publish our initial value so the sim and the remote start in sync.
	E.echo(E.sm_speed_change, {
		E.sm_speed_change.p_speed: $Target.value, })

func _input(event: InputEvent) -> void :
	# Track left-button state globally so we know when the user is
	# mid-drag even if the mouse leaves the slider bounds.
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			# Only lock if the press started on the slider.
			if _is_mouse_over($Target):
				_is_local_dragging = true
		else:
			if _is_local_dragging:
				_is_local_dragging = false
				_apply_pending_remote_speed()

func _is_mouse_over(control: Control) -> bool :
	if not control or not control.visible:
		return false
	# Control nodes don't have get_global_mouse_position() (that's a Node2D method).
	# Use the viewport's mouse position and the control's global rect instead.
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	return control.get_global_rect().has_point(mouse_pos)

func _on_value_changed(new_value: float) -> void :
	if _is_applying_remote_speed:
		return
	# The local user moved the slider — broadcast.
	E.echo(E.sm_speed_change, {
		E.sm_speed_change.p_speed: new_value, })

# Event-bus handler. Called for both local-origin E.echo and remote replays
# (mp_draw_sync uses E.emit_signal(event_name, E.ECHO, payload) on receive).
func _ev_sm_speed_change(_mode: int, _args: Dictionary) -> void :
	var p_speed: float = _args[E.sm_speed_change.p_speed]
	# If the local user is mid-drag, remember the value but don't snap the slider.
	if _is_local_dragging:
		_last_remote_speed = p_speed
		return
	_apply_remote_speed_to_ui(p_speed)

func _apply_remote_speed_to_ui(p_speed: float) -> void :
	_is_applying_remote_speed = true
	$Target.value = p_speed
	# Also update the spinbox so it's in sync when the user toggles to it.
	var spin_box = get_node_or_null("../SpinBoxSpeed")
	if spin_box:
		# Set the echo-guard meta so simulation_controls._on_spinbox_value_changed
		# doesn't re-broadcast this programmatic update.
		var sim_controls = get_node_or_null("..")
		if sim_controls:
			sim_controls.set_meta("applying_remote_speed", true)
		var linear: float = pow(3.0, 14.0 * p_speed - 14.0) * 5000000.0
		spin_box.public_set_float_value(linear)
		if sim_controls:
			sim_controls.set_meta("applying_remote_speed", false)
	_is_applying_remote_speed = false
	_last_remote_speed = -1.0

func _apply_pending_remote_speed() -> void :
	if _last_remote_speed >= 0.0:
		_apply_remote_speed_to_ui(_last_remote_speed)
