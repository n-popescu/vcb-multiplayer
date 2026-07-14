extends "res://src/main/simulator.gd"

# vcb-mp runtime port — script extension of the Simulator.
#
# Adds the MP tick-alignment entry point mp_advance_ticks(), matching the vcb-mp src edit. It lets
# a client fast-forward its engine to the host's authoritative paused tick so both boards show the
# same tick when paused / stepping. Forward-only (a free-running engine keeps no snapshots to
# rewind) and bounded so a large drift can't freeze the game. Called from MPDrawSync
# (_rpc_align_tick), which computes the count from the host's reported tick minus our last-seen one.

const MP_MAX_CATCHUP_TICKS: = 2000000

# MP: per-sender last PRESS position for press-and-hold mode. The momentary release must clear the
# latch the press set, at the press position (the pointer may have moved since), keyed by sender.
var _mp_remote_override_pos: = {}

func mp_advance_ticks(p_ticks: int) -> void :
	if not is_run or not is_engine_ready or TE == null:
		return
	if is_continue:
		return
	if p_ticks <= 0:
		return
	if p_ticks > MP_MAX_CATCHUP_TICKS:
		p_ticks = MP_MAX_CATCHUP_TICKS
	var _result: = TE.solve(p_ticks, [], vinput_value, vmem_range, 0)
	process_state_texture(TE.get_texture())
	E.echo(E.vd_vmem_editor_section_update, {
		E.vd_vmem_editor_section_update.p_section: TE.get_vmem_section(), })
	if is_process_vdisplay:
		E.echo(E.vd_vdisplay_texture_render, {
			E.vd_vdisplay_texture_render.p_texture: TE.get_vdisplay_texture(), })

func apply_remote_sim_click(p_sender_id: int, p_position: Vector2, p_is_just_pressed: bool, p_is_just_released: bool, p_is_toggle_mode: bool) -> void :
	# MP: apply another player's in-simulation board click (a "mouse override" that toggles / presses a
	# latch in the live circuit) using the SENDER's interaction mode, not ours. VCB's toggle vs
	# press-and-hold mode is a per-player preference, so a toggle-mode player's click toggles here and a
	# press-mode player's press/release forces the latch on/off here, whatever THIS peer's own mode is.
	# Both boards end up with the same override_set, so the deterministic engines stay in lockstep.
	# Called from MPDrawSync (_rpc_apply_sim_click); guarded to the live, running sim and to clicks
	# inside the circuit, mirroring the local _ev_mi_mouse_input_on_board path.
	if not is_run or not is_engine_ready or TE == null:
		return
	if not C.CIRCUIT.RECT.has_point(p_position):
		return
	var saved_mode: bool = is_override_toggle_mode
	is_override_toggle_mode = p_is_toggle_mode
	if p_is_toggle_mode:
		if p_is_just_pressed:
			set_mouse_override(p_position, true)
	else:
		if p_is_just_pressed:
			set_mouse_override(p_position, true)
			_mp_remote_override_pos[p_sender_id] = p_position
		elif p_is_just_released:
			var press_pos: Vector2 = _mp_remote_override_pos.get(p_sender_id, p_position)
			set_mouse_override(press_pos, false)
	is_override_toggle_mode = saved_mode
