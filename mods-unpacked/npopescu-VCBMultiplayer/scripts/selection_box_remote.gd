extends Control

# --- Remote Selection Box Renderer ---
# Renders the remote player's selection box with a greenish tint to distinguish
# from the local SelectionBox. Updated via direct calls from mp_draw_sync.gd
# (not via the event system, to avoid clobbering the local SelectionBox).

onready var DashedLine: = $DashedLine
onready var SelectionTexture: = $SelectionTexture

const REMOTE_TINT: = Color(0.3, 1.0, 0.3, 1.0)
# Same opacity the local SelectionBox uses for its floating pixels (see main.tscn
# World/SelectionBox/SelectionTexture.self_modulate).
const LOCAL_TEXTURE_MODULATE: = Color(1.0, 1.0, 1.0, 0.784314)

func _ready() -> void:
	hide()
	# Tint ONLY the dashed border green, so a remote selection still reads as the *other*
	# player's. The lifted pixels themselves render in their true colours at the same opacity
	# as the local SelectionBox — if they were green-tinted and translucent, a remote selection
	# looked like the traces vanished into a faint green ghost the instant they were lifted off
	# the board (on release).
	DashedLine.modulate = REMOTE_TINT
	SelectionTexture.modulate = Color(1.0, 1.0, 1.0, 1.0)
	SelectionTexture.self_modulate = LOCAL_TEXTURE_MODULATE
	# Also tint the dashed line material
	if DashedLine.get_material():
		DashedLine.get_material().set_shader_param("is_move", true)

# Recolour the remote box to the owning player's chosen hover colour (called from mp_draw_sync
# with that peer's colour). Only the dashed border is tinted; the lifted pixels keep their true
# colours at the local opacity (see _ready).
func set_tint(c: Color) -> void:
	DashedLine.modulate = c
	if DashedLine.get_material():
		DashedLine.get_material().set_shader_param("is_move", true)


func update_area(p_selection_area: Rect2, p_selection_tiles: Vector2) -> void:
	if p_selection_area.position == Vector2(-1, -1):
		hide()
		return
	show()
	var pos: = p_selection_area.position
	var size: = p_selection_area.size
	pos.x += (p_selection_tiles.x + 1) * size.x if p_selection_tiles.x < 0 else 0.0
	pos.y += (p_selection_tiles.y + 1) * size.y if p_selection_tiles.y < 0 else 0.0
	size.x += (abs(p_selection_tiles.x) - 1) * size.x
	size.y += (abs(p_selection_tiles.y) - 1) * size.y
	rect_position = pos
	SelectionTexture.rect_size = size
	DashedLine.rect_size = size
	if DashedLine.get_material():
		DashedLine.get_material().set_shader_param("size", size)

func update_image(p_selection_image: Image) -> void:
	if p_selection_image == null:
		SelectionTexture.texture = null
		SelectionTexture.visible = false
		return
	var tex: = ImageTexture.new()
	tex.create_from_image(p_selection_image, 0)
	SelectionTexture.texture = tex
	SelectionTexture.visible = true

func update_zoom(zoom: float) -> void:
	if DashedLine.get_material():
		DashedLine.get_material().set_shader_param("zoom", zoom)
	# Keep the lifted pixels visible at every zoom level. The local SelectionBox swaps to a
	# downsampled texture when zoomed out; the remote box has no such node, so instead of
	# hiding the selection (which made it look like the traces disappeared) we keep the
	# full-res texture shown whenever there is one.
	SelectionTexture.visible = (SelectionTexture.texture != null)
