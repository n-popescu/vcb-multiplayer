extends Label

var _status: String = "Offline"

func _ready():
	text = _status

func set_status(s: String) -> void:
	_status = s
	text = s

func show_hosting(code: String) -> void:
	text = "Hosting: " + code

func show_connected() -> void:
	text = "Connected!"

func show_offline() -> void:
	text = "Offline"
