extends "res://src/editor/tool_bucket.gd"

# vcb-mp runtime port — script extension of the game's ToolBucket.
#
# Factors the fill out of bucket_fill into a parameterized _do_bucket_fill, and adds
# bucket_fill_remote so MPDrawSync can reproduce the OTHER player's fill using the SENDER's
# layer / colour / bucket settings (per-player, carried in the mouse payload) without
# touching this client's own active layer or ToolBucket toggles.

func bucket_fill(position: Vector2, is_left_click: bool) -> void :
	# Local fill: use this player's active layer, color and bucket settings.
	_do_bucket_fill(position, is_left_click, ED.active_layer, ED.indexed_color_id, ED.paint_color, is_adjacent, is_pass_crosses, is_ignore_empty)

func bucket_fill_remote(position: Vector2, is_left_click: bool, active_layer: int, indexed_color_id: String, paint_color: Color, bucket_state: Dictionary) -> void :
	var r_is_adjacent: bool = bool(bucket_state.get("p_is_adjacent", is_adjacent))
	var r_is_pass_crosses: bool = bool(bucket_state.get("p_is_pass_crosses", is_pass_crosses))
	var r_is_ignore_empty: bool = bool(bucket_state.get("p_is_ignore_empty", is_ignore_empty))
	_do_bucket_fill(position, is_left_click, active_layer, indexed_color_id, paint_color, r_is_adjacent, r_is_pass_crosses, r_is_ignore_empty)

func _do_bucket_fill(position: Vector2, is_left_click: bool, active_layer: int, indexed_color_id: String, paint_color: Color, p_is_adjacent: bool, p_is_pass_crosses: bool, p_is_ignore_empty: bool) -> void :
	if not ED.CIRCUIT_RECT.has_point(position):
		return
	ED.images[Editor.LAYER.LOGIC].lock()
	ED.images[active_layer].lock()
	var is_logic_layer: bool = (active_layer == Editor.LAYER.LOGIC)
	var sample_active_color: String = ED.images[active_layer].get_pixelv(position).to_html()
	var sample_logic_color: String = ED.images[Editor.LAYER.LOGIC].get_pixelv(position).to_html()
	if p_is_ignore_empty:
		if is_logic_layer and sample_active_color == "00000000":
			ED.images[active_layer].unlock()
			ED.images[Editor.LAYER.LOGIC].unlock()
			return
		if not is_logic_layer and sample_logic_color == "00000000":
			ED.images[active_layer].unlock()
			ED.images[Editor.LAYER.LOGIC].unlock()
			return
	var draw_color: String
	if is_left_click:
		if is_logic_layer:
			draw_color = C.PALETTE[indexed_color_id].EDITOR
		else:
			draw_color = paint_color.to_html()
	else:
		draw_color = "00000000"
	var target_color: Color = ED.images[active_layer].get_pixelv(position)
	if p_is_adjacent:
		var is_pass_through_crosses: bool = (
			p_is_pass_crosses and 
			is_logic_layer and 
			p_is_ignore_empty and 
			(sample_logic_color != ("ff" + C.PALETTE.CROSS.EDITOR))
		)
		ED.TEH.bucket_flood_fill(
			target_color, 
			draw_color, 
			position, 
			ED.images[active_layer], 
			ED.images[Editor.LAYER.LOGIC], 
			is_logic_layer, 
			is_pass_through_crosses
		)
	else:
		ED.TEH.bucket_replace(
			ED.images[active_layer].get_pixelv(position), 
			draw_color, 
			ED.images[active_layer]
		)
	ED.images[active_layer].unlock()
	ED.images[Editor.LAYER.LOGIC].unlock()
	E.echo(E.fs_file_modify, {})
	E.echo(E.ed_layers_resources_change, {
		E.ed_layers_resources_change.p_layers: ED.images, })
