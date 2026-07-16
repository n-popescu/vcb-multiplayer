extends PanelContainer

# MP Players panel — a small roster injected into the circuit-editor side panel, at the TOP of its
# root VBoxContainer (above the "Layers" card, next to the always-visible "Cursor Info" card). Being
# a direct child of that root VBox — which circuit_editor.gd's update_visibility() never hides — it
# stays visible in BOTH edit and simulation modes, "on top" of the panel.
#
# It lists every OTHER connected player (never ourselves — our own cursor/ink already show in the
# Cursor Info card). Each entry shows:
#   • a colour square in that player's hover colour,
#   • their name, tinted that same colour (only the name is coloured, for now),
#   • their cursor position, laid out like the Cursor Info "Position" readout (X / Y),
#   • the ink their cursor is hovering, as a coloured pill (like the "Hovered Ink" readout).
#
# Data (all polled / optional, so this is inert when MP is absent):
#   • MP (/root/MP)               — roster (connected_players), names, hover colours.
#   • MPDrawSync (/root/MPDrawSync) — per-peer remote cursor board positions.
#   • the LOGIC layer image (E.ed_layers_resources_change / the Editor's own images) — read locally
#     to resolve the ink under a peer's cursor. The board is a shared, byte-identical document, so
#     reading our own copy at their cursor matches what that peer sees.

var _mp = null
var _draw_sync = null
var _layer_logic: Image = null
var _color_map := {}          # ink EDITOR hex -> ink NAME (same mapping the Cursor Info readout uses)
var _rows := {}               # peer id -> { root, swatch, name, x, y, pill, pill_sb }
var _known_ids := []          # peer ids currently shown, in order (to detect roster changes)
var _list: VBoxContainer = null
var _refresh_accum := 0.0

const _REFRESH_INTERVAL := 0.05   # seconds between position/ink readouts (~20 Hz)
const _DARK_FONT := Color(0.0745098, 0.0941176, 0.12549, 1)  # Cursor Info pill font colour
const _NAMED_INK_BG := Color("3a4551")  # bg the vanilla readout uses for a matched ink


func _ready() -> void:
	name = "MPPlayersPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_adopt_panel_style()
	_build_ui()
	_build_color_map()
	_resolve_singletons()
	_seed_layer_logic()
	# Track the current LOGIC layer the same way the Cursor Info "Hovered Ink" readout does.
	E.follow_events(self, [E.ed_layers_resources_change])
	visible = false
	set_process(true)


# Match the neighbouring "Cursor Info" card's panel look by reusing its panel stylebox.
func _adopt_panel_style() -> void:
	var parent = get_parent()
	if parent == null:
		return
	var hovered = parent.get_node_or_null("HoveredInk")
	if hovered != null:
		var sb = hovered.get_stylebox("panel")
		if sb != null:
			add_stylebox_override("panel", sb)


func _build_ui() -> void:
	var vb = VBoxContainer.new()
	vb.add_constant_override("separation", 4)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(vb)

	var header = Label.new()
	header.text = "Players"
	# Mirror the "Cursor Info" header's theme/font if we can find it, so the section title matches.
	var parent = get_parent()
	if parent != null:
		var cursor_header = parent.get_node_or_null("HoveredInk/VBoxContainer2/Label3")
		if cursor_header != null and cursor_header.theme != null:
			header.theme = cursor_header.theme
	vb.add_child(header)

	_list = VBoxContainer.new()
	_list.add_constant_override("separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_list)


# ink EDITOR hex -> NAME, exactly like mouse_over_label.gd builds it.
func _build_color_map() -> void:
	if typeof(C.PALETTE) != TYPE_DICTIONARY:
		return
	for i in C.PALETTE:
		_color_map[C.PALETTE[i].EDITOR] = String(C.PALETTE[i].NAME)


func _resolve_singletons() -> void:
	if _mp == null:
		_mp = get_node_or_null("/root/MP")
	if _draw_sync == null:
		_draw_sync = get_node_or_null("/root/MPDrawSync")


# Seed the LOGIC layer from the Editor now, in case ed_layers_resources_change already fired before
# we were built (it fires on file load / undo / draw, which may predate this panel).
func _seed_layer_logic() -> void:
	var editor = get_node_or_null("/root/Main/Systems/Editor")
	if editor == null:
		var main = get_node_or_null("/root/Main")
		if main != null:
			editor = main.find_node("Editor", true, false)
	if editor == null:
		return
	var imgs = editor.get("images")
	if typeof(imgs) == TYPE_ARRAY and imgs.size() > Editor.LAYER.LOGIC:
		var img = imgs[Editor.LAYER.LOGIC]
		if img is Image:
			_layer_logic = img


func _ev_ed_layers_resources_change(_mode: int, args: Dictionary) -> void:
	var layers = args.get(E.ed_layers_resources_change.p_layers, null)
	if typeof(layers) == TYPE_ARRAY and layers.size() > Editor.LAYER.LOGIC:
		var img = layers[Editor.LAYER.LOGIC]
		if img is Image:
			_layer_logic = img


func _process(delta: float) -> void:
	_resolve_singletons()
	if _mp == null or not _bool(_mp.get("is_connected")):
		if visible:
			visible = false
		return
	var others = _other_ids()
	if others.empty():
		if visible:
			visible = false
		return
	visible = true
	if others != _known_ids:
		_rebuild_rows(others)
	_refresh_accum += delta
	if _refresh_accum < _REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	for pid in _known_ids:
		_update_row(int(pid))


# The connected peers other than ourselves (sorted, stable order).
func _other_ids() -> Array:
	var ids = []
	if _mp == null:
		return ids
	var mine = int(_mp.get("my_id"))
	var cp = _mp.get("connected_players")
	if typeof(cp) == TYPE_ARRAY:
		for a in cp:
			var pid = int(a)
			if pid != mine and not ids.has(pid):
				ids.append(pid)
	ids.sort()
	return ids


func _rebuild_rows(ids: Array) -> void:
	for child in _list.get_children():
		child.queue_free()
	_rows.clear()
	for pid_any in ids:
		var pid = int(pid_any)
		_rows[pid] = _make_row()
		_list.add_child(_rows[pid].root)
	_known_ids = ids.duplicate()


# Build one player's block: [swatch + name] / [Position X __ Y __] / [Hovered Ink pill].
func _make_row() -> Dictionary:
	var root = VBoxContainer.new()
	root.add_constant_override("separation", 2)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Line 1: colour square + name.
	var name_row = HBoxContainer.new()
	name_row.add_constant_override("separation", 6)
	var swatch = ColorRect.new()
	swatch.rect_min_size = Vector2(14, 14)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(swatch)
	var name_lbl = Label.new()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_lbl)
	root.add_child(name_row)

	# Line 2: cursor position, laid out like the Cursor Info "Position" readout.
	var pos_row = HBoxContainer.new()
	var pos_lbl = Label.new()
	pos_lbl.text = "Position "
	pos_row.add_child(pos_lbl)
	var x_tag = Label.new()
	x_tag.text = "X"
	pos_row.add_child(x_tag)
	var x_val = Label.new()
	x_val.rect_min_size = Vector2(50, 0)
	x_val.align = Label.ALIGN_CENTER
	x_val.text = "-"
	pos_row.add_child(x_val)
	var vsep = VSeparator.new()
	pos_row.add_child(vsep)
	var y_tag = Label.new()
	y_tag.text = "Y"
	pos_row.add_child(y_tag)
	var y_val = Label.new()
	y_val.rect_min_size = Vector2(50, 0)
	y_val.align = Label.ALIGN_CENTER
	y_val.text = "-"
	pos_row.add_child(y_val)
	root.add_child(pos_row)

	# Line 3: hovered-ink pill.
	var ink_row = HBoxContainer.new()
	ink_row.add_constant_override("separation", 6)
	var ink_tag = Label.new()
	ink_tag.text = "Hovered Ink "
	ink_row.add_child(ink_tag)
	var pill = Label.new()
	pill.rect_min_size = Vector2(120, 22)
	pill.align = Label.ALIGN_CENTER
	pill.valign = Label.VALIGN_CENTER
	pill.add_color_override("font_color", _DARK_FONT)
	var pill_sb = StyleBoxFlat.new()
	pill_sb.bg_color = Color(0, 0, 0, 0)
	pill_sb.content_margin_left = 6
	pill_sb.content_margin_right = 6
	pill_sb.content_margin_top = 2
	pill_sb.content_margin_bottom = 2
	pill_sb.corner_radius_top_left = 2
	pill_sb.corner_radius_top_right = 2
	pill_sb.corner_radius_bottom_left = 2
	pill_sb.corner_radius_bottom_right = 2
	pill.add_stylebox_override("normal", pill_sb)
	pill.text = "None"
	ink_row.add_child(pill)
	root.add_child(ink_row)

	return {
		"root": root,
		"swatch": swatch,
		"name": name_lbl,
		"x": x_val,
		"y": y_val,
		"pill": pill,
		"pill_sb": pill_sb,
	}


func _update_row(pid: int) -> void:
	if not _rows.has(pid):
		return
	var row = _rows[pid]
	var col = _player_color(pid)
	# Colour square + name (only the name is tinted, per spec).
	row.swatch.color = col
	row.name.text = _player_name(pid)
	row.name.add_color_override("font_color", col)

	# Cursor position (board coords), same integer readout as the Cursor Info card.
	var pos = _cursor_pos(pid)
	if pos == null:
		row.x.text = "-"
		row.y.text = "-"
	else:
		row.x.text = str(int(pos.x))
		row.y.text = str(int(pos.y))

	# Hovered ink under their cursor, read from our (identical) LOGIC layer.
	_update_pill(row, pos)


func _update_pill(row: Dictionary, pos) -> void:
	var pill = row.pill
	var sb = row.pill_sb
	if pos == null or _layer_logic == null or not C.CIRCUIT.RECT.has_point(pos):
		pill.text = "None"
		sb.bg_color = Color(0, 0, 0, 0)
		return
	_layer_logic.lock()
	var px = _layer_logic.get_pixelv(pos)
	_layer_logic.unlock()
	var html_a = px.to_html(true)
	var html = px.to_html(false)
	if _color_map.has(html_a):
		pill.text = str(_color_map[html_a])
		sb.bg_color = _NAMED_INK_BG
	elif _color_map.has(html):
		pill.text = str(_color_map[html])
		sb.bg_color = px
	else:
		pill.text = "#" + html
		sb.bg_color = px


func _cursor_pos(pid: int):
	if _draw_sync == null:
		return null
	var positions = _draw_sync.get("remote_cursor_positions")
	if typeof(positions) == TYPE_DICTIONARY and positions.has(pid):
		return positions[pid]
	return null


func _player_color(pid: int) -> Color:
	if _mp != null and _mp.has_method("get_player_color"):
		return _mp.get_player_color(pid)
	return Color(0.3, 1.0, 0.3)


func _player_name(pid: int) -> String:
	if _mp != null and _mp.has_method("get_player_name"):
		return str(_mp.get_player_name(pid))
	return "Player %d" % pid


func _bool(v) -> bool:
	return v != null and bool(v)
