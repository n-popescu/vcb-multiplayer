extends "res://src/editor/history.gd"

# vcb-mp runtime port — script extension of the game's History (undo/redo).
#
# Adds host-authoritative shared undo/redo. In a networked session the undo/redo stacks are
# shared; to guarantee both peers apply stack ops in the SAME global order, a non-host client
# does NOT act on its local request — it defers and lets MPDrawSync route the request to the
# host, which arbitrates and fans the resulting op back out (calling perform_undo/redo on
# receipt). The host and single-player still act immediately. last_history_action lets the
# network layer know whether the op actually moved the stack (so a no-op is never broadcast).

const HA_NONE: = 0
const HA_UNDID: = 1
const HA_REDID: = 2

var last_history_action: int = HA_NONE
# Per-frame de-dupe of the LOCAL undo/redo request. A single physical Ctrl+Z / Ctrl+Y maps to
# one undo/redo; if ed_undo_request / ed_redo_request is emitted more than once in the same
# frame (e.g. under the runtime Mod Loader a vanilla and a modded input path both echo it), we
# collapse it to a single action here — the choke point where the board actually mutates. A
# genuine second press and hold-to-repeat are always more than one frame apart, so real use is
# unaffected. (MPDrawSync applies the mirror guard on the network-routing side.)
var _last_undo_request_frame: int = -1
var _last_redo_request_frame: int = -1

func _is_network_controlled_client() -> bool:
	var mpg = get_node_or_null("/root/MP")
	return mpg != null and mpg.is_connected and mpg.is_game_started and not mpg.is_host

func _ev_ed_undo_request(_mode: int, _args: Dictionary) -> void :
	last_history_action = HA_NONE
	var frame: int = Engine.get_frames_drawn()
	if frame == _last_undo_request_frame:
		return
	_last_undo_request_frame = frame
	if _is_network_controlled_client():
		return
	perform_undo()

func _ev_ed_redo_request(_mode: int, _args: Dictionary) -> void :
	last_history_action = HA_NONE
	var frame: int = Engine.get_frames_drawn()
	if frame == _last_redo_request_frame:
		return
	_last_redo_request_frame = frame
	if _is_network_controlled_client():
		return
	perform_redo()

func perform_undo() -> void :
	last_history_action = HA_NONE
	if history_stack_undo.empty():
		update_undoredo_lock_states()
		return
	else:
		_regenerate(history_stack_undo.back(), true)
		history_stack_redo.append(history_stack_undo.pop_back())
		last_history_action = HA_UNDID
	update_undoredo_lock_states()

func perform_redo() -> void :
	last_history_action = HA_NONE
	if history_stack_redo.empty():
		update_undoredo_lock_states()
		return
	else:
		_regenerate(history_stack_redo.back(), false)
		history_stack_undo.append(history_stack_redo.pop_back())
		last_history_action = HA_REDID
	update_undoredo_lock_states()
