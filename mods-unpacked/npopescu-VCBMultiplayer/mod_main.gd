extends Node

# mod_main.gd — Mod Loader entry point for the VCB Multiplayer runtime port.
#
# This installs a script extension for every game script the mod changes, ships the
# multiplayer scripts unchanged under scripts/, and — instead of extending the main scene's
# root script (main.gd), which crashes the Godot Mod Loader on this game — builds the extra
# scene nodes and the MP / MPDrawSync autoloads itself, from here, once the Main scene is up.
#
# Why not extend main.gd: extending the *main-scene root script* via install_script_extension
# hard-crashes VCB at load. So we do NOT extend main.gd; we wait (in _process) for the Main
# scene to appear and graft the nodes on then, which is functionally identical.

const MOD_DIR := "npopescu-VCBMultiplayer"
const MOD_ROOT := "res://mods-unpacked/npopescu-VCBMultiplayer"
const SCRIPTS := MOD_ROOT + "/scripts"
const SELECTION_BOX_SHADER := "res://src/graphics/shaders/selection_box.shader"
const MAIN_THEME := "res://src/gui/themes/main_theme.tres"

var _ext := MOD_ROOT + "/extensions/"
var _built := false


func _init() -> void:
	ModLoaderLog.info("Installing VCB Multiplayer (runtime port)…", MOD_DIR)
	# Script extensions for the game scripts the mod changes (all plain scripts — no scene
	# roots, no class_name targets other than the well-supported cases). Order doesn't matter.
	ModLoaderMod.install_script_extension(_ext + "editor.gd")
	ModLoaderMod.install_script_extension(_ext + "input_blocker.gd")
	ModLoaderMod.install_script_extension(_ext + "history.gd")
	ModLoaderMod.install_script_extension(_ext + "shortcuts.gd")
	ModLoaderMod.install_script_extension(_ext + "tool_bucket.gd")
	ModLoaderMod.install_script_extension(_ext + "tool_selection.gd")
	ModLoaderMod.install_script_extension(_ext + "button_texture_event.gd")
	ModLoaderMod.install_script_extension(_ext + "button_toggle_run.gd")
	ModLoaderMod.install_script_extension(_ext + "simulation_controls.gd")
	ModLoaderMod.install_script_extension(_ext + "simulation_sliders.gd")
	ModLoaderMod.install_script_extension(_ext + "simulator.gd")
	ModLoaderMod.install_script_extension(_ext + "label_mouse_position.gd")
	ModLoaderMod.install_script_extension(_ext + "mouse_over_label.gd")


func _ready() -> void:
	# Poll for the Main scene, then build once. (Deferred until it exists so we run after the
	# game's own _ready has finished — same timing the old main.gd extension had.)
	set_process(true)


func _process(_delta: float) -> void:
	if _built:
		set_process(false)
		return
	var root := get_tree().root
	var main := root.get_node_or_null("Main")
	if main == null:
		return
	var editor := main.get_node_or_null("Systems/Editor")
	if editor == null:
		editor = main.find_node("Editor", true, false)
	var world := main.get_node_or_null("World")
	if editor == null or world == null:
		return
	_built = true
	set_process(false)
	_build(main, root, editor, world)


# --- runtime node construction (was the main.gd extension) --------------------------------
func _build(main: Node, root: Node, editor: Node, world: Node) -> void:
	# World: remote cursor + remote selection box.
	_build_remote_cursor(world)
	_build_remote_selection_box(world)

	# Editor: the two *Remote tools.
	if editor.get_node_or_null("ToolArrayPencilEraserRemote") == null:
		var apre := _new_script(SCRIPTS + "/tool_array_pencil_eraser_remote.gd")
		if apre != null:
			apre.name = "ToolArrayPencilEraserRemote"
			editor.add_child(apre)
	if editor.get_node_or_null("ToolSelectionRemote") == null:
		var sel := _new_script(SCRIPTS + "/tool_selection_remote.gd")
		if sel != null:
			sel.name = "ToolSelectionRemote"
			editor.add_child(sel)

	# Autoload: MP (must exist before the GUI + MPDrawSync resolve /root/MP).
	if root.get_node_or_null("MP") == null:
		var mp := _new_script(SCRIPTS + "/mp_global.gd")
		if mp != null:
			mp.name = "MP"
			root.add_child(mp)

	# Header GUI: status label + MP button (with its window).
	var file_controls := main.find_node("FileControls", true, false)
	if file_controls != null:
		_build_header_ui(main, file_controls)

	# Autoload: MPDrawSync (resolves the nodes above; it yields a frame first).
	if root.get_node_or_null("MPDrawSync") == null:
		var sync := _new_script(SCRIPTS + "/mp_draw_sync.gd")
		if sync != null:
			sync.name = "MPDrawSync"
			root.add_child(sync)


# Instance a mod script, or null (logged) if it can't be loaded — never dereference a null.
func _new_script(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_warning("[VCB-MP] missing script, skipping: " + path)
		return null
	var scr = load(path)
	if scr == null:
		push_warning("[VCB-MP] failed to load script: " + path)
		return null
	var inst = scr.new()
	if inst == null:
		push_warning("[VCB-MP] failed to instance script: " + path)
		return null
	return inst


func _build_remote_cursor(world: Node) -> void:
	if world.get_node_or_null("CursorRemote") != null:
		return
	var cursor_remote := Node2D.new()
	cursor_remote.name = "CursorRemote"
	cursor_remote.z_index = 10
	var sprite := Sprite.new()
	sprite.name = "Sprite"
	sprite.centered = false
	cursor_remote.add_child(sprite)
	world.add_child(cursor_remote)


func _build_remote_selection_box(world: Node) -> void:
	if world.get_node_or_null("SelectionBoxRemote") != null:
		return
	var box := _new_script(SCRIPTS + "/selection_box_remote.gd")
	if box == null:
		return
	box.name = "SelectionBoxRemote"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var selection_texture := TextureRect.new()
	selection_texture.name = "SelectionTexture"
	selection_texture.visible = false
	selection_texture.self_modulate = Color(0.3, 1, 0.3, 0.784314)
	selection_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	selection_texture.expand = true
	selection_texture.stretch_mode = TextureRect.STRETCH_TILE
	box.add_child(selection_texture)

	var dashed_line := ColorRect.new()
	dashed_line.name = "DashedLine"
	dashed_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dashed_line.color = Color(1, 1, 1, 0.1)
	var mat := _make_selection_box_material()
	if mat != null:
		dashed_line.material = mat
	box.add_child(dashed_line)

	world.add_child(box)


# Safely reproduce selection_box_remote.tres + GDshaderLoader: a ShaderMaterial whose shader
# carries the real selection_box code (from the .shader.gd companion), with the mod's params.
func _make_selection_box_material() -> ShaderMaterial:
	var shader: Shader = null
	var gd_path := SELECTION_BOX_SHADER + ".gd"
	if ResourceLoader.exists(gd_path):
		var src = load(gd_path)
		if src != null:
			var inst = src.new()
			if inst != null:
				var code = inst.get("shader_code")
				if typeof(code) == TYPE_STRING and not (code as String).empty():
					shader = Shader.new()
					shader.code = code
	if shader == null:
		var res = load(SELECTION_BOX_SHADER)
		if res is Shader:
			shader = res
	if shader == null:
		shader = Shader.new()
		shader.code = "shader_type canvas_item;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_param("opacity", 0.2)
	mat.set_shader_param("width", 2.0)
	mat.set_shader_param("size", Vector2(1, 1))
	mat.set_shader_param("zoom", 1.0)
	mat.set_shader_param("is_move", false)
	return mat


func _build_header_ui(main: Node, file_controls: Node) -> void:
	# Status label. BtnMP resolves it via ../StatusLabel in its _ready, so it must already be in
	# the tree before the button is added below — we add it first, then (once the button exists)
	# move it so it renders to the RIGHT of the MP button, matching the .pck build's main.tscn
	# ordering (…BtnMP, StatusLabel). FileControls is an HBoxContainer, so child order is the
	# left-to-right layout order.
	var status_label: Node = file_controls.get_node_or_null("StatusLabel")
	if status_label == null:
		status_label = _new_script(SCRIPTS + "/gui/status_label.gd")
		if status_label != null:
			status_label.name = "StatusLabel"
			status_label.text = "status"
			file_controls.add_child(status_label)

	if file_controls.get_node_or_null("BtnMP") != null:
		return
	# Build the button + its window detached; adding the button to the tree then fires the
	# window's _ready first and the button's after (so its onready $MPWindow / ../StatusLabel
	# both resolve).
	var btn := _new_script(SCRIPTS + "/gui/btn_mp.gd")
	if btn == null:
		return
	btn.name = "BtnMP"
	btn.text = "MP"
	btn.focus_mode = Control.FOCUS_NONE

	var window := _new_script(SCRIPTS + "/gui/mp_window.gd")
	if window != null:
		window.name = "MPWindow"
		window.rect_min_size = Vector2(360, 0)
		var theme_res = load(MAIN_THEME)
		if theme_res is Theme:
			window.theme = theme_res
		btn.add_child(window)

	file_controls.add_child(btn)

	# Move the status label to sit immediately to the RIGHT of the MP button. It was added
	# before the button (so BtnMP's ../StatusLabel lookup resolved); moving it to the last slot
	# now places it after the button in the HBoxContainer.
	if status_label != null and is_instance_valid(status_label):
		file_controls.move_child(status_label, file_controls.get_child_count() - 1)
