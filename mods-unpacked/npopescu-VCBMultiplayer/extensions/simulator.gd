extends "res://src/main/simulator.gd"

# vcb-mp runtime port — script extension of the Simulator.
#
# Adds the MP tick-alignment entry point mp_advance_ticks(), matching the vcb-mp src edit. It lets
# a client fast-forward its engine to the host's authoritative paused tick so both boards show the
# same tick when paused / stepping. Forward-only (a free-running engine keeps no snapshots to
# rewind) and bounded so a large drift can't freeze the game. Called from MPDrawSync
# (_rpc_align_tick), which computes the count from the host's reported tick minus our last-seen one.

const MP_MAX_CATCHUP_TICKS: = 2000000

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
