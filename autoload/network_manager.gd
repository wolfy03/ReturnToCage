extends Node

signal hosting_started
signal connected_to_server
signal connection_failed
signal server_disconnected
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal session_synchronized
signal peer_world_ready(peer_id: int)
signal multiplayer_session_ended(reason: String)

enum ConnectionState { OFFLINE, HOSTING, CONNECTING, CONNECTED }

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const NETWORK_PROTOCOL_VERSION := NetworkProtocol.VERSION
const END_REASON_MANUAL := "manual_leave"
const END_REASON_CONNECTION_FAILED := "connection_failed"
const END_REASON_SERVER_DISCONNECTED := "server_disconnected"
const PROFILE_PATH_ARGUMENT := "--local-profile-path="

var state: ConnectionState = ConnectionState.OFFLINE
var last_error: String = ""
var players: Dictionary[int, NetworkPlayerInfo] = {}
var peer_to_player: Dictionary[int, StringName] = {}
var player_to_peer: Dictionary[StringName, int] = {}
var world_ready_peers: Dictionary[int, bool] = {}
var _peer: ENetMultiplayerPeer
var _local_peer_id: int = 1
var _session_entered: bool = false
var _local_profile: LocalPlayerProfile

func _ready() -> void:
	_ensure_local_profile()
	multiplayer.peer_connected.connect(_on_transport_peer_connected)
	multiplayer.peer_disconnected.connect(_on_transport_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS) -> Error:
	_reset_transport()
	if port < 1 or port > 65535 or max_players < 2 or max_players > MAX_PLAYERS:
		last_error = "Invalid host port or player limit"
		return ERR_INVALID_PARAMETER
	var profile_error := _ensure_local_profile()
	if profile_error != OK:
		return profile_error
	_peer = ENetMultiplayerPeer.new()
	var result := _peer.create_server(port, max_players - 1)
	if result != OK:
		last_error = "Cannot host on port %d: %s" % [port, error_string(result)]
		_peer = null
		return result
	multiplayer.multiplayer_peer = _peer
	state = ConnectionState.HOSTING
	_local_peer_id = 1
	_session_entered = true
	var host_player_id := local_profile_player_id()
	if not _set_identity(1, host_player_id):
		last_error = "Cannot attach the host local player profile"
		_reset_transport()
		return ERR_INVALID_DATA
	players[1] = NetworkPlayerInfo.new(1, host_player_id, local_profile_display_name(), true)
	world_ready_peers[1] = true
	last_error = ""
	print("[NET] Hosting on port %d" % port)
	hosting_started.emit()
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	_reset_transport()
	var target := address.strip_edges()
	if target.is_empty() or port < 1 or port > 65535:
		last_error = "Invalid server address or port"
		return ERR_INVALID_PARAMETER
	var profile_error := _ensure_local_profile()
	if profile_error != OK:
		return profile_error
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
	_finish_network_session(END_REASON_MANUAL)
	last_error = ""

func is_server() -> bool:
	return state == ConnectionState.HOSTING and multiplayer.is_server()

func is_session_connected() -> bool:
	return state in [ConnectionState.HOSTING, ConnectionState.CONNECTED]

func is_multiplayer_active() -> bool:
	return state != ConnectionState.OFFLINE

func is_authoritative_simulation() -> bool:
	return state == ConnectionState.OFFLINE or is_server()

func local_peer_id() -> int:
	return _local_peer_id

func has_peer(peer_id: int) -> bool:
	return players.has(peer_id)

func player_id_for_peer(peer_id: int) -> StringName:
	return peer_to_player.get(peer_id, &"")

func peer_id_for_player(player_id: StringName) -> int:
	return player_to_peer.get(player_id, 0)

func has_player_id(player_id: StringName) -> bool:
	return not player_id.is_empty() and player_to_peer.has(player_id)

func local_profile_player_id() -> StringName:
	return _local_profile.get_player_id() if _local_profile != null and _local_profile.is_valid() else &""

func local_profile_display_name() -> String:
	return _local_profile.get_display_name() if _local_profile != null and _local_profile.is_valid() else ""

func has_valid_local_profile() -> bool:
	return _local_profile != null and _local_profile.is_valid()

func _set_identity(peer_id: int, player_id: StringName) -> bool:
	if peer_id <= 0 or not LocalPlayerProfile.is_valid_player_id(player_id) \
			or peer_to_player.has(peer_id) or player_to_peer.has(player_id):
		return false
	peer_to_player[peer_id] = player_id
	player_to_peer[player_id] = peer_id
	return true

func _remove_identity(peer_id: int) -> void:
	var player_id := player_id_for_peer(peer_id)
	peer_to_player.erase(peer_id)
	if not player_id.is_empty() and player_to_peer.get(player_id, 0) == peer_id:
		player_to_peer.erase(player_id)

func can_send_to_peer(peer_id: int) -> bool:
	if not is_server() or _peer == null or not multiplayer.get_peers().has(peer_id):
		return false
	var packet_peer := _peer.get_peer(peer_id)
	return packet_peer != null and packet_peer.is_active() and packet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED

func mark_peer_world_ready(peer_id: int) -> void:
	if is_server() and players.has(peer_id) and not world_ready_peers.has(peer_id):
		world_ready_peers[peer_id] = true
		peer_world_ready.emit(peer_id)

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
		GameSession.detach_player(peer_id)
		_remove_identity(peer_id)
		for remaining_peer_id in multiplayer.get_peers():
			if can_send_to_peer(remaining_peer_id):
				_client_remove_peer.rpc_id(remaining_peer_id, peer_id)
		print("[NET] Disconnected peer %d" % peer_id)
		peer_left.emit(peer_id)

func _on_connected_to_server() -> void:
	state = ConnectionState.CONNECTED
	_local_peer_id = multiplayer.get_unique_id()
	print("[NET] Joined server; validating protocol")
	connected_to_server.emit()
	if not has_valid_local_profile():
		last_error = "Persistent local player profile is unavailable"
		_finish_network_session(END_REASON_CONNECTION_FAILED)
		connection_failed.emit()
		return
	_request_handshake.rpc_id(1, NETWORK_PROTOCOL_VERSION, local_profile_player_id(), local_profile_display_name())

func _on_connection_failed() -> void:
	last_error = "Connection failed"
	_finish_network_session(END_REASON_CONNECTION_FAILED)
	print("[NET] Connection failed")
	connection_failed.emit()

func _on_server_disconnected() -> void:
	last_error = "Server disconnected"
	_finish_network_session(END_REASON_SERVER_DISCONNECTED)
	print("[NET] Server disconnected")
	server_disconnected.emit()

func _finish_network_session(reason: String) -> void:
	var notify_session_end := _session_entered
	_reset_transport()
	if notify_session_end:
		multiplayer_session_ended.emit(reason)

func _reset_transport() -> void:
	var previous_local_peer_id := local_peer_id()
	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	state = ConnectionState.OFFLINE
	_local_peer_id = 1
	_session_entered = false
	players.clear()
	peer_to_player.clear()
	player_to_peer.clear()
	world_ready_peers.clear()
	GameSession.reset_to_offline_local_player(previous_local_peer_id)

@rpc("any_peer", "call_remote", "reliable")
func _request_handshake(protocol_version: int, player_id: StringName, display_name: String) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or protocol_version != NETWORK_PROTOCOL_VERSION:
		_reject_remote_handshake(sender, "Incompatible multiplayer protocol version")
		print("[NET] Protocol mismatch for peer %d" % sender)
		return
	if players.has(sender):
		return
	var identity_error := _handshake_identity_error(sender, player_id)
	if not identity_error.is_empty():
		_reject_remote_handshake(sender, identity_error)
		return
	var safe_name := display_name.strip_edges().left(24)
	if not _set_identity(sender, player_id):
		_reject_remote_handshake(sender, "Cannot attach persistent player identity")
		return
	players[sender] = NetworkPlayerInfo.new(sender, player_id, safe_name if not safe_name.is_empty() else "Player", true)
	# Existing clients must register the peer before PlayerSpawnManager reacts to
	# the domain attachment and sends that actor's spawn RPC.
	_client_add_peer.rpc(sender, player_id, players[sender].display_name)
	var attached_state := GameSession.attach_player(sender, player_id)
	if attached_state == null:
		players.erase(sender)
		_client_remove_peer.rpc(sender)
		_remove_identity(sender)
		_reject_remote_handshake(sender, "Cannot attach persistent player state")
		return
	_receive_session_snapshot.rpc_id(sender, GameSession.to_network_snapshot(NETWORK_PROTOCOL_VERSION))
	print("[NET] Connected peer %d" % sender)
	peer_joined.emit(sender)

func _reject_remote_handshake(peer_id: int, message: String) -> void:
	if peer_id <= 1 or _peer == null:
		return
	if can_send_to_peer(peer_id):
		_reject_handshake.rpc_id(peer_id, message)
	_peer.disconnect_peer(peer_id)

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
	if not _snapshot_matches_local_profile(snapshot):
		leave_game()
		last_error = "Server returned a different local player identity"
		connection_failed.emit()
		return
	peer_to_player.clear()
	player_to_peer.clear()
	for identity in snapshot.identities:
		if not _set_identity(identity.peer_id, identity.player_id):
			leave_game()
			last_error = "Invalid multiplayer identity mapping"
			connection_failed.emit()
			return
	if not GameSession.apply_network_snapshot(snapshot):
		leave_game()
		last_error = "Invalid multiplayer session snapshot"
		connection_failed.emit()
		return
	players.clear()
	for identity in snapshot.identities:
		players[identity.peer_id] = NetworkPlayerInfo.new(identity.peer_id, identity.player_id, "Host" if identity.peer_id == 1 else "Player", true)
	_session_entered = true
	print("[NET] Session synchronized with %d players" % players.size())
	session_synchronized.emit()

@rpc("authority", "call_remote", "reliable")
func _client_add_peer(peer_id: int, player_id: StringName, display_name: String) -> void:
	if peer_id <= 0 or players.has(peer_id):
		return
	if not _set_identity(peer_id, player_id):
		return
	if GameSession.attach_player(peer_id, player_id) == null:
		_remove_identity(peer_id)
		return
	players[peer_id] = NetworkPlayerInfo.new(peer_id, player_id, display_name, true)
	peer_joined.emit(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_remove_peer(peer_id: int) -> void:
	var player_id := player_id_for_peer(peer_id)
	if players.erase(peer_id):
		GameSession.detach_player(peer_id)
		# A client owns no reconnect-authoritative private state for remote players.
		# The server retains its canonical state; clients discard this placeholder.
		if peer_id != local_peer_id() and not player_id.is_empty():
			GameSession.remove_player_state(player_id)
		_remove_identity(peer_id)
		peer_left.emit(peer_id)

func _ensure_local_profile() -> Error:
	if _local_profile != null and _local_profile.is_valid():
		return OK
	_local_profile = LocalPlayerProfile.new(_profile_path_from_arguments())
	var result := _local_profile.load_or_create()
	if result != OK:
		last_error = _local_profile.last_error
	return result

func _profile_path_from_arguments() -> String:
	# Development/test override for running multiple local ENet processes with
	# distinct installation identities. Production uses the user:// profile.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(PROFILE_PATH_ARGUMENT):
			var path := argument.trim_prefix(PROFILE_PATH_ARGUMENT).strip_edges()
			if not path.is_empty():
				return path
	return LocalPlayerProfile.DEFAULT_PATH

func _snapshot_matches_local_profile(snapshot: NetworkSessionSnapshot) -> bool:
	if snapshot == null or not has_valid_local_profile():
		return false
	for identity in snapshot.identities:
		if identity.peer_id == local_peer_id():
			return identity.player_id == local_profile_player_id()
	return false

func _handshake_identity_error(sender: int, player_id: StringName) -> String:
	if sender <= 1:
		return "Invalid handshake sender"
	if not LocalPlayerProfile.is_valid_player_id(player_id):
		return "Invalid persistent player identity"
	var active_peer: int = player_to_peer.get(player_id, 0)
	if active_peer > 0 and active_peer != sender:
		return "Player identity is already connected"
	return ""
