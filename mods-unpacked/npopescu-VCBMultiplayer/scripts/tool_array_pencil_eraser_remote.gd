extends Node
onready var ED: = get_parent()
const TRACE_INKS_DICT: = {
	C.PALETTE.TRACE_GRAY.EDITOR: 0,
	C.PALETTE.TRACE_WHITE.EDITOR: 1,
	C.PALETTE.TRACE_RED.EDITOR: 2,
	C.PALETTE.TRACE_ORANGE.EDITOR: 3,
	C.PALETTE.TRACE_YELLOW_WARM.EDITOR: 4,
	C.PALETTE.TRACE_YELLOW_COLD.EDITOR: 5,
	C.PALETTE.TRACE_LEMON.EDITOR: 6,
	C.PALETTE.TRACE_GREEN_WARM.EDITOR: 7,
	C.PALETTE.TRACE_GREEN_COLD.EDITOR: 8,
	C.PALETTE.TRACE_TURQUOISE.EDITOR: 9,
	C.PALETTE.TRACE_BLUE_LIGHT.EDITOR: 10,
	C.PALETTE.TRACE_BLUE.EDITOR: 11,
	C.PALETTE.TRACE_BLUE_DARK.EDITOR: 12,
	C.PALETTE.TRACE_PURPLE.EDITOR: 13,
	C.PALETTE.TRACE_VIOLET.EDITOR: 14,
	C.PALETTE.TRACE_PINK.EDITOR: 15,
}
const TRACE_INKS_LIST: = [
	C.PALETTE.TRACE_GRAY.EDITOR,
	C.PALETTE.TRACE_WHITE.EDITOR,
	C.PALETTE.TRACE_RED.EDITOR,
	C.PALETTE.TRACE_ORANGE.EDITOR,
	C.PALETTE.TRACE_YELLOW_WARM.EDITOR,
	C.PALETTE.TRACE_YELLOW_COLD.EDITOR,
	C.PALETTE.TRACE_LEMON.EDITOR,
	C.PALETTE.TRACE_GREEN_WARM.EDITOR,
	C.PALETTE.TRACE_GREEN_COLD.EDITOR,
	C.PALETTE.TRACE_TURQUOISE.EDITOR,
	C.PALETTE.TRACE_BLUE_LIGHT.EDITOR,
	C.PALETTE.TRACE_BLUE.EDITOR,
	C.PALETTE.TRACE_BLUE_DARK.EDITOR,
	C.PALETTE.TRACE_PURPLE.EDITOR,
	C.PALETTE.TRACE_VIOLET.EDITOR,
	C.PALETTE.TRACE_PINK.EDITOR,
]

var first_pos: = Vector2.ZERO
var last_pos: = Vector2.ZERO
var array_amount: = 1
var array_angle: = 2
var array_angles_list: = [
	Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
	Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
]
var is_auto_cross: = false
var is_multicolored_traces: = false
var array_pixels: = [[0, 0]]
var is_array_space_zero: = false
var pencil_shape: = 0
var pencil_size: = 8
var pencil_pxs_filled: = [[0, 0]]
var pencil_pxs_hollow: = [[0, 0]]
var is_filter: = false

var pb_color: = Color.white
var pb_active_layer: Image
var pb_is_logic_layer: = false
var pb_is_array_tool: = false
var pb_is_eraser_color: = false
var pb_is_multicolored: = false
var pb_multicolored_index: = 0

func _ready() -> void:
	reset_remote_state()

func reset_remote_state() -> void:
	first_pos = Vector2.ZERO
	last_pos = Vector2.ZERO
	array_amount = 1
	array_angle = 2
	array_angles_list = [
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
	]
	is_auto_cross = false
	is_multicolored_traces = false
	array_pixels = [[0, 0]]
	is_array_space_zero = false
	pencil_shape = 0
	pencil_size = 8
	pencil_pxs_filled = [[0, 0]]
	pencil_pxs_hollow = [[0, 0]]
	is_filter = false
	pb_color = Color.white
	pb_active_layer = null
	pb_is_logic_layer = false
	pb_is_array_tool = false
	pb_is_eraser_color = false
	pb_is_multicolored = false
	pb_multicolored_index = 0

func apply_brush_state(brush_state: Dictionary, editor_tool: int) -> void:
	if brush_state.has("p_pencil_size"):
		pencil_size = int(brush_state["p_pencil_size"])
	if brush_state.has("p_pencil_shape"):
		pencil_shape = int(brush_state["p_pencil_shape"])
	if brush_state.has("p_array_amount"):
		array_amount = int(brush_state["p_array_amount"])
	if brush_state.has("p_array_angle"):
		array_angle = int(brush_state["p_array_angle"])
	if brush_state.has("p_array_space"):
		array_angles_list[array_angle] = brush_state["p_array_space"]
	if brush_state.has("p_is_auto_cross"):
		is_auto_cross = bool(brush_state["p_is_auto_cross"])
	if brush_state.has("p_is_multicolored_traces"):
		is_multicolored_traces = bool(brush_state["p_is_multicolored_traces"])
	if brush_state.has("p_is_filter"):  # sync filter state
		is_filter = bool(brush_state["p_is_filter"])
	if editor_tool == Editor.TOOL.ARRAY:
		update_array_pixels()
	else:
		update_pencil_pixels()

func draw_remote(pixel: Vector2, is_just_pressed: bool, is_draw: bool, active_layer: int, indexed_color_id: String, paint_color: Color, editor_tool: int) -> void:
	if is_just_pressed:
		first_pos = pixel
		last_pos = pixel
	var is_logic_layer: bool = (active_layer == Editor.LAYER.LOGIC)
	var draw_color: String
	if is_draw:
		if is_logic_layer:
			draw_color = C.PALETTE[indexed_color_id].EDITOR
		else:
			draw_color = paint_color.to_html()
	else:
		draw_color = "00000000"
	var x0: = pixel.x
	var y0: = pixel.y
	var x1: = pixel.x if is_just_pressed else last_pos.x
	var y1: = pixel.y if is_just_pressed else last_pos.y
	var xDist: = abs(x1 - x0)
	var yDist: = -abs(y1 - y0)
	var xStep: = 1 if (x0 < x1) else -1
	var yStep: = 1 if (y0 < y1) else -1
	var error: = xDist + yDist
	ED.images[active_layer].lock()
	ED.images[Editor.LAYER.LOGIC].lock()
	pb_color = Color(draw_color)
	pb_active_layer = ED.images[active_layer]
	pb_is_logic_layer = is_logic_layer
	pb_is_array_tool = (editor_tool == Editor.TOOL.ARRAY)
	pb_is_eraser_color = (draw_color == "00000000")
	pb_is_multicolored = is_multicolored_traces and (draw_color in TRACE_INKS_DICT)
	pb_multicolored_index = TRACE_INKS_DICT[draw_color] if pb_is_multicolored else 0
	var brush_pxs_filled: Array = array_pixels if pb_is_array_tool else pencil_pxs_filled
	var brush_pxs_hollow: Array = array_pixels if pb_is_array_tool else pencil_pxs_hollow
	paint_brush_pixels(brush_pxs_filled, pixel)
	while (x0 != x1 or y0 != y1):
		var cond: bool
		if pixel.y > last_pos.y:
			cond = (2 * error - yDist >= xDist - 2 * error)
		else:
			cond = (2 * error - yDist > xDist - 2 * error)
		if cond:
			error += yDist
			x0 += xStep
		else:
			error += xDist
			y0 += yStep
		if not Vector2(x0, y0) == last_pos:
			paint_brush_pixels(brush_pxs_hollow, Vector2(x0, y0))
	ED.images[active_layer].unlock()
	ED.images[Editor.LAYER.LOGIC].unlock()
	E.echo(E.ed_layers_resources_change, {
		E.ed_layers_resources_change.p_layers: ED.images, })
	last_pos = pixel

func paint_brush_pixels(p_brush_pxs: Array, p_root_px: Vector2) -> void:
	for i in p_brush_pxs.size():
		var px: Array = p_brush_pxs[i]
		var xy: = Vector2(p_root_px.x + px[0], p_root_px.y + px[1])
		if not ED.CIRCUIT_RECT.has_point(xy):
			continue
		var px_ic: String = ED.images[Editor.LAYER.LOGIC].get_pixelv(xy).to_html()
		if pb_is_logic_layer:
			if pb_is_array_tool:
				if pb_is_multicolored:
					pb_color = Color(TRACE_INKS_LIST[(pb_multicolored_index + i) % 16])
				if is_auto_cross:
					if px_ic != "00000000" and not pb_is_eraser_color and ED.filter.empty():
						pb_active_layer.set_pixelv(xy, Color(C.PALETTE.CROSS.EDITOR))
						continue
		elif px_ic == "00000000":
			continue
		if not ED.filter.empty() and not Color(px_ic) in ED.filter:
			continue
		pb_active_layer.set_pixelv(xy, pb_color)

func update_array_pixels() -> void:
	var pixels: = []
	for i in array_amount:
		var offset: Vector2 = array_angles_list[array_angle] * i
		pixels.append([int(offset.x), int(offset.y)])
	pixels = pixels if not is_array_space_zero else [[0, 0]]
	pixels = pixels if not pixels.empty() else [[0, 0]]
	var x_centering: int = (pixels[0][0] + pixels[-1][0]) / 2
	var y_centering: int = (pixels[0][1] + pixels[-1][1]) / 2
	for px in pixels:
		px[0] -= x_centering
		px[1] -= y_centering
	array_pixels = pixels

func update_pencil_pixels() -> void:
	var new_pxs_filled: = []
	var new_pxs_hollow: = []
	var size_x: int
	var size_y: int
	if (pencil_shape == 0) or (pencil_shape == 2 and pencil_size < 4):
		for x in pencil_size:
			for y in pencil_size:
				new_pxs_filled.append([x, y])
				if (x == pencil_size - 1) or (y == pencil_size - 1) or (x == 0) or (y == 0):
					new_pxs_hollow.append([x, y])
		size_x = int(max(abs(new_pxs_filled[0][0] - new_pxs_filled[-1][0]) + 2, 1))
		size_y = size_x
	elif pencil_shape == 1:
		var proportional_size: int = int(sqrt((pencil_size * pencil_size) / 2))
		var increment_range: = []
		for i in proportional_size:
			increment_range.append(i)
		var temp: = increment_range.duplicate()
		for i in temp:
			if i != 0:
				increment_range.push_front(abs(i))
		var decrement_range: = []
		for i in increment_range:
			decrement_range.append(proportional_size - i - 1)
		for x in increment_range.size():
			for y in decrement_range.size():
				if increment_range[x] <= decrement_range[y]:
					new_pxs_filled.append([x, y])
				if increment_range[x] == decrement_range[y]:
					new_pxs_hollow.append([x, y])
		new_pxs_filled = new_pxs_filled if not new_pxs_filled.empty() else [[0, 0]]
		size_x = int(max(abs(new_pxs_filled[0][0] - new_pxs_filled[-1][0]) + 2, 1))
		size_y = size_x
	elif pencil_shape == 2:
		var r: int = int(ceil(pencil_size / 2.0))
		var x: int = 0
		var y: int = r
		var d: float = 3 - 2 * r
		size_x = int(max(r * 2 + 2, 1))
		size_y = size_x
		var map: = []
		for _x in size_x:
			map.append([])
			map[_x].resize(size_y)
		while (y >= x):
			x += 1
			if (d > 0):
				y -= 1
				d = d + 4 * (x - y) - 10
			else:
				d = d + 4 * x + 6
			new_pxs_hollow += [[ + x, + y], [ + x, - y + 1], [ - x + 1, + y], [ - x + 1, - y + 1],
						[ + y, + x], [ + y, - x + 1], [ - y + 1, + x], [ - y + 1, - x + 1]]
			map[r + x][r + y] = true;map[r + x][r - y + 1] = true;
			map[r - x + 1][r + y] = true;map[r - x + 1][r - y + 1] = true
			map[r + y][r + x] = true;map[r + y][r - x + 1] = true;
			map[r - y + 1][r + x] = true;map[r - y + 1][r - x + 1] = true
		var queue: = [[size_x / 2, size_y / 2]]
		while not queue.empty():
			var px = queue.pop_back()
			var s = map.size() - 1
			var neighbours = [[min(px[0] + 1, s), px[1]], [max(px[0] - 1, 0), px[1]],
								[px[0], min(px[1] + 1, s)], [px[0], max(px[1] - 1, 0)]]
			for nbr in neighbours:
				if map[nbr[0]][nbr[1]] == null:
					queue.append(nbr)
			map[px[0]][px[1]] = true
		for m_x in map.size() - 1:
			for m_y in map.size() - 1:
				if map[m_x][m_y] == true:
					new_pxs_filled.append([m_x - size_x / 2, m_y - size_y / 2])
	new_pxs_filled = new_pxs_filled if not new_pxs_filled.empty() else [[0, 0]]
	new_pxs_hollow = new_pxs_hollow if not new_pxs_hollow.empty() else [[0, 0]]
	var x_centering: int = (new_pxs_filled[0][0] + new_pxs_filled[-1][0]) / 2 if not (pencil_shape == 2) else 1
	var y_centering: int = (new_pxs_filled[0][1] + new_pxs_filled[-1][1]) / 2 if not (pencil_shape == 2) else 1
	for px in new_pxs_filled:
		px[0] -= x_centering
		px[1] -= y_centering
	for px in new_pxs_hollow:
		px[0] -= x_centering
		px[1] -= y_centering
	if (pencil_shape == 2 and pencil_size > 3):
		for px in new_pxs_filled:
			px[0] -= -1
			px[1] -= -1
	pencil_pxs_filled = new_pxs_filled
	pencil_pxs_hollow = new_pxs_hollow
