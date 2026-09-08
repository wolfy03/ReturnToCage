extends Node

signal hosting_started
signal connected_to_server
signal connection_failed
signal server_disconnected
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal session_synchronized

enum ConnectionState { OFFLINE, HOSTING, CONNECTING, CONNECTED }

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const NETWORK_PROTOCOL_VERSION := NetworkProtocol.VERSION

var state: ConnectionState = ConnectionState.OFFLINE
var last_error: String = ""
var players: Dictionary[int, NetworkPlayerInfo] = {}
var world_ready_peers: Dictionary[int, bool] = {}
var _peer: ENetMultiplayerPeer

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_transport_peer_connected)
	multiplayer.peer_disconnected.connect(_on_transport_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS) -> Error:
	leave_game()
	if port < 1 or port > 65535 or max_players < 2 or max_players > MAX_PLAYERS:
		last_error = "Invalid host port or player limit"
		return ERR_INVALID_PARAMETER
	_peer = ENetMultiplayerPeer.new()
	var result := _peer.create_server(port, max_players - 1)
	if result != OK:
		last_error = "Cannot host on port %d: %s" % [port, error_string(result)]
		_peer = null
		return result
	multiplayer.multiplayer_peer = _peer
	state = ConnectionState.HOSTING
	players[1] = NetworkPlayerInfo.new(1, "Host", true)
	world_ready_peers[1] = true
	last_error = ""
	print("[NET] Hosting on port %d" % port)
	hosting_started.emit()
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	leave_game()
	var target := address.strip_edges()
	if target.is_empty() or port < 1 or port > 65535:
		last_error = "Invalid server address or port"
		return ERR_INVALID_PARAMETER
	_peer = ENetMultiplayerPeer.new()
	var result := _peer.create_client(target, port)
	if result != OK:
		last_error = "Cannot connect to %s:%d: %s" % [target, port, error_string(result)]
		_peer = null
		return result
	multiplayer.multiplayer_peer = _peer
	state = ConnectionState.CONNECTING
	last_error = ""
	print("[NET] Connecting to %s:%d" % [target, port])
	return OK

func leave_game() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	state = ConnectionState.OFFLINE
	players.clear()
	world_ready_peers.clear()
	last_error = ""

func is_server() -> bool:
	return state != ConnectionState.OFFLINE and multiplayer.is_server()

func is_session_connected() -> bool:
	return state in [ConnectionState.HOSTING, ConnectionState.CONNECTED]

func is_multiplayer_active() -> bool:
	return state != ConnectionState.OFFLINE

func is_authoritative_simulation() -> bool:
	return state == ConnectionState.OFFLINE or is_server()

func local_peer_id() -> int:
	return multiplayer.get_unique_id() if state != ConnectionState.OFFLINE else 1

func has_peer(peer_id: int) -> bool:
	return players.has(peer_id)

func can_send_to_peer(peer_id: int) -> bool:
	if not is_server() or _peer == null or not multiplayer.get_peers().has(peer_id):
		return false
	var packet_peer := _peer.get_peer(peer_id)
	return packet_peer != null and packet_peer.is_active() and packet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED

func mark_peer_world_ready(peer_id: int) -> void:
	if is_server() and players.has(peer_id):
		world_ready_peers[peer_id] = true

func begin_world_sync() -> void:
	if is_server():
		world_ready_peers.clear()
		world_ready_peers[1] = true

func ready_remote_peer_ids() -> Array[int]:
	var result: Array[int] = []
	for peer_id in world_ready_peers:
		if peer_id != 1 and players.has(peer_id):
			result.append(peer_id)
	return result

func _on_transport_peer_connected(peer_id: int) -> void:
	if is_server():
		print("[NET] Transport connected peer %d; awaiting protocol handshake" % peer_id)

func _on_transport_peer_disconnected(peer_id: int) -> void:
	if not is_server():
		return
	if players.erase(peer_id):
		world_ready_peers.erase(peer_id)
		GameSession.unregister_player(peer_id)
		for remaining_peer_id in multiplayer.get_peers():
			if can_send_to_peer(remaining_peer_id):
				_client_remove_peer.rpc_id(remaining_peer_id, peer_id)
		print("[NET] Disconnected peer %d" % peer_id)
		peer_left.emit(peer_id)

func _on_connected_to_server() -> void:
	state = ConnectionState.CONNECTED
	print("[NET] Joined server; validating protocol")
	connected_to_server.emit()
	_request_handshake.rpc_id(1, NETWORK_PROTOCOL_VERSION, "Player")

func _on_connection_failed() -> void:
	last_error = "Connection failed"
	_reset_transport()
	print("[NET] Connection failed")
	connection_failed.emit()

func _on_server_disconnected() -> void:
	last_error = "Server disconnected"
	_reset_transport()
	print("[NET] Server disconnected")
	server_disconnected.emit()

func _reset_transport() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	state = ConnectionState.OFFLINE
	players.clear()
	world_ready_peers.clear()

@rpc("any_peer", "call_remote", "reliable")
func _request_handshake(protocol_version: int, display_name: String) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or protocol_version != NETWORK_PROTOCOL_VERSION:
		_reject_handshake.rpc_id(sender, "Incompatible multiplayer protocol version")
		print("[NET] Protocol mismatch for peer %d" % sender)
		_peer.disconnect_peer(sender)
		return
	if players.has(sender):
		return
	var safe_name := display_name.strip_edges().left(24)
	players[sender] = NetworkPlayerInfo.new(sender, safe_name if not safe_name.is_empty() else "Player", true)
	_client_add_peer.rpc(sender, players[sender].display_name)
	GameSession.register_player(sender)
	_receive_session_snapshot.rpc_id(sender, GameSession.to_network_snapshot(NETWORK_PROTOCOL_VERSION))
	print("[NET] Connected peer %d" % sender)
	peer_joined.emit(sender)

@rpc("authority", "call_remote", "reliable")
func _reject_handshake(message: String) -> void:
	print("[NET] %s" % message)
	leave_game()
	last_error = message
	connection_failed.emit()

@rpc("authority", "call_remote", "reliable")
func _receive_session_snapshot(payload: Dictionary) -> void:
	var snapshot := NetworkSessionSnapshot.from_payload(payload, NETWORK_PROTOCOL_VERSION, MAX_PLAYERS)
	if not snapshot.error_message.is_empty() or not snapshot.player_ids.has(local_peer_id()):
		var message := snapshot.error_message if not snapshot.error_message.is_empty() else "Server omitted the local player"
		leave_game()
		last_error = message
		connection_failed.emit()
		return
	if not GameSession.apply_network_snapshot(snapshot):
		leave_game()
		last_error = "Invalid multiplayer session snapshot"
		connection_failed.emit()
		return
	players.clear()
	for peer_id in snapshot.player_ids:
		players[peer_id] = NetworkPlayerInfo.new(peer_id, "Host" if peer_id == 1 else "Player", true)
	print("[NET] Session synchronized with %d players" % players.size())
	session_synchronized.emit()

@rpc("authority", "call_remote", "reliable")
func _client_add_peer(peer_id: int, display_name: String) -> void:
	if peer_id <= 0 or players.has(peer_id):
		return
	players[peer_id] = NetworkPlayerInfo.new(peer_id, display_name, true)
	GameSession.register_player(peer_id)
	peer_joined.emit(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_remove_peer(peer_id: int) -> void:
	if players.erase(peer_id):
		GameSession.unregister_player(peer_id)
		peer_left.emit(peer_id)
