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

enum ConnectionState { OFFLINE, HOSTING_RESTORING, HOSTING, CONNECTING, CONNECTED }

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
var _received_session_snapshot: bool = false
var _received_private_player_state: bool = false
var _received_spawn_assignment: bool = false
var _accepting_handshakes: bool = false
var _pending_host_port: int = 0
var _returning_peers: Dictionary[int, bool] = {}
var _spawn_assignments: Dictionary[int, PlayerSpawnAssignment] = {}
# Narrow one-shot debug seam for deterministic bind-failure lifecycle tests.
var _host_transport_error_for_test: Error = OK
var _local_profile: LocalPlayerProfile

func _ready() -> void:
	_ensure_local_profile()
	multiplayer.peer_connected.connect(_on_transport_peer_connected)
	multiplayer.peer_disconnected.connect(_on_transport_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS) -> Error:
	if port < 1 or port > 65535 or max_players < 2 or max_players > MAX_PLAYERS:
		last_error = "Invalid host port or player limit"
		return ERR_INVALID_PARAMETER
	var profile_error := _ensure_local_profile()
	if profile_error != OK:
		return profile_error
	if not is_local_identity_activated():
		last_error = "Local player identity is not activated"
		return ERR_UNCONFIGURED
	_reset_transport()
	var result := _open_host_transport(port, max_players)
	if result != OK:
		return result
	result = _finalize_host_session(false)
	if result != OK:
		_reset_transport()
	return result

# Saved hosting opens a real ENet server while protocol handshakes remain
# disabled. The caller must apply its already-staged SessionSnapshot and then
# call finalize_host_restore(). This function never mutates GameSession.
func begin_host_restore(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS) -> Error:
	if state != ConnectionState.OFFLINE:
		last_error = "Cannot restore a hosted session while networking is active"
		return ERR_ALREADY_IN_USE
	if port < 1 or port > 65535 or max_players < 2 or max_players > MAX_PLAYERS:
		last_error = "Invalid host port or player limit"
		return ERR_INVALID_PARAMETER
	var profile_error := _ensure_local_profile()
	if profile_error != OK:
		return profile_error
	if not is_local_identity_activated():
		last_error = "Local player identity is not activated"
		return ERR_UNCONFIGURED
	_reset_transport_only()
	return _open_host_transport(port, max_players)

func finalize_host_restore() -> Error:
	return _finalize_host_session(true)

func abort_host_restore() -> void:
	if state == ConnectionState.HOSTING_RESTORING:
		_reset_transport_only()

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	var target := address.strip_edges()
	if target.is_empty() or port < 1 or port > 65535:
		last_error = "Invalid server address or port"
		return ERR_INVALID_PARAMETER
	var profile_error := _ensure_local_profile()
	if profile_error != OK:
		return profile_error
	if not is_local_identity_activated():
		last_error = "Local player identity is not activated"
		return ERR_UNCONFIGURED
	_reset_transport()
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
	# Transport role only. A restoring host owns the ENet server but is not yet
	# allowed to run authoritative gameplay simulation.
	return state in [ConnectionState.HOSTING_RESTORING, ConnectionState.HOSTING] and multiplayer.is_server()

func is_session_connected() -> bool:
	return state in [ConnectionState.HOSTING, ConnectionState.CONNECTED]

func is_multiplayer_active() -> bool:
	return state != ConnectionState.OFFLINE

func is_authoritative_simulation() -> bool:
	# Gameplay mutation authority starts only at completed host finalization.
	return state == ConnectionState.OFFLINE or is_host_session_ready()

func is_host_session_ready() -> bool:
	return state == ConnectionState.HOSTING and multiplayer.is_server() \
			and _accepting_handshakes and _session_entered

func is_host_restoring() -> bool:
	return state == ConnectionState.HOSTING_RESTORING

func is_accepting_handshakes() -> bool:
	return is_server() and _accepting_handshakes

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

func is_returning_peer(peer_id: int) -> bool:
	return bool(_returning_peers.get(peer_id, false))

func register_authoritative_spawn_assignment(peer_id: int, assignment: PlayerSpawnAssignment) -> bool:
	if not is_authoritative_simulation() or assignment == null or not assignment.error_message.is_empty() \
			or not players.has(peer_id) or not GameSession.has_player(peer_id) \
			or assignment.player_id != player_id_for_peer(peer_id) \
			or assignment.session_id != GameSession.session_id:
		return false
	_spawn_assignments[peer_id] = assignment
	return true

func spawn_assignment_for_peer(peer_id: int) -> PlayerSpawnAssignment:
	return _spawn_assignments.get(peer_id)

func consume_local_spawn_assignment() -> PlayerSpawnAssignment:
	if is_server() or not _session_entered:
		return null
	var result: PlayerSpawnAssignment = _spawn_assignments.get(local_peer_id())
	_spawn_assignments.erase(local_peer_id())
	return result

func local_profile_player_id() -> StringName:
	return _local_profile.get_player_id() if _local_profile != null and _local_profile.is_valid() else &""

func local_profile_display_name() -> String:
	return _local_profile.get_display_name() if _local_profile != null and _local_profile.is_valid() else ""

func has_valid_local_profile() -> bool:
	return _local_profile != null and _local_profile.is_valid()

func local_profile_load_status() -> int:
	return _local_profile.load_status if _local_profile != null else LocalPlayerProfile.LoadStatus.NONE

func is_local_identity_activated() -> bool:
	return has_valid_local_profile() and GameSession.get_local_player() != null \
		and GameSession.get_local_player_id() == local_profile_player_id()

func commit_local_profile_identity(
	player_id: StringName,
	display_name: String = "Player"
) -> CommandResult:
	if _local_profile == null:
		return CommandResult.make(false, "Local player profile is unavailable")
	if _local_profile.load_status != LocalPlayerProfile.LoadStatus.IDENTITY_RECOVERY_REQUIRED:
		return CommandResult.make(false, "Local profile is not awaiting identity recovery")
	if not LocalPlayerProfile.is_valid_player_id(player_id):
		return CommandResult.make(false, "Invalid local player identity")
	var commit_error := _local_profile.commit_identity(player_id, display_name)
	if commit_error != OK:
		last_error = _local_profile.last_error
		return CommandResult.make(false, "Profile identity commit failed: %s" % last_error)
	last_error = ""
	return CommandResult.make(true, "Local player identity recovered")

func create_new_local_identity(display_name: String = "Player") -> CommandResult:
	if _local_profile == null:
		return CommandResult.make(false, "Local player profile is unavailable")
	if _local_profile.load_status != LocalPlayerProfile.LoadStatus.IDENTITY_RECOVERY_REQUIRED:
		return CommandResult.make(false, "Local profile is not awaiting identity recovery")
	var create_error := _local_profile.create_new_identity(display_name)
	if create_error != OK:
		last_error = _local_profile.last_error
		return CommandResult.make(false, "New profile identity creation failed: %s" % last_error)
	last_error = ""
	return CommandResult.make(true, "New local player identity created")

# Narrow debug-test seam: production callers use the read-only queries above
# and commit_local_profile_identity(), never a mutable profile object.
func _load_local_profile_for_test(path: String, failure_hook: Callable = Callable()) -> Error:
	if not OS.is_debug_build():
		return ERR_UNAUTHORIZED
	_local_profile = LocalPlayerProfile.new(path, failure_hook)
	var result := _local_profile.load_or_create()
	last_error = _local_profile.last_error if result != OK else ""
	return result

func _restore_local_profile_after_test() -> Error:
	if not OS.is_debug_build():
		return ERR_UNAUTHORIZED
	_local_profile = null
	return _ensure_local_profile()

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
	var was_active := players.has(peer_id) or peer_to_player.has(peer_id) or GameSession.has_player(peer_id)
	if GameSession.has_player(peer_id):
		GameSession.detach_player(peer_id)
	players.erase(peer_id)
	world_ready_peers.erase(peer_id)
	_spawn_assignments.erase(peer_id)
	_returning_peers.erase(peer_id)
	_remove_identity(peer_id)
	if was_active:
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
	_reset_transport_only()
	GameSession.reset_to_offline_local_player(previous_local_peer_id)

func _reset_transport_only() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	state = ConnectionState.OFFLINE
	_local_peer_id = 1
	_session_entered = false
	_received_session_snapshot = false
	_received_private_player_state = false
	_received_spawn_assignment = false
	_accepting_handshakes = false
	_pending_host_port = 0
	players.clear()
	peer_to_player.clear()
	player_to_peer.clear()
	world_ready_peers.clear()
	_returning_peers.clear()
	_spawn_assignments.clear()

func _open_host_transport(port: int, max_players: int) -> Error:
	_accepting_handshakes = false
	if OS.is_debug_build() and _host_transport_error_for_test != OK:
		var injected_error := _host_transport_error_for_test
		_host_transport_error_for_test = OK
		last_error = "Cannot host on port %d: %s" % [port, error_string(injected_error)]
		return injected_error
	_peer = ENetMultiplayerPeer.new()
	var result := _peer.create_server(port, max_players - 1)
	if result != OK:
		last_error = "Cannot host on port %d: %s" % [port, error_string(result)]
		_peer = null
		return result
	multiplayer.multiplayer_peer = _peer
	state = ConnectionState.HOSTING_RESTORING
	_local_peer_id = 1
	_session_entered = false
	_pending_host_port = port
	return OK

func _finalize_host_session(require_restored_session: bool) -> Error:
	if state != ConnectionState.HOSTING_RESTORING or _peer == null or not multiplayer.is_server():
		last_error = "Host transport is not awaiting session finalization"
		return ERR_UNCONFIGURED
	var host_player_id := local_profile_player_id()
	if GameSession.get_local_player() == null or GameSession.get_local_player_id() != host_player_id:
		last_error = "Cannot attach the host local player profile"
		return ERR_INVALID_DATA
	if require_restored_session and (GameSession.phase != GameSession.Phase.SETTLEMENT \
			or GameSession.session_id.is_empty() or GameSession.players.size() != 1):
		last_error = "Restored host session is not ready"
		return ERR_INVALID_DATA
	if not players.is_empty() or not peer_to_player.is_empty() or not player_to_peer.is_empty() \
			or not world_ready_peers.is_empty() or not _set_identity(1, host_player_id):
		last_error = "Cannot initialize the host network roster"
		return ERR_INVALID_DATA
	players[1] = NetworkPlayerInfo.new(1, host_player_id, local_profile_display_name(), true)
	world_ready_peers[1] = true
	_returning_peers[1] = require_restored_session
	_accepting_handshakes = true
	state = ConnectionState.HOSTING
	_session_entered = true
	last_error = ""
	print("[NET] Hosting on port %d" % _pending_host_port)
	_pending_host_port = 0
	hosting_started.emit()
	return OK

@rpc("any_peer", "call_remote", "reliable")
func _request_handshake(protocol_version: int, player_id: StringName, display_name: String) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accepting_handshakes:
		_reject_remote_handshake(sender, "Server is restoring session")
		return
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
	var was_persistent := GameSession.has_persistent_player(player_id)
	if not _set_identity(sender, player_id):
		_reject_remote_handshake(sender, "Cannot attach persistent player identity")
		return
	players[sender] = NetworkPlayerInfo.new(sender, player_id, safe_name if not safe_name.is_empty() else "Player", true)
	_returning_peers[sender] = was_persistent
	# Existing clients must register the peer before PlayerSpawnManager reacts to
	# the domain attachment and sends that actor's spawn RPC.
	_client_add_peer.rpc(sender, player_id, players[sender].display_name)
	var attached_state := GameSession.attach_player(sender, player_id)
	if attached_state == null:
		_rollback_peer_attachment(sender, player_id, was_persistent)
		_reject_remote_handshake(sender, "Cannot attach persistent player state")
		return
	# Resolve the owner from the accepted sender mapping. Clients never request
	# another identity's private state and this payload is never broadcast.
	var private_snapshot := GameSession.make_player_private_snapshot(sender)
	if private_snapshot == null or not private_snapshot.error_message.is_empty():
		_rollback_peer_attachment(sender, player_id, was_persistent)
		_reject_remote_handshake(sender, "Cannot build owner-private player state")
		return
	var spawn_assignment := spawn_assignment_for_peer(sender)
	if spawn_assignment == null or not spawn_assignment.error_message.is_empty():
		_rollback_peer_attachment(sender, player_id, was_persistent)
		_reject_remote_handshake(sender, "Cannot build authoritative spawn assignment")
		return
	_receive_session_snapshot.rpc_id(sender, GameSession.to_network_snapshot(NETWORK_PROTOCOL_VERSION))
	_receive_private_player_state.rpc_id(sender, private_snapshot.to_payload())
	_receive_spawn_assignment.rpc_id(sender, spawn_assignment.to_payload())
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
	if _received_session_snapshot or _session_entered:
		return
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
	_received_session_snapshot = true
	_try_complete_client_sync()

@rpc("authority", "call_remote", "reliable")
func _receive_private_player_state(payload: Dictionary) -> void:
	if is_server() or _received_private_player_state or _session_entered:
		return
	if not _received_session_snapshot:
		_fail_client_sync("Owner-private player state arrived before the session snapshot")
		return
	var local_player_id := local_profile_player_id()
	if local_player_id.is_empty() or GameSession.get_local_player_id() != local_player_id:
		_fail_client_sync("Owner-private player identity is not attached")
		return
	var snapshot := PlayerPrivateStateSnapshot.from_payload(
		payload, ContentRegistry, GameSession.get_start_definition(), local_player_id
	)
	if not snapshot.error_message.is_empty() or not GameSession.apply_player_private_network_snapshot(snapshot):
		var message := snapshot.error_message if not snapshot.error_message.is_empty() \
				else "Cannot apply owner-private player state"
		_fail_client_sync(message)
		return
	_received_private_player_state = true
	_try_complete_client_sync()

@rpc("authority", "call_remote", "reliable")
func _receive_spawn_assignment(payload: Dictionary) -> void:
	if is_server() or _received_spawn_assignment or _session_entered:
		return
	if not _received_session_snapshot or not _received_private_player_state:
		_fail_client_sync("Spawn assignment arrived before private state synchronization")
		return
	var local_player_id := local_profile_player_id()
	var assignment := PlayerSpawnAssignment.from_payload(payload, GameSession.session_id, local_player_id)
	if not assignment.error_message.is_empty() or GameSession.get_local_player_id() != assignment.player_id:
		_fail_client_sync(
			assignment.error_message if not assignment.error_message.is_empty() \
			else "Authoritative spawn assignment owner mismatch"
		)
		return
	_spawn_assignments[local_peer_id()] = assignment
	_received_spawn_assignment = true
	_try_complete_client_sync()

func _try_complete_client_sync() -> void:
	if _session_entered or not _received_session_snapshot or not _received_private_player_state \
			or not _received_spawn_assignment:
		return
	_session_entered = true
	print("[NET] Session synchronized with %d players" % players.size())
	session_synchronized.emit()

func _fail_client_sync(message: String) -> void:
	leave_game()
	last_error = message
	print("[NET] Client synchronization failed: %s" % message)
	connection_failed.emit()

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
	var was_active := players.has(peer_id) or peer_to_player.has(peer_id) or GameSession.has_player(peer_id)
	if GameSession.has_player(peer_id):
		GameSession.detach_player(peer_id)
	# A client owns no reconnect-authoritative private state for remote players.
	# The server retains its canonical state; clients discard this placeholder.
	if peer_id != local_peer_id() and not player_id.is_empty():
		GameSession.remove_player_state(player_id)
	players.erase(peer_id)
	_remove_identity(peer_id)
	_spawn_assignments.erase(peer_id)
	_returning_peers.erase(peer_id)
	if was_active:
		peer_left.emit(peer_id)

func _rollback_peer_attachment(
	peer_id: int,
	player_id: StringName,
	was_persistent: bool,
	notify_clients: bool = true
) -> void:
	# Network/scene attachment is transactional. A returning canonical state is
	# detached and retained; a newly-created state is removed on preparation
	# failure so a rejected handshake cannot leave a ghost persistent player.
	if GameSession.has_player(peer_id):
		GameSession.detach_player(peer_id)
	if not was_persistent and GameSession.has_persistent_player(player_id):
		GameSession.remove_player_state(player_id)
	players.erase(peer_id)
	world_ready_peers.erase(peer_id)
	_spawn_assignments.erase(peer_id)
	_returning_peers.erase(peer_id)
	_remove_identity(peer_id)
	if notify_clients and is_server():
		_client_remove_peer.rpc(peer_id)

func _ensure_local_profile() -> Error:
	if _local_profile != null:
		if _local_profile.is_valid():
			return OK
		# Preserve recovery evidence and the configured path. Reconstructing an
		# unresolved profile here could bypass a startup gate or test override.
		last_error = _local_profile.last_error
		return ERR_INVALID_DATA
	_local_profile = LocalPlayerProfile.new(_profile_path_from_arguments())
	var result := _local_profile.load_or_create()
	if result != OK:
		last_error = _local_profile.last_error
	else:
		last_error = ""
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
