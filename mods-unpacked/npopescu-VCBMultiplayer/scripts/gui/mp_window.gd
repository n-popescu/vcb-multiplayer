extends Popup
# mp/gui/mp_window.gd
#
# The Multiplayer *settings window*: a centered, native-styled panel (matching the stock
# dialogs) opened from the toolbar "MP" button instead of a cramped dropdown. It presents,
# in one panel:
#   • your display name,
#   • Host / Join with an address field,
#   • the shareable host address + connection status,
#   • the connected-players list,
#   • Start-session (host) and Leave.
#
# The layout is built in code and styled from the game's own Theme + a dark StyleBoxFlat
# that matches the stock dialogs (dialog_about.tscn), so it reads as a native window rather
# than a mod bolt-on. All networking goes through the MP autoload — the original
# peer-to-peer layer that runs on the stock closed engine; this file is pure UI + wiring.

# The stock game's popup helper. Added as a child of this Popup it gives us the exact same
# presentation as the built-in dialogs (e.g. Settings): the shared dimmed gray backdrop
# (BackgroundForDialogs, via the mn_popup_visibility "is_dialog" event), a scale + fade
# entrance, and keep-centered-on-resize. See src/gui/flux/flux_mod_popup.gd and
# src/gui/dialogs/background_for_dialogs.gd.
const FluxModPopupScene := preload("res://src/gui/flux/flux_mod_popup.tscn")

var mp: Node = null

# built controls
var _name_edit: LineEdit = null
var _status_label: Label = null
var _offline_box: VBoxContainer = null
var _session_box: VBoxContainer = null
var _address_edit: LineEdit = null
var _host_btn: Button = null
var _join_btn: Button = null
var _code_value: Label = null
var _roster_list: VBoxContainer = null
var _start_btn: Button = null
var _leave_btn: Button = null
var _debug_box: VBoxContainer = null
var _consistency_btn: Button = null
var _reset_history_btn: Button = null

func _ready() -> void:
	mp = get_tree().root.get_node_or_null("/root/MP")
	_build_ui()
	if mp:
		var _s1 = mp.connect("status_update", self, "_on_status_update")
		var _s2 = mp.connect("connection_failed", self, "_on_connection_failed")
		var _s3 = mp.connect("player_connected", self, "_on_player_changed")
		var _s4 = mp.connect("player_disconnected", self, "_on_player_changed")
		var _s5 = mp.connect("server_disconnected", self, "_on_server_disconnected")
		var _s6 = mp.connect("game_started", self, "_on_game_started")
		# Names arrive shortly after connect (and on rename); refresh the roster when they do.
		if mp.has_signal("roster_updated"):
			var _s7 = mp.connect("roster_updated", self, "_on_player_changed")
	# Commit the name when the field is confirmed (Enter) or loses focus, so a rename made
	# mid-session propagates to the other player too (set_player_name broadcasts when connected).
	if _name_edit:
		var _n1 = _name_edit.connect("text_entered", self, "_on_name_committed")
		var _n2 = _name_edit.connect("focus_exited", self, "_on_name_committed")
	_refresh()

# Called by BtnMP when the toolbar button is pressed.
func open_window() -> void:
	if mp and _name_edit:
		_name_edit.text = str(mp.player_name)
	_refresh()
	popup_centered()
	set_as_minsize()  # shrink to the content's min size, like the stock dialogs

# ---------------------------------------------------------------- UI construction --
func _build_ui() -> void:
	# opaque, rounded dark panel (matches the stock dialogs)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.add_stylebox_override("panel", _make_panel_style())
	add_child(panel)

	var margin := MarginContainer.new()
	# Match the stock Settings dialog's inner padding (30 / 20) so the box reads the same.
	margin.add_constant_override("margin_left", 30)
	margin.add_constant_override("margin_right", 30)
	margin.add_constant_override("margin_top", 20)
	margin.add_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_constant_override("separation", 8)
	margin.add_child(root)

	var title := Label.new()
	title.text = "Multiplayer"
	title.align = Label.ALIGN_CENTER
	root.add_child(title)
	root.add_child(HSeparator.new())

	# name row
	var name_row := HBoxContainer.new()
	name_row.add_constant_override("separation", 8)
	root.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Name"
	name_lbl.rect_min_size = Vector2(64, 0)
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.placeholder_text = "Player"
	name_row.add_child(_name_edit)

	_status_label = Label.new()
	_status_label.text = "Offline"
	_status_label.align = Label.ALIGN_CENTER
	_status_label.autowrap = true
	root.add_child(_status_label)
	root.add_child(HSeparator.new())

	# ---- offline section: host / join --------------------------------------------
	_offline_box = VBoxContainer.new()
	_offline_box.add_constant_override("separation", 6)
	root.add_child(_offline_box)

	var hostjoin := HBoxContainer.new()
	hostjoin.add_constant_override("separation", 8)
	_offline_box.add_child(hostjoin)
	_host_btn = Button.new()
	_host_btn.text = "Host"
	_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _h = _host_btn.connect("pressed", self, "_on_host_pressed")
	hostjoin.add_child(_host_btn)
	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _j = _join_btn.connect("pressed", self, "_on_join_pressed")
	hostjoin.add_child(_join_btn)

	var addr_row := HBoxContainer.new()
	addr_row.add_constant_override("separation", 8)
	_offline_box.add_child(addr_row)
	var addr_lbl := Label.new()
	addr_lbl.text = "Address"
	addr_lbl.rect_min_size = Vector2(64, 0)
	addr_row.add_child(addr_lbl)
	_address_edit = LineEdit.new()
	_address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address_edit.placeholder_text = "Host IP to join"
	addr_row.add_child(_address_edit)

	# ---- session section: code / roster / start / leave --------------------------
	_session_box = VBoxContainer.new()
	_session_box.add_constant_override("separation", 6)
	root.add_child(_session_box)

	var code_row := HBoxContainer.new()
	code_row.add_constant_override("separation", 8)
	_session_box.add_child(code_row)
	var code_lbl := Label.new()
	code_lbl.text = "Share code"
	code_lbl.rect_min_size = Vector2(72, 0)
	code_row.add_child(code_lbl)
	_code_value = Label.new()
	_code_value.text = "-"
	_code_value.mouse_filter = Control.MOUSE_FILTER_STOP
	_code_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_row.add_child(_code_value)

	var players_lbl := Label.new()
	players_lbl.text = "Players"
	_session_box.add_child(players_lbl)
	_roster_list = VBoxContainer.new()
	_roster_list.add_constant_override("separation", 4)
	_session_box.add_child(_roster_list)

	var session_buttons := HBoxContainer.new()
	session_buttons.add_constant_override("separation", 8)
	_session_box.add_child(session_buttons)
	_start_btn = Button.new()
	_start_btn.text = "Start session"
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _st = _start_btn.connect("pressed", self, "_on_start_pressed")
	session_buttons.add_child(_start_btn)
	_leave_btn = Button.new()
	_leave_btn.text = "Leave"
	_leave_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _lv = _leave_btn.connect("pressed", self, "_on_leave_pressed")
	session_buttons.add_child(_leave_btn)

	# ---- DEBUG section: manual board-sync + history recovery (in-session only) ----------
	_debug_box = VBoxContainer.new()
	_debug_box.add_constant_override("separation", 6)
	root.add_child(_debug_box)
	_debug_box.add_child(HSeparator.new())
	var debug_lbl := Label.new()
	debug_lbl.text = "DEBUG"
	debug_lbl.add_color_override("font_color", Color(0.58, 0.63, 0.71))
	_debug_box.add_child(debug_lbl)
	# Host-only: force every client to reconcile its board to the host's (tiled diff).
	_consistency_btn = Button.new()
	_consistency_btn.text = "Recheck board sync"
	_consistency_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _cc = _consistency_btn.connect("pressed", self, "_on_consistency_pressed")
	_debug_box.add_child(_consistency_btn)
	# Anyone: clear the shared undo/redo history on every peer (recover a desynced stack).
	_reset_history_btn = Button.new()
	_reset_history_btn.text = "Reset undo/redo history (everyone)"
	_reset_history_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _rh = _reset_history_btn.connect("pressed", self, "_on_reset_history_pressed")
	_debug_box.add_child(_reset_history_btn)

	root.add_child(HSeparator.new())
	var close_btn := Button.new()
	close_btn.text = "Close"
	var _cl = close_btn.connect("pressed", self, "hide")
	root.add_child(close_btn)

	rect_min_size = Vector2(360, 0)

	# Attach the shared popup helper so this window presents exactly like the stock
	# dialogs: it fades in the dimmed gray backdrop (BackgroundForDialogs) behind the
	# centered box, animates a scale + fade entrance, and keeps the box centered when
	# the window is resized.
	var flux := FluxModPopupScene.instance()
	flux.is_keep_centered_on_resize = true
	add_child(flux)

func _make_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0745098, 0.0941176, 0.12549, 1)
	sb.border_color = Color(0.164706, 0.207843, 0.254902, 1)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.corner_detail = 5
	sb.shadow_color = Color(0.054902, 0.0745098, 0.117647, 0.156863)
	sb.shadow_size = 16
	# Godot 3.5 has no set_content_margin_all(); set each side's default (content) margin.
	sb.set_default_margin(MARGIN_LEFT, 4)
	sb.set_default_margin(MARGIN_TOP, 4)
	sb.set_default_margin(MARGIN_RIGHT, 4)
	sb.set_default_margin(MARGIN_BOTTOM, 4)
	return sb

# ------------------------------------------------------------------- UI refresh ---
func _refresh() -> void:
	var connected: bool = mp != null and (mp.is_connected or mp.is_host)
	if _offline_box:
		_offline_box.visible = not connected
	if _session_box:
		_session_box.visible = connected
	if _code_value and mp:
		_code_value.text = str(mp.upnp_external_ip) if str(mp.upnp_external_ip) != "" else "-"
	if _start_btn and mp:
		# Only the host can start the session, and only once the other player is present.
		_start_btn.visible = mp.is_host
		_start_btn.disabled = mp.connected_players.size() < 2
	if _debug_box and mp:
		# DEBUG tools only make sense in a live session; the board-sync recheck is host-only.
		_debug_box.visible = connected
		if _consistency_btn:
			_consistency_btn.visible = mp.is_host
	_rebuild_roster()

func _rebuild_roster() -> void:
	if not _roster_list:
		return
	for child in _roster_list.get_children():
		child.queue_free()
	if not mp:
		return
	var my_id: int = int(mp.my_id)
	for pid_any in mp.connected_players:
		var pid: int = int(pid_any)
		var row := HBoxContainer.new()
		row.add_constant_override("separation", 6)
		var lbl := Label.new()
		# Peer-to-peer has no roles/roster server: id 1 is always the host, and the local
		# peer is tagged "(you)".
		var tags := ""
		if pid == 1:
			tags += "  (host)"
		if pid == my_id:
			tags += "  (you)"
		var pname := ("Player %d" % pid)
		if mp.has_method("get_player_name"):
			pname = str(mp.get_player_name(pid))
		lbl.text = "%s%s" % [pname, tags]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		_roster_list.add_child(row)

func _commit_name() -> void:
	if mp and _name_edit and mp.has_method("set_player_name"):
		mp.set_player_name(_name_edit.text)

# text_entered passes the text; focus_exited passes nothing — accept either.
func _on_name_committed(_arg = null) -> void:
	_commit_name()

# ------------------------------------------------------------------- UI handlers ---
func _on_host_pressed() -> void:
	if not mp:
		return
	_commit_name()
	_host_btn.disabled = true
	_join_btn.disabled = true
	if mp.host_game():
		_refresh()
	else:
		_host_btn.disabled = false
		_join_btn.disabled = false

func _on_join_pressed() -> void:
	if not mp:
		return
	var addr: String = _address_edit.text.strip_edges()
	if addr == "":
		_set_status("Enter a host address")
		return
	_commit_name()
	_host_btn.disabled = true
	_join_btn.disabled = true
	# join_game() yields internally, so it hands back a coroutine state rather than a
	# bool; success/failure surfaces through the status_update / connection_failed /
	# player_connected signals, which drive _refresh().
	mp.join_game(addr)

func _on_start_pressed() -> void:
	if mp and mp.is_host:
		mp.start_game()

func _on_leave_pressed() -> void:
	if mp:
		mp.leave_game()
	_host_btn.disabled = false
	_join_btn.disabled = false
	_set_status("Offline")
	_refresh()

# DEBUG: host pushes its authoritative board digest so clients reconcile any differing tiles.
func _on_consistency_pressed() -> void:
	var sync = get_tree().root.get_node_or_null("/root/MPDrawSync")
	if sync and sync.has_method("host_run_consistency_check"):
		sync.host_run_consistency_check()
		_set_status("Board sync check sent to clients")

# DEBUG: clear the shared undo/redo history on every peer (recover a desynced stack).
func _on_reset_history_pressed() -> void:
	var sync = get_tree().root.get_node_or_null("/root/MPDrawSync")
	if sync and sync.has_method("reset_shared_history"):
		sync.reset_shared_history()
		_set_status("Undo/redo history reset for everyone")

# ------------------------------------------------------------------- MP signals ---
func _on_status_update(text: String) -> void:
	_set_status(text)

func _on_connection_failed(error: String) -> void:
	_set_status("Error: " + str(error))
	_host_btn.disabled = false
	_join_btn.disabled = false
	_refresh()

func _on_player_changed(_id: int) -> void:
	_refresh()

func _on_server_disconnected() -> void:
	_set_status("Disconnected")
	_host_btn.disabled = false
	_join_btn.disabled = false
	_refresh()

func _on_game_started() -> void:
	_set_status("Session started")
	hide()

func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = str(text)
