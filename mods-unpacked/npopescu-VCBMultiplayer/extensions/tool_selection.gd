extends "res://src/editor/tool_selection.gd"

# vcb-mp runtime port — script extension of the game's ToolSelection.
#
# Paste position fix: a paste triggered with the mouse on the board lands at the cursor
# (so it mirrors to the remote peer at the right spot). When the mouse is off-board (e.g.
# the user presses Ctrl+V while hovering over the VMem panel or assembly editor), we fall
# back to vanilla's camera-centred position instead of always using mouse_pos_on_board.
#
# Bug fixed (was: always mouse_pos_on_board):
#   When mouse was off-board, mouse_pos_on_board was stale (often Vector2.ZERO), placing
#   the paste at (-size/2, -size/2) — off the board, invisible. On the next paste call
#   selection_image != null triggered apply_selection(true), stamping the invisible selection
#   to the board corner (visible traces) before creating the new floating selection at the
#   correct position. The user saw: traces at corner + movable preview = apparent double-paste.
#
# The area/image RPCs carry the actual paste position to the remote regardless of which
# fallback is used, so network sync is unaffected.

func _ev_ed_selection_paste(_mode: int, _args: Dictionary) -> void :
	if ED.editor_tool == ED.TOOL.SELECTION:
		if _args.has(E.mi_mouse_input_on_board.p_position):
			mouse_pos_on_board = _args[E.mi_mouse_input_on_board.p_position]
		paste_selection()

func paste_selection() -> void :
	if not copy_selection_image == null:
		ED.is_busy = true
		if not selection_image == null:
			apply_selection(true)
		var size: = copy_selection_area.size
		# Use cursor position when the mouse is on the board; camera-centre otherwise (vanilla).
		# This prevents stale/zero mouse_pos_on_board from placing the paste off-board, which
		# caused apply_selection(true) to stamp invisible traces on the next paste call.
		var pos: = get_pos_centered_at_camera(size)
		if ED.is_world_frame_context:
			pos = Vector2(mouse_pos_on_board.x - (size.x / 2), mouse_pos_on_board.y - (size.y / 2))
		selection_area = Rect2(pos, size)
		selection_area.position = selection_area.position.round()
		selection_image = copy_selection_image.duplicate()
		emit_changes(EMITCHANGE.AREA_AND_IMAGE)
		if not copy_selection_image_p_on == null:
			selection_image_p_on = copy_selection_image_p_on.duplicate()
			selection_image_p_off = copy_selection_image_p_off.duplicate()

# vcb-mp fix: set is_selecting BEFORE the new-marquee area emit. The mod's from_mouse gate
# (MPDrawSync._is_selection_mouse_active) keys on is_selecting/is_dragging/is_tiling to know a
# live board gesture is in progress; vanilla emitted the first marquee area change while
# is_selecting was still false, so the remote adopted a 1x1 selection_area and mis-detected a
# drag (the selection only appeared on the remote once you moved it). This is the whole
# vanilla select() reproduced verbatim with those two lines reordered (can't patch mid-func).
func select(position: Vector2, is_just_pressed: bool, 
			is_just_released: bool, is_left_click: bool) -> void :
	position.x = clamp(position.x, 0, int(ED.CIRCUIT_SPAN))
	position.y = clamp(position.y, 0, int(ED.CIRCUIT_SPAN))
	if is_just_pressed or is_shift_just_pressed:
		first_pos = position
		is_axis_straight_set = false
	var diff = position - first_pos
	if not is_axis_straight_set:
		if diff.is_equal_approx(Vector2.ZERO):
			pass
		elif is_equal_approx(abs(diff.x), abs(diff.y)):
			axis_constraint_straight = 2
			is_axis_straight_set = true
		elif abs(diff.x) > abs(diff.y):
			axis_constraint_straight = 2
			is_axis_straight_set = true
		else:
			axis_constraint_straight = 0
			is_axis_straight_set = true
	if BetterInput.is_key_pressed(KEY_SHIFT) and is_axis_straight_set:
		if not is_shift_pressed_before_selecting or is_dragging:
			if axis_constraint_straight == 2:
				position.y = position.y if is_just_pressed else last_pos.y
			elif axis_constraint_straight == 0:
				position.x = position.x if is_just_pressed else last_pos.x
	if is_just_released:
		if (selection_area.size.x < MIN_SELECTION_SIZE.x) and (selection_area.size.y < MIN_SELECTION_SIZE.y):
			is_selecting = false
			delete_selection()
			return
		if is_tiling:
			apply_selection(true)
			delete_selection()
			is_tiling = false
		elif not is_dragging and is_selecting:
			selection_origin = selection_area.position
			HISTORY.public_register_state(ED.active_layer, true)
			selection_image = Image.new()
			selection_image.create(int(selection_area.size.x), int(selection_area.size.y), false, Image.FORMAT_RGBA8)
			selection_image.blit_rect_mask(ED.images[ED.active_layer], ED.images[Editor.LAYER.LOGIC], selection_area, Vector2(0, 0))
			emit_changes(EMITCHANGE.IMAGE)
			if ED.active_layer == Editor.LAYER.LOGIC:
				selection_image_p_on = Image.new()
				selection_image_p_on.create(int(selection_area.size.x), int(selection_area.size.y), false, Image.FORMAT_RGBA8)
				selection_image_p_on.blit_rect(ED.images[Editor.LAYER.PAINT_ON], selection_area, Vector2(0, 0))
				selection_image_p_off = Image.new()
				selection_image_p_off.create(int(selection_area.size.x), int(selection_area.size.y), false, Image.FORMAT_RGBA8)
				selection_image_p_off.blit_rect(ED.images[Editor.LAYER.PAINT_OFF], selection_area, Vector2(0, 0))
			ED.images[ED.active_layer].blit_rect(background_image, Rect2(Vector2.ZERO, selection_area.size), selection_area.position)
			if ED.active_layer == Editor.LAYER.LOGIC:
				ED.images[Editor.LAYER.PAINT_ON].blit_rect(background_image, Rect2(Vector2.ZERO, selection_area.size), selection_area.position)
				ED.images[Editor.LAYER.PAINT_OFF].blit_rect(background_image, Rect2(Vector2.ZERO, selection_area.size), selection_area.position)
			E.echo(E.fs_file_modify, {})
			E.echo(E.ed_layers_resources_change, {
				E.ed_layers_resources_change.p_layers: ED.images, })
			is_selecting = false
		is_dragging = false
		return
	if is_just_pressed and is_left_click:
		if is_tiling:
			return
		is_dragging = selection_area.has_point(position)
		if is_dragging:
			last_pos = position
			if BetterInput.is_key_pressed(KEY_ALT):
				apply_selection(false)
		else:
			if not selection_image == null:
				apply_selection(true)
			selection_origin = position
			selection_area.position = position
			selection_area.size = Vector2(1, 1)
			# Set is_selecting BEFORE emitting the area change. MPDrawSync's from_mouse gate
			# (_is_selection_mouse_active) keys on this flag to decide the area RPC is part of a
			# live board gesture (so the remote's select_remote owns the tool state and the RPC
			# must NOT overwrite selection_area). Emitting first left is_selecting=false on this
			# first marquee frame, so the remote adopted a 1x1 selection_area and its has_point()
			# drag-vs-new-select test misfired — the selection wasn't mirrored until the move.
			is_selecting = true
			emit_changes(EMITCHANGE.AREA)
			return
	if is_just_pressed and not is_left_click:
		if is_dragging or is_selecting:
			return
		is_tiling = selection_area.has_point(position)
		if is_tiling:
			last_pos = position
	if is_dragging:
		selection_area.position += position - last_pos
	elif is_tiling:
		var pos: = selection_area.position
		var size: = position - pos
		var tiles: = (size / selection_area.size).floor()
		tiles.x += 2 * float(int(tiles.x) > - 1) - 1
		tiles.y += 2 * float(int(tiles.y) > - 1) - 1
		selection_tiles = tiles
	elif is_selecting:
		var pos: = selection_origin
		var size: = position - pos
		pos.x = pos.x if size.x > - 1 else pos.x + size.x
		pos.y = pos.y if size.y > - 1 else pos.y + size.y
		size.x = abs(size.x) + 1
		size.y = abs(size.y) + 1
		size.x = min(size.x, ED.CIRCUIT_SPAN - pos.x)
		size.y = min(size.y, ED.CIRCUIT_SPAN - pos.y)
		selection_area = Rect2(pos, size)
	emit_changes(EMITCHANGE.AREA)
	last_pos = position
