extends "res://src/gui/scripts/simulation_controls.gd"

# vcb-mp runtime port — script extension of SimulationControls.
#
# Echo guard: when the sliders extension applies a REMOTE speed to the spinbox, the spinbox's
# value_changed fires and would re-broadcast sm_speed_change, looping between peers. The
# sliders extension sets an "applying_remote_speed" meta around that programmatic update; we
# skip the broadcast while it's set.

func _on_spinbox_value_changed(new_value: int) -> void :
	if has_meta("applying_remote_speed") and get_meta("applying_remote_speed"):
		return
	var exp_speed: = linear_simspeed_to_exponetial(float(new_value))
	E.echo(E.sm_speed_change, {
		E.sm_speed_change.p_speed: exp_speed, })
