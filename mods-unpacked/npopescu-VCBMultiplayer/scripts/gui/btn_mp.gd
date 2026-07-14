extends Button
# mp/gui/BtnMP.gd
#
# The toolbar "MP" button opens the Multiplayer *settings window* (mp_window.gd) instead
# of a cramped dropdown. All host/join logic lives in the window; this script only opens
# it and keeps the little header StatusLabel in sync with the connection state.

onready var MPWindow = $MPWindow
onready var StatusLabel: Label = $"../StatusLabel"

var mp: Node = null

func _ready() -> void:
	mp = get_tree().root.get_node_or_null("/root/MP")
	if mp:
		var _s1 = mp.connect("status_update", self, "_on_status_update")
		var _s2 = mp.connect("connection_failed", self, "_on_connection_failed")
		var _s3 = mp.connect("player_connected", self, "_on_player_connected")
		var _s4 = mp.connect("player_disconnected", self, "_on_player_disconnected")
		var _s5 = mp.connect("server_disconnected", self, "_on_server_disconnected")
	var _p = connect("pressed", self, "_on_button_pressed")
	if StatusLabel and StatusLabel.has_method("show_offline"):
		StatusLabel.show_offline()

func _on_button_pressed() -> void:
	if MPWindow and MPWindow.has_method("open_window"):
		MPWindow.open_window()

func _on_status_update(text: String) -> void:
	if StatusLabel:
		StatusLabel.set_status(text)

func _on_player_connected(_id: int) -> void:
	if StatusLabel and StatusLabel.has_method("show_connected"):
		StatusLabel.show_connected()

func _on_player_disconnected(_id: int) -> void:
	if StatusLabel and mp and StatusLabel.has_method("show_hosting"):
		StatusLabel.show_hosting(str(mp.upnp_external_ip))

func _on_server_disconnected() -> void:
	if StatusLabel and StatusLabel.has_method("show_offline"):
		StatusLabel.show_offline()

func _on_connection_failed(error: String) -> void:
	if StatusLabel:
		StatusLabel.set_status("Error: " + str(error))
