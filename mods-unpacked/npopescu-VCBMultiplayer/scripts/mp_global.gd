extends Node

# Network state
var peer: NetworkedMultiplayerENet
var port: int = 6777
var max_players: int = 2
var connected_players: Array = []
var is_host: bool = false
var is_connected: bool = false
var is_connecting: bool = false
var is_game_started: bool = false
var my_id: int = 0

# A join is confirmed by the connected_to_server signal, or failed by connection_failed /
# this timeout. The token invalidates a stale timeout once the outcome is known.
const JOIN_TIMEOUT_SEC: float = 6.0
var _join_token: int = 0

# Player info
var player_name: String = "Player"
# Peer id → display name, for everyone in the session (including us). Filled by exchanging
# names on connect (see _on_network_peer_connected / _on_connected_to_server) and kept live by
# _receive_player_name; the roster UI reads it via get_player_name() so it shows names, not ids.
var player_names: Dictionary = {}

# Scene to load when game starts
var game_scene_path: String = "res://src/main/main.tscn"

signal player_connected(id)
signal player_disconnected(id)
signal server_disconnected
signal connection_failed(error)
signal status_update(text)
signal game_started
# Emitted when the peer→name map changes (a name arrived / was updated), so the roster UI
# can refresh to show the new name without a connect/disconnect event.
signal roster_updated

var upnp_external_ip: String = ""
var upnp: UPNP
var _is_applying_local_mode_change: bool = false
var _is_applying_remote_mode_change: bool = false

func _ready():
	var name_file = File.new()
	if name_file.file_exists("user://mp_name.dat"):
		name_file.open("user://mp_name.dat", File.READ)
		player_name = name_file.get_var()
		name_file.close()
	
	get_tree().connect("network_peer_connected", self, "_on_network_peer_connected")
	get_tree().connect("network_peer_disconnected", self, "_on_network_peer_disconnected")
	get_tree().connect("server_disconnected", self, "_on_server_disconnected")
	# A join is only really "connected" once ENet confirms it. Listen for the client-side
	# connect/fail signals so we can tell a live host apart from an address that simply
	# doesn't resolve (which otherwise sits silently in CONNECTING and looks "connected").
	get_tree().connect("connected_to_server", self, "_on_connected_to_server")
	get_tree().connect("connection_failed", self, "_on_connection_failed_to_server")
	E.follow_events(self, [E.mi_mode_change_requested])


func emit_status(text: String):
	emit_signal("status_update", text)


func set_player_name(new_name: String) -> void:
	new_name = new_name.strip_edges()
	if new_name == "":
		return
	player_name = new_name
	var name_file = File.new()
	if name_file.open("user://mp_name.dat", File.WRITE) == OK:
		name_file.store_var(player_name)
		name_file.close()
	# Keep our own roster entry current and, if we're in a session, tell the other peers so
	# the change shows up on their side too.
	if my_id != 0:
		player_names[my_id] = player_name
	_broadcast_player_name()
	emit_signal("roster_updated")


# The display name for a peer id: the synced name if we've received it, else a numeric
# fallback so the roster still reads sensibly before the name arrives.
func get_player_name(pid) -> String:
	var key: int = int(pid)
	if player_names.has(key):
		var n: String = str(player_names[key]).strip_edges()
		if n != "":
			return n
	return "Player %d" % key


# Send our name to every remote peer (no-op when not in a live session).
func _broadcast_player_name() -> void:
	if get_tree().network_peer == null or not is_connected:
		return
	for peer_id in _get_remote_peer_ids():
		rpc_id(int(peer_id), "_receive_player_name", my_id, player_name)


# A peer told us its display name (on connect, or after they renamed).
remote func _receive_player_name(pid: int, pname: String) -> void:
	player_names[int(pid)] = str(pname)
	emit_signal("roster_updated")


func request_mode_change(is_simulation_requested: bool) -> void:
	if not is_connected or get_tree().network_peer == null:
		E.emit_signal("mi_mode_change_requested", is_simulation_requested)
		return
	_is_applying_local_mode_change = true
	E.emit_signal("mi_mode_change_requested", is_simulation_requested)
	_is_applying_local_mode_change = false
	var peer_ids = _get_remote_peer_ids()
	if peer_ids.empty():
		return
	for peer_id in peer_ids:
		rpc_id(int(peer_id), "on_mode_change_requested", is_simulation_requested)


func _ev_mi_mode_change_requested(_mode: int, args: Dictionary) -> void:
	if _is_applying_local_mode_change or _is_applying_remote_mode_change or not is_connected or get_tree().network_peer == null:
		return
	var is_simulation_requested: bool = bool(args.get(E.mi_mode_change_requested.p_is_simulation_requested, false))
	var peer_ids = _get_remote_peer_ids()
	if peer_ids.empty():
		return
	for peer_id in peer_ids:
		rpc_id(int(peer_id), "on_mode_change_requested", is_simulation_requested)


func _get_remote_peer_ids() -> Array:
	var peer_ids = []
	if is_host:
		for peer_id in connected_players:
			if int(peer_id) != 1:
				peer_ids.append(int(peer_id))
	else:
		peer_ids.append(1)
	return peer_ids


# === Host Functions ===

func host_game() -> bool:
	emit_status("Creating ENet...")
	
	peer = NetworkedMultiplayerENet.new()
	
	emit_status("Calling create_server(" + str(port) + ", " + str(max_players) + ")...")
	
	var result = peer.create_server(port, max_players)
	
	emit_status("create_server result: " + str(result))
	
	var status = peer.get_connection_status()
	emit_status("Connection status: " + str(status))
	
	if result != OK:
		emit_status("FAILED: result != OK")
		emit_signal("connection_failed", "Server error: " + str(result))
		return false
	
	if status == NetworkedMultiplayerENet.CONNECTION_DISCONNECTED:
		emit_status("FAILED: disconnected")
		emit_signal("connection_failed", "Disconnected")
		return false
	
	emit_status("Server created! Setting network_peer...")
	get_tree().network_peer = peer
	
	is_host = true
	is_connected = true
	is_game_started = false
	my_id = 1
	connected_players.append(1)
	player_names.clear()
	player_names[1] = player_name
	
	# Get external IP (tries UPnP first, falls back to local)
	upnp_external_ip = get_external_ip()
	emit_status("HOST OK! IP: " + upnp_external_ip)


	# MP: start every session on a fresh board (before we join our own relay, so no stray
	# events fire) — both players begin from the same blank file, not whatever the host had
	# open.
	var fs := _find_file_system()
	if fs and fs.has_method("new_file"):
		fs.new_file()
	
	return true

func _find_file_system() -> Node:
	var main := get_tree().root.get_node_or_null("Main")
	return main.find_node("FileSystem", true, false) if main else null


func get_external_ip() -> String:
	emit_status("Trying UPnP...")
	# Try UPnP first for public IP
	upnp = UPNP.new()
	var err = upnp.discover(2000)
	emit_status("UPnP discover result: " + str(err))
	
	if err == OK:
		var gateway = upnp.get_gateway()
		emit_status("Gateway: " + str(gateway))
		
		if gateway and gateway.is_valid_gateway():
			emit_status("Gateway valid, adding port mapping...")
			upnp.add_port_mapping(port, port, "VCB-MP", "UDP")
			var external_ip = upnp.query_external_address()
			emit_status("External IP from UPnP: " + external_ip)
			if external_ip != "":
				return external_ip
		else:
			emit_status("Gateway not valid")
	else:
		emit_status("UPnP discover failed")
	
	# Fallback to local IP
	emit_status("Falling back to local IP")
	return get_local_ip()


func get_local_ip() -> String:
	var ips = IP.get_local_addresses()
	for ip in ips:
		if ip.begins_with("192.") or ip.begins_with("10.") or ip.begins_with("172."):
			return ip
	return "127.0.0.1"


# === Join Functions ===

func join_game(ip_address: String) -> bool:
	ip_address = ip_address.strip_edges()
	if not ip_address.is_valid_ip_address():
		emit_signal("connection_failed", "Enter the host's numeric IP address (e.g. 192.168.1.20)")
		return false

	emit_status("Connecting to " + ip_address + "…")

	peer = NetworkedMultiplayerENet.new()
	var result = peer.create_client(ip_address, port)
	if result != OK:
		emit_signal("connection_failed", "Could not start client (error " + str(result) + ")")
		peer = null
		return false

	# Assign the peer now so the SceneTree starts polling it — that's what lets ENet
	# actually emit connected_to_server / connection_failed. We are NOT connected yet.
	get_tree().network_peer = peer
	is_connecting = true
	is_connected = false
	is_game_started = false

	# ENet keeps silently retrying an unreachable address, so a successful create_client
	# tells us nothing. Fail the join if it hasn't confirmed within the timeout — that's
	# the "valid IP but no host / doesn't resolve" case the user hits.
	_start_join_timeout()
	return true


func _start_join_timeout() -> void:
	_join_token += 1
	var token: int = _join_token
	yield(get_tree().create_timer(JOIN_TIMEOUT_SEC), "timeout")
	if token != _join_token:
		return  # superseded: we already connected, failed, or left
	if is_connecting and not is_connected:
		_fail_join("No host responded at that address — it may not exist or isn't reachable. Check the IP and that the host pressed Host.")


func _fail_join(reason: String) -> void:
	_join_token += 1  # invalidate any pending timeout
	is_connecting = false
	is_connected = false
	is_game_started = false
	if peer:
		peer.close_connection()
		peer = null
	get_tree().network_peer = null
	connected_players.clear()
	player_names.clear()
	emit_signal("connection_failed", reason)


func _on_connected_to_server() -> void:
	if not is_connecting:
		return
	_join_token += 1  # invalidate the pending timeout — we made it
	is_connecting = false
	is_connected = true
	is_game_started = false
	my_id = get_tree().get_network_unique_id()
	if connected_players.find(my_id) == -1:
		connected_players.append(my_id)
	player_names[my_id] = player_name
	# Tell the host our name (in case we don't also get a network_peer_connected for id 1).
	rpc_id(1, "_receive_player_name", my_id, player_name)

	var fs := _find_file_system()
	if fs and fs.has_method("new_file"):
		fs.new_file()

	emit_status("Connected! Waiting for host to start...")


func _on_connection_failed_to_server() -> void:
	if not is_connecting:
		return  # already resolved (e.g. timed out) — don't double-report
	_fail_join("Couldn't reach that address — the host isn't resolving or isn't reachable.")


# === Leave/Disconnect ===

func leave_game():
	_join_token += 1  # cancel any in-flight join timeout
	if peer:
		peer.close_connection()
		peer = null
	
	connected_players.clear()
	is_host = false
	is_connected = false
	is_connecting = false
	is_game_started = false
	my_id = 0
	player_names.clear()
	
	get_tree().network_peer = null


# === Network Signals ===

func _on_network_peer_connected(id: int):
	emit_status("Player: " + str(id) + " joined")
	if connected_players.find(id) == -1:
		connected_players.append(id)
	# Introduce ourselves to the peer that just connected so their roster shows our name
	# (both ends run this on the mutual connect, so names flow both ways).
	rpc_id(id, "_receive_player_name", my_id, player_name)
	emit_signal("player_connected", id)


func _on_network_peer_disconnected(id: int):
	emit_status("Player: " + str(id) + " left")
	connected_players.erase(id)
	player_names.erase(id)
	emit_signal("player_disconnected", id)


func _on_server_disconnected():
	emit_status("Disconnected")
	leave_game()
	emit_signal("server_disconnected")


# === Start Game ===

func start_game():
	print("[MP] start_game called, is_host: ", is_host)
	emit_status("Starting game...")
	if is_host:
		is_game_started = true
		emit_signal("game_started")
		emit_status("Game started!  You can now collaborate on the circuit.")
		# Broadcast game start to all clients (but don't reload scene)
		rpc("on_game_started")


remote func on_game_started():
	print("[MP] on_game_started called!")
	emit_status("Game started! You can now collaborate on the circuit.")
	is_connected = true  # Ensure we stay connected
	is_game_started = true
	emit_signal("game_started")


remote func on_mode_change_requested(is_simulation_requested: bool):
	_is_applying_remote_mode_change = true
	E.emit_signal("mi_mode_change_requested", is_simulation_requested)
	_is_applying_remote_mode_change = false
