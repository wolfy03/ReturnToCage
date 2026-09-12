extends Node

signal hosting_started
signal connected_to_server
signal connection_failed
signal server_disconnected
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal session_synchronized
signal peer_world_ready(peer_id: int)
signal local_world_assignment_received(assignment: PlayerWorldAssignment)
signal world_roster_player_received(peer_id: int, assignment: PlayerWorldAssignment, position: Vector2)
signal world_roster_player_removed(peer_id: int)
signal local_world_roster_complete(world_id: StringName, revision: int)
signal world_transition_failed(message: String)
signal multiplayer_session_ended(reason: String)
signal player_move_command_received(peer_id: int, sequence: int, move_axis: float, vertical_axis: float, jump_pressed: bool)
signal player_transform_snapshot_received(peer_id: int, position: Vector2, velocity: Vector2, facing: float, movement_mode: int, sequence: int)
signal player_runtime_snapshot_received(payload: Dictionary)
signal player_attack_command_received(peer_id: int, sequence: int)
signal player_attack_presented_received(peer_id: int, sequence: int, facing: float)
signal player_respawn_received(world_id: StringName, peer_id: int, position: Vector2)
signal enemy_spawn_received(world_id: StringName, payload: Dictionary)
signal enemy_despawn_received(world_id: StringName, entity_id: int)
signal enemy_snapshot_received(world_id: StringName, payload: Dictionary, reliable: bool)
signal loot_spawn_received(world_id: StringName, payload: Dictionary)
signal loot_despawn_received(world_id: StringName, entity_id: int)
signal loot_pickup_requested(peer_id: int, world_id: StringName, entity_id: int)
signal loot_pickup_result_received(success: bool, item_id: StringName, quantity: int, message: String)
signal gather_requested(peer_id: int, world_id: StringName, interaction_id: StringName)
signal gather_consumed_received(world_id: StringName, interaction_id: StringName)

enum ConnectionState { OFFLINE, HOSTING_RESTORING, HOSTING, CONNECTING, CONNECTED }

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const NETWORK_PROTOCOL_VERSION := NetworkProtocol.VERSION
const END_REASON_MANUAL := "manual_leave"
const END_REASON_CONNECTION_FAILED := "connection_failed"
const END_REASON_SERVER_DISCONNECTED := "server_disconnected"
const PROFILE_PATH_ARGUMENT := "--local-profile-path="
const REPLICATION_ACTOR_GRACE_MSEC := 150

var state: ConnectionState = ConnectionState.OFFLINE
var last_error: String = ""
var players: Dictionary[int, NetworkPlayerInfo] = {}
var peer_to_player: Dictionary[int, StringName] = {}
var player_to_peer: Dictionary[StringName, int] = {}
var world_ready_peers: Dictionary[int, PeerWorldReadyState] = {}
var _peer: ENetMultiplayerPeer
var _local_peer_id: int = 1
var _session_entered: bool = false
var _received_session_snapshot: bool = false
var _received_private_player_state: bool = false
var _received_spawn_assignment: bool = false
var _received_world_assignment: bool = false
var _accepting_handshakes: bool = false
var _pending_host_port: int = 0
var _returning_peers: Dictionary[int, bool] = {}
var _spawn_assignments: Dictionary[int, PlayerSpawnAssignment] = {}
var _pending_world_transitions: Dictionary[int, PlayerWorldAssignment] = {}
# A reliable world-roster actor creation is sent before scene-node snapshots.
# Unreliable transforms are admitted only after this short transport grace.
var _replication_ready_after_msec: Dictionary[int, int] = {}
# A rejected peer belongs only to the current transport generation. SceneTree
# timers cannot be cancelled by clearing this cache, so delayed callbacks also
# capture and validate the generation that scheduled them.
var _rejected_handshake_peers: Dictionary[int, bool] = {}
var _transport_generation: int = 0
# Narrow one-shot debug seam for deterministic bind-failure lifecycle tests.
var _host_transport_error_for_test: Error = OK
# Narrow debug seam for deterministic delayed-disconnect lifecycle tests.
var _rejected_disconnect_hook_for_test: Callable = Callable()
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

func world_assignment_for_peer(peer_id: int) -> PlayerWorldAssignment:
	return PlayerWorldAssignment.from_world_state(GameSession.session_id, GameSession.get_peer_world(peer_id))

func is_peer_world_ready(peer_id: int) -> bool:
	var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
	return ready != null and ready.matches(GameSession.get_peer_world(peer_id))

func is_peer_replication_ready(peer_id: int) -> bool:
	if not is_peer_world_ready(peer_id):
		return false
	return Time.get_ticks_msec() >= int(_replication_ready_after_msec.get(peer_id, 0))

func is_local_world_ready() -> bool:
	return is_peer_world_ready(local_peer_id()) if is_server() else _session_entered and is_peer_world_ready(local_peer_id())

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

func ensure_authoritative_spawn_assignment(peer_id: int) -> PlayerSpawnAssignment:
	if not is_authoritative_simulation() or not players.has(peer_id) or not GameSession.has_player(peer_id):
		return null
	var existing: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
	if existing != null and existing.session_id == GameSession.session_id \
			and existing.player_id == player_id_for_peer(peer_id) and existing.position.is_finite():
		return existing
	var assignment := _make_spawn_assignment_for_current_world(peer_id, is_returning_peer(peer_id))
	if assignment != null and assignment.error_message.is_empty():
		register_authoritative_spawn_assignment(peer_id, assignment)
	return assignment

func peek_local_spawn_assignment() -> PlayerSpawnAssignment:
	if is_server() or not _session_entered and not _received_spawn_assignment:
		return null
	return _spawn_assignments.get(local_peer_id())

func consume_local_spawn_assignment() -> PlayerSpawnAssignment:
	var result := peek_local_spawn_assignment()
	if result == null:
		return null
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
	if not is_server() or not players.has(peer_id):
		return
	var world := GameSession.get_peer_world(peer_id)
	if world == null:
		return
	var pending: PlayerWorldAssignment = _pending_world_transitions.get(peer_id)
	if pending != null and (pending.world_id != world.world_id or pending.revision != world.revision):
		return
	var previous: PeerWorldReadyState = world_ready_peers.get(peer_id)
	if previous != null and previous.matches(world):
		return
	world_ready_peers[peer_id] = PeerWorldReadyState.new(world.world_id, world.revision)
	_replication_ready_after_msec[peer_id] = Time.get_ticks_msec() + REPLICATION_ACTOR_GRACE_MSEC \
			if peer_id != local_peer_id() else 0
	_pending_world_transitions.erase(peer_id)
	for node in get_tree().get_nodes_in_group(&"player_spawn_manager"):
		var manager := node as PlayerSpawnManager
		if manager != null:
			manager.reconcile_peer_world(peer_id)
	# Existing same-world clients must instantiate the actor before scene-bound
	# runtime/item/quest components send follow-up RPCs for this ready peer.
	_broadcast_world_arrival(peer_id)
	get_tree().create_timer(0.05).timeout.connect(
		_emit_peer_world_ready.bind(peer_id, world.world_id, world.revision, _transport_generation),
		CONNECT_ONE_SHOT
	)

func _emit_peer_world_ready(peer_id: int, world_id: StringName, revision: int, generation: int) -> void:
	if generation != _transport_generation:
		return
	var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
	if ready != null and ready.world_id == world_id and ready.revision == revision:
		peer_world_ready.emit(peer_id)

func begin_world_sync() -> void:
	if is_server():
		world_ready_peers.erase(1)
		_replication_ready_after_msec.erase(1)

func ready_remote_peer_ids(world_id: StringName = &"") -> Array[int]:
	if world_id.is_empty() and is_server():
		world_id = GameSession.get_peer_world_id(local_peer_id())
	var result: Array[int] = []
	for peer_id in world_ready_peers:
		var ready: PeerWorldReadyState = world_ready_peers[peer_id]
		if peer_id != 1 and players.has(peer_id) and is_peer_world_ready(peer_id) \
				and (world_id.is_empty() or ready.world_id == world_id):
			result.append(peer_id)
	result.sort()
	return result

func all_ready_remote_peer_ids() -> Array[int]:
	var result: Array[int] = []
	for peer_id in world_ready_peers:
		if peer_id != local_peer_id() and players.has(peer_id) and is_peer_world_ready(peer_id):
			result.append(peer_id)
	result.sort()
	return result

func replication_ready_remote_peer_ids(world_id: StringName = &"") -> Array[int]:
	var result: Array[int] = []
	for peer_id in ready_remote_peer_ids(world_id):
		if is_peer_replication_ready(peer_id):
			result.append(peer_id)
	return result

func world_revision_for_peer(peer_id: int) -> int:
	var world := GameSession.get_peer_world(peer_id)
	return world.revision if world != null else 0

func submit_player_move_input(
	peer_id: int,
	sequence: int,
	move_axis: float,
	vertical_axis: float,
	jump_pressed: bool
) -> void:
	if is_server():
		if peer_id == local_peer_id() and is_peer_world_ready(peer_id):
			player_move_command_received.emit(peer_id, sequence, move_axis, vertical_axis, jump_pressed)
	elif is_session_connected() and peer_id == local_peer_id() and is_local_world_ready():
		_request_player_move_input.rpc_id(1, sequence, move_axis, vertical_axis, jump_pressed)

@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _request_player_move_input(sequence: int, move_axis: float, vertical_axis: float, jump_pressed: bool) -> void:
	if not is_host_session_ready():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkProtocol.valid_command_sender(sender, sender, has_peer(sender) and GameSession.has_player(sender) \
			and is_peer_world_ready(sender)):
		player_move_command_received.emit(sender, sequence, move_axis, vertical_axis, jump_pressed)

func broadcast_player_transform(
	source_peer_id: int,
	position: Vector2,
	velocity: Vector2,
	facing: float,
	movement_mode: int,
	sequence: int
) -> void:
	if not is_host_session_ready():
		return
	var world_id := GameSession.get_peer_world_id(source_peer_id)
	if world_id.is_empty():
		return
	for peer_id in replication_ready_remote_peer_ids(world_id):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		_receive_player_transform.rpc_id(
			peer_id, world_id, ready.revision, source_peer_id,
			position, velocity, facing, movement_mode, sequence
		)
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		player_transform_snapshot_received.emit(source_peer_id, position, velocity, facing, movement_mode, sequence)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _receive_player_transform(
	world_id: StringName,
	world_revision: int,
	peer_id: int,
	position: Vector2,
	velocity: Vector2,
	facing: float,
	movement_mode: int,
	sequence: int
) -> void:
	if _accept_current_world_packet(world_id, world_revision):
		player_transform_snapshot_received.emit(peer_id, position, velocity, facing, movement_mode, sequence)

func broadcast_player_runtime(source_peer_id: int, payload: Dictionary) -> void:
	if not is_host_session_ready():
		return
	var world_id := GameSession.get_peer_world_id(source_peer_id)
	for peer_id in ready_remote_peer_ids(world_id):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		_receive_player_runtime.rpc_id(peer_id, world_id, ready.revision, payload)
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		player_runtime_snapshot_received.emit(payload)

func send_player_runtime_to_peer(source_peer_id: int, target_peer_id: int, payload: Dictionary) -> void:
	var world_id := GameSession.get_peer_world_id(source_peer_id)
	if target_peer_id == local_peer_id() and GameSession.get_peer_world_id(target_peer_id) == world_id:
		player_runtime_snapshot_received.emit(payload)
	elif can_send_to_peer(target_peer_id) and GameSession.get_peer_world_id(target_peer_id) == world_id:
		var ready: PeerWorldReadyState = world_ready_peers.get(target_peer_id)
		if ready != null:
			_receive_player_runtime.rpc_id(target_peer_id, world_id, ready.revision, payload)

@rpc("authority", "call_remote", "reliable")
func _receive_player_runtime(world_id: StringName, world_revision: int, payload: Dictionary) -> void:
	if _accept_current_world_packet(world_id, world_revision):
		player_runtime_snapshot_received.emit(payload)

func submit_player_attack(peer_id: int, sequence: int) -> void:
	if is_server():
		if peer_id == local_peer_id() and is_peer_world_ready(peer_id):
			player_attack_command_received.emit(peer_id, sequence)
	elif is_session_connected() and peer_id == local_peer_id() and is_local_world_ready():
		_request_player_attack.rpc_id(1, sequence)

@rpc("any_peer", "call_remote", "reliable")
func _request_player_attack(sequence: int) -> void:
	if not is_host_session_ready():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1 and has_peer(sender) and GameSession.has_player(sender) and is_peer_world_ready(sender):
		player_attack_command_received.emit(sender, sequence)

func broadcast_player_attack(source_peer_id: int, sequence: int, facing: float) -> void:
	if not is_host_session_ready():
		return
	var world_id := GameSession.get_peer_world_id(source_peer_id)
	for peer_id in ready_remote_peer_ids(world_id):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		_receive_player_attack.rpc_id(peer_id, world_id, ready.revision, source_peer_id, sequence, facing)
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		player_attack_presented_received.emit(source_peer_id, sequence, facing)

func broadcast_player_respawn(world_id: StringName, source_peer_id: int, position: Vector2) -> void:
	if not is_host_session_ready() or world_id.is_empty() or not position.is_finite():
		return
	for peer_id in ready_remote_peer_ids(world_id):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		_receive_player_respawn.rpc_id(peer_id, world_id, ready.revision, source_peer_id, position)
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		player_respawn_received.emit(world_id, source_peer_id, position)

@rpc("authority", "call_remote", "reliable")
func _receive_player_respawn(
	world_id: StringName, world_revision: int, peer_id: int, position: Vector2
) -> void:
	if position.is_finite() and _accept_current_world_packet(world_id, world_revision):
		player_respawn_received.emit(world_id, peer_id, position)

@rpc("authority", "call_remote", "reliable")
func _receive_player_attack(
	world_id: StringName, world_revision: int, peer_id: int, sequence: int, facing: float
) -> void:
	if _accept_current_world_packet(world_id, world_revision):
		player_attack_presented_received.emit(peer_id, sequence, facing)

func broadcast_enemy_spawn(world_id: StringName, payload: Dictionary) -> void:
	_broadcast_world_payload(world_id, &"enemy_spawn", payload)

func broadcast_enemy_snapshot(world_id: StringName, payload: Dictionary, reliable: bool) -> void:
	if not is_host_session_ready():
		return
	for peer_id in (ready_remote_peer_ids(world_id) if reliable else replication_ready_remote_peer_ids(world_id)):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		if reliable:
			_receive_enemy_runtime.rpc_id(peer_id, world_id, ready.revision, payload)
		else:
			_receive_enemy_transform.rpc_id(peer_id, world_id, ready.revision, payload)
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		enemy_snapshot_received.emit(world_id, payload, reliable)

func broadcast_enemy_despawn(world_id: StringName, entity_id: int) -> void:
	_broadcast_world_payload(world_id, &"enemy_despawn", {"entity_id": entity_id})

func send_enemy_roster(peer_id: int, world_id: StringName, payloads: Array[Dictionary]) -> void:
	if not can_send_to_peer(peer_id) or GameSession.get_peer_world_id(peer_id) != world_id:
		return
	var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
	for payload in payloads:
		_receive_enemy_spawn.rpc_id(peer_id, world_id, ready.revision, payload)

@rpc("authority", "call_remote", "reliable")
func _receive_enemy_spawn(world_id: StringName, revision: int, payload: Dictionary) -> void:
	if _accept_current_world_packet(world_id, revision):
		enemy_spawn_received.emit(world_id, payload)

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _receive_enemy_transform(world_id: StringName, revision: int, payload: Dictionary) -> void:
	if _accept_current_world_packet(world_id, revision):
		enemy_snapshot_received.emit(world_id, payload, false)

@rpc("authority", "call_remote", "reliable")
func _receive_enemy_runtime(world_id: StringName, revision: int, payload: Dictionary) -> void:
	if _accept_current_world_packet(world_id, revision):
		enemy_snapshot_received.emit(world_id, payload, true)

@rpc("authority", "call_remote", "reliable")
func _receive_enemy_despawn(world_id: StringName, revision: int, entity_id: int) -> void:
	if _accept_current_world_packet(world_id, revision):
		enemy_despawn_received.emit(world_id, entity_id)

func broadcast_loot_spawn(world_id: StringName, payload: Dictionary) -> void:
	_broadcast_world_payload(world_id, &"loot_spawn", payload)

func broadcast_loot_despawn(world_id: StringName, entity_id: int) -> void:
	_broadcast_world_payload(world_id, &"loot_despawn", {"entity_id": entity_id})

func send_loot_roster(peer_id: int, world_id: StringName, payloads: Array[Dictionary]) -> void:
	if not can_send_to_peer(peer_id) or GameSession.get_peer_world_id(peer_id) != world_id:
		return
	var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
	for payload in payloads:
		_receive_loot_spawn.rpc_id(peer_id, world_id, ready.revision, payload)

func request_loot_pickup(entity_id: int) -> void:
	if entity_id <= 0 or not is_local_world_ready():
		return
	if is_server():
		loot_pickup_requested.emit(local_peer_id(), GameSession.get_peer_world_id(local_peer_id()), entity_id)
	elif is_session_connected():
		_request_world_loot_pickup.rpc_id(1, entity_id)

@rpc("any_peer", "call_remote", "reliable")
func _request_world_loot_pickup(entity_id: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if is_host_session_ready() and entity_id > 0 and has_peer(sender) and is_peer_world_ready(sender):
		loot_pickup_requested.emit(sender, GameSession.get_peer_world_id(sender), entity_id)

func send_loot_pickup_result(peer_id: int, success: bool, item_id: StringName, quantity: int, message: String) -> void:
	if peer_id == local_peer_id():
		loot_pickup_result_received.emit(success, item_id, quantity, message)
	elif can_send_to_peer(peer_id):
		_receive_world_loot_pickup_result.rpc_id(peer_id, success, item_id, quantity, message)

@rpc("authority", "call_remote", "reliable")
func _receive_world_loot_pickup_result(success: bool, item_id: StringName, quantity: int, message: String) -> void:
	loot_pickup_result_received.emit(success, item_id, quantity, message)

@rpc("authority", "call_remote", "reliable")
func _receive_loot_spawn(world_id: StringName, revision: int, payload: Dictionary) -> void:
	if _accept_current_world_packet(world_id, revision):
		loot_spawn_received.emit(world_id, payload)

@rpc("authority", "call_remote", "reliable")
func _receive_loot_despawn(world_id: StringName, revision: int, entity_id: int) -> void:
	if _accept_current_world_packet(world_id, revision):
		loot_despawn_received.emit(world_id, entity_id)

func request_gather(interaction_id: StringName) -> void:
	if interaction_id.is_empty() or not is_local_world_ready():
		return
	if is_server():
		gather_requested.emit(local_peer_id(), GameSession.get_peer_world_id(local_peer_id()), interaction_id)
	elif is_session_connected():
		_request_world_gather.rpc_id(1, interaction_id)

func broadcast_gather_consumed(world_id: StringName, interaction_id: StringName) -> void:
	if not is_host_session_ready() or world_id.is_empty() or interaction_id.is_empty():
		return
	for peer_id in ready_remote_peer_ids(world_id):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		_receive_gather_consumed.rpc_id(peer_id, world_id, ready.revision, interaction_id)
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		gather_consumed_received.emit(world_id, interaction_id)

func send_gather_state(peer_id: int, world_id: StringName, consumed_ids: Array[StringName]) -> void:
	if not can_send_to_peer(peer_id) or GameSession.get_peer_world_id(peer_id) != world_id:
		return
	var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
	if ready == null:
		return
	for interaction_id in consumed_ids:
		_receive_gather_consumed.rpc_id(peer_id, world_id, ready.revision, interaction_id)

@rpc("authority", "call_remote", "reliable")
func _receive_gather_consumed(world_id: StringName, revision: int, interaction_id: StringName) -> void:
	if not interaction_id.is_empty() and _accept_current_world_packet(world_id, revision):
		gather_consumed_received.emit(world_id, interaction_id)

@rpc("any_peer", "call_remote", "reliable")
func _request_world_gather(interaction_id: StringName) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if is_host_session_ready() and not interaction_id.is_empty() and has_peer(sender) and is_peer_world_ready(sender):
		gather_requested.emit(sender, GameSession.get_peer_world_id(sender), interaction_id)

func _broadcast_world_payload(world_id: StringName, kind: StringName, payload: Dictionary) -> void:
	if not is_host_session_ready() or world_id.is_empty():
		return
	for peer_id in ready_remote_peer_ids(world_id):
		var ready: PeerWorldReadyState = world_ready_peers.get(peer_id)
		match kind:
			&"enemy_spawn": _receive_enemy_spawn.rpc_id(peer_id, world_id, ready.revision, payload)
			&"enemy_despawn": _receive_enemy_despawn.rpc_id(peer_id, world_id, ready.revision, int(payload.get("entity_id", 0)))
			&"loot_spawn": _receive_loot_spawn.rpc_id(peer_id, world_id, ready.revision, payload)
			&"loot_despawn": _receive_loot_despawn.rpc_id(peer_id, world_id, ready.revision, int(payload.get("entity_id", 0)))
	if GameSession.get_peer_world_id(local_peer_id()) == world_id and is_local_world_ready():
		match kind:
			&"enemy_spawn": enemy_spawn_received.emit(world_id, payload)
			&"enemy_despawn": enemy_despawn_received.emit(world_id, int(payload.get("entity_id", 0)))
			&"loot_spawn": loot_spawn_received.emit(world_id, payload)
			&"loot_despawn": loot_despawn_received.emit(world_id, int(payload.get("entity_id", 0)))

func _accept_current_world_packet(world_id: StringName, revision: int) -> bool:
	if is_server() or not _session_entered or not is_local_world_ready():
		return false
	var local_world := GameSession.get_local_player_world()
	return local_world != null and local_world.world_id == world_id and local_world.revision == revision

func request_enter_region(exit_id: StringName, region_id: StringName) -> CommandResult:
	if not is_multiplayer_active():
		var context := GameSession.request_adventure_from_exit(exit_id, region_id)
		if context == null:
			return CommandResult.make(false, GameSession.last_message)
		return CommandResult.make(true, "World transition assigned") \
				if SceneRouter.go_to_adventure(context) else CommandResult.make(false, "Cannot load adventure world")
	if is_authoritative_simulation():
		return _begin_player_world_transition(local_peer_id(), exit_id, region_id)
	if not is_session_connected() or not is_local_world_ready():
		return CommandResult.make(false, "Local world is not ready")
	_request_enter_region.rpc_id(1, exit_id, region_id)
	return CommandResult.make(true, "World transition requested")

func request_return_to_settlement(
	result: AdventureSession.Result = AdventureSession.Result.NORMAL_ESCAPE
) -> CommandResult:
	if not is_multiplayer_active():
		var message := GameSession.finish_adventure(result)
		if GameSession.phase != GameSession.Phase.SETTLEMENT:
			return CommandResult.make(false, message)
		return CommandResult.make(true, message) \
				if SceneRouter.go_to_settlement() else CommandResult.make(false, "Cannot load Settlement")
	if is_authoritative_simulation():
		return _return_player_to_settlement(local_peer_id(), result)
	if not is_session_connected() or not is_local_world_ready():
		return CommandResult.make(false, "Local world is not ready")
	_request_return_to_settlement.rpc_id(1, int(result))
	return CommandResult.make(true, "Settlement return requested")

@rpc("any_peer", "call_remote", "reliable")
func _request_enter_region(exit_id: StringName, region_id: StringName) -> void:
	if not is_host_session_ready():
		return
	var sender := multiplayer.get_remote_sender_id()
	var result := _begin_player_world_transition(sender, exit_id, region_id)
	if not result.success:
		_send_world_transition_failure(sender, result.message)

@rpc("any_peer", "call_remote", "reliable")
func _request_return_to_settlement(result_value: int) -> void:
	if not is_host_session_ready():
		return
	var sender := multiplayer.get_remote_sender_id()
	if result_value < AdventureSession.Result.NORMAL_ESCAPE \
			or result_value > AdventureSession.Result.RETURN_ITEM_ESCAPE:
		_send_world_transition_failure(sender, "Invalid adventure return result")
		return
	var result := _return_player_to_settlement(sender, result_value as AdventureSession.Result)
	if not result.success:
		_send_world_transition_failure(sender, result.message)

func _begin_player_world_transition(
	peer_id: int,
	exit_id: StringName,
	region_id: StringName
) -> CommandResult:
	if not is_authoritative_simulation() or not players.has(peer_id) or not is_peer_world_ready(peer_id):
		return CommandResult.make(false, "Player world is not ready for transition")
	if _pending_world_transitions.has(peer_id):
		return CommandResult.make(false, "A world transition is already pending")
	var exit := ContentRegistry.get_definition(exit_id) as SettlementExitDefinition
	var region := ContentRegistry.get_definition(region_id) as RegionDefinition
	var check := GameSession.can_peer_use_exit(peer_id, exit_id, region_id)
	if not check.success or exit == null or region == null:
		return check if not check.success else CommandResult.make(false, "Unknown world destination")
	var destination_world := PlayerWorldState.adventure_world_id(region_id)
	var position := _configured_world_spawn(region.scene_path, exit.entry_point_id, GameSession.peer_ids_in_world(destination_world).size())
	if not position.is_finite():
		return CommandResult.make(false, "Adventure entry spawn is unavailable")
	var old_world := GameSession.get_peer_world_id(peer_id)
	var spawn := PlayerSpawnAssignment.create(
		GameSession.session_id, player_id_for_peer(peer_id), PlayerSpawnAssignment.SpawnKind.FRESH_SLOT, position
	)
	var previous_spawn: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
	if not register_authoritative_spawn_assignment(peer_id, spawn):
		return CommandResult.make(false, "Cannot prepare the destination spawn")
	var moved := GameSession.begin_player_adventure(peer_id, exit_id, region_id)
	if not moved.success:
		_restore_spawn_assignment(peer_id, previous_spawn)
		return moved
	_place_player_in_loaded_host_world(peer_id, spawn)
	return _dispatch_world_assignment(peer_id, old_world)

func _return_player_to_settlement(peer_id: int, result: AdventureSession.Result) -> CommandResult:
	if not is_authoritative_simulation() or not players.has(peer_id) or not is_peer_world_ready(peer_id):
		return CommandResult.make(false, "Player world is not ready for transition")
	if _pending_world_transitions.has(peer_id):
		return CommandResult.make(false, "A world transition is already pending")
	var player_state := GameSession.get_player(peer_id)
	var position := player_state.last_safe_position if player_state != null else Vector2.INF
	if not position.is_finite():
		position = _configured_world_spawn(SceneRouter.SETTLEMENT_SCENE, &"", 0)
	if not position.is_finite():
		return CommandResult.make(false, "Settlement return spawn is unavailable")
	var old_world := GameSession.get_peer_world_id(peer_id)
	var spawn := PlayerSpawnAssignment.create(
		GameSession.session_id,
		player_id_for_peer(peer_id),
		PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION,
		position
	)
	var previous_spawn: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
	if not register_authoritative_spawn_assignment(peer_id, spawn):
		return CommandResult.make(false, "Cannot prepare the Settlement spawn")
	var finished := GameSession.finish_player_adventure(peer_id, result)
	if not finished.success:
		_restore_spawn_assignment(peer_id, previous_spawn)
		return finished
	_place_player_in_loaded_host_world(peer_id, spawn)
	return _dispatch_world_assignment(peer_id, old_world)

func _restore_spawn_assignment(peer_id: int, previous: PlayerSpawnAssignment) -> void:
	if previous == null:
		_spawn_assignments.erase(peer_id)
	else:
		_spawn_assignments[peer_id] = previous

func _dispatch_world_assignment(peer_id: int, old_world_id: StringName) -> CommandResult:
	var assignment := world_assignment_for_peer(peer_id)
	if not assignment.error_message.is_empty():
		return CommandResult.make(false, assignment.error_message)
	_pending_world_transitions[peer_id] = assignment
	world_ready_peers.erase(peer_id)
	_replication_ready_after_msec.erase(peer_id)
	for ready_peer_id in ready_remote_peer_ids(old_world_id):
		if ready_peer_id != peer_id and can_send_to_peer(ready_peer_id):
			_receive_world_roster_remove.rpc_id(ready_peer_id, peer_id, assignment.to_payload())
	# Destination peers can instantiate the committed actor while the owner is
	# loading. Scene-bound follow-up RPCs then cannot outrun roster creation.
	_broadcast_world_arrival(peer_id)
	if peer_id == local_peer_id():
		local_world_assignment_received.emit(assignment)
	elif can_send_to_peer(peer_id):
		var spawn: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
		_receive_spawn_assignment.rpc_id(peer_id, spawn.to_payload())
		_receive_world_assignment.rpc_id(peer_id, assignment.to_payload())
	return CommandResult.make(true, "World transition assigned")

func request_local_world_roster() -> void:
	var local_world := GameSession.get_local_player_world()
	if is_server():
		if local_world == null:
			return
		for peer_id in GameSession.peer_ids_in_world(local_world.world_id):
			var spawn: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
			var assignment := world_assignment_for_peer(peer_id)
			if spawn != null and spawn.position.is_finite() and assignment.error_message.is_empty():
				if peer_id != local_peer_id():
					world_roster_player_received.emit(peer_id, assignment, spawn.position)
		local_world_roster_complete.emit(local_world.world_id, local_world.revision)
	elif is_session_connected() and multiplayer.get_unique_id() != 1:
		_request_world_roster.rpc_id(1)

func confirm_local_world_ready() -> void:
	var local_world := GameSession.get_local_player_world()
	if local_world == null:
		return
	if is_server():
		mark_peer_world_ready(local_peer_id())
	elif is_session_connected():
		world_ready_peers[local_peer_id()] = PeerWorldReadyState.new(local_world.world_id, local_world.revision)
		_confirm_world_ready.rpc_id(1, local_world.world_id, local_world.revision)

@rpc("any_peer", "call_remote", "reliable")
func _request_world_roster() -> void:
	if not is_host_session_ready():
		return
	var sender := multiplayer.get_remote_sender_id()
	var sender_world := GameSession.get_peer_world(sender)
	var pending: PlayerWorldAssignment = _pending_world_transitions.get(sender)
	if sender_world == null or pending == null or pending.world_id != sender_world.world_id \
			or pending.revision != sender_world.revision:
		return
	for peer_id in GameSession.peer_ids_in_world(sender_world.world_id):
		var spawn: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
		var assignment := world_assignment_for_peer(peer_id)
		if spawn != null and spawn.position.is_finite() and assignment.error_message.is_empty():
			_receive_world_roster_player.rpc_id(sender, peer_id, assignment.to_payload(), [spawn.position.x, spawn.position.y])
	_receive_world_roster_complete.rpc_id(sender, sender_world.world_id, sender_world.revision)

@rpc("authority", "call_remote", "reliable")
func _receive_world_roster_player(peer_id: int, world_payload: Dictionary, coordinates: Array) -> void:
	if is_server() or coordinates.size() != 2 \
			or not coordinates[0] is float and not coordinates[0] is int \
			or not coordinates[1] is float and not coordinates[1] is int:
		return
	var position := Vector2(float(coordinates[0]), float(coordinates[1]))
	var assignment := PlayerWorldAssignment.from_payload(world_payload, GameSession.session_id)
	var local_world := GameSession.get_local_player_world()
	if not position.is_finite() or not assignment.error_message.is_empty() or local_world == null \
			or assignment.world_id != local_world.world_id:
		return
	if assignment.player_id != GameSession.get_player_id(peer_id):
		return
	if peer_id != local_peer_id():
		GameSession.apply_remote_player_world_mirror(assignment)
	world_roster_player_received.emit(peer_id, assignment, position)

@rpc("authority", "call_remote", "reliable")
func _receive_world_roster_remove(peer_id: int, world_payload: Dictionary) -> void:
	if is_server():
		return
	var assignment := PlayerWorldAssignment.from_payload(world_payload, GameSession.session_id)
	if not assignment.error_message.is_empty() or assignment.player_id != GameSession.get_player_id(peer_id):
		return
	if peer_id != local_peer_id():
		GameSession.apply_remote_player_world_mirror(assignment)
	world_roster_player_removed.emit(peer_id)

@rpc("authority", "call_remote", "reliable")
func _receive_world_roster_complete(world_id: StringName, revision: int) -> void:
	if is_server():
		return
	var local_world := GameSession.get_local_player_world()
	if local_world != null and local_world.world_id == world_id and local_world.revision == revision:
		local_world_roster_complete.emit(world_id, revision)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_world_ready(world_id: StringName, revision: int) -> void:
	if not is_host_session_ready():
		return
	var sender := multiplayer.get_remote_sender_id()
	var world := GameSession.get_peer_world(sender)
	if world != null and world.world_id == world_id and world.revision == revision \
			and _pending_world_transitions.has(sender):
		mark_peer_world_ready(sender)

func _broadcast_world_arrival(peer_id: int) -> void:
	var world := GameSession.get_peer_world(peer_id)
	var spawn: PlayerSpawnAssignment = _spawn_assignments.get(peer_id)
	var assignment := world_assignment_for_peer(peer_id)
	if world == null or spawn == null or not spawn.position.is_finite() or not assignment.error_message.is_empty():
		return
	for ready_peer_id in ready_remote_peer_ids(world.world_id):
		if ready_peer_id != peer_id and can_send_to_peer(ready_peer_id):
			_receive_world_roster_player.rpc_id(
				ready_peer_id, peer_id, assignment.to_payload(), [spawn.position.x, spawn.position.y]
			)

func _send_world_transition_failure(peer_id: int, message: String) -> void:
	if can_send_to_peer(peer_id):
		_receive_world_transition_failure.rpc_id(peer_id, message)

@rpc("authority", "call_remote", "reliable")
func _receive_world_transition_failure(message: String) -> void:
	if not is_server():
		world_transition_failed.emit(message.left(256))

func _configured_world_spawn(scene_path: String, entry_point_id: StringName, slot_index: int) -> Vector2:
	var packed := ResourceLoader.load(scene_path) as PackedScene if ResourceLoader.exists(scene_path) else null
	if packed == null:
		return Vector2.INF
	var scene := packed.instantiate()
	var result := Vector2.INF
	var spawn_points: Array[PlayerSpawnPoint] = []
	for child in scene.get_children():
		if child is PlayerSpawnPoint:
			spawn_points.append(child)
	spawn_points.sort_custom(func(a: PlayerSpawnPoint, b: PlayerSpawnPoint) -> bool: return a.spawn_index < b.spawn_index)
	# The first arrival uses the authored entry marker. Additional arrivals use
	# deterministic world-local slots so two peers never enter on one collider.
	if slot_index > 0 and not spawn_points.is_empty():
		result = spawn_points[slot_index % spawn_points.size()].position
	elif not entry_point_id.is_empty():
		var region_points: Array[RegionPoint] = []
		RegionPoint.collect(scene, region_points)
		for point in region_points:
			if point.kind == RegionPoint.Kind.ENTRY and point.point_id == entry_point_id:
				result = point.position
				break
	if not result.is_finite():
		if not spawn_points.is_empty():
			result = spawn_points[slot_index % spawn_points.size()].position
	scene.free()
	return result

func _make_spawn_assignment_for_current_world(peer_id: int, returning: bool) -> PlayerSpawnAssignment:
	var world := GameSession.get_peer_world(peer_id)
	var player_state := GameSession.get_player(peer_id)
	if world == null or player_state == null:
		return null
	var position := Vector2.INF
	var kind := PlayerSpawnAssignment.SpawnKind.FRESH_SLOT
	var world_peers := GameSession.peer_ids_in_world(world.world_id)
	var slot_index := maxi(0, world_peers.find(peer_id))
	if world.world_kind == PlayerWorldState.WorldKind.SETTLEMENT:
		if returning and player_state.last_safe_position.is_finite():
			position = player_state.last_safe_position
			kind = PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION
		else:
			position = _configured_world_spawn(SceneRouter.SETTLEMENT_SCENE, &"", slot_index)
	elif world.world_kind == PlayerWorldState.WorldKind.ADVENTURE:
		var region := ContentRegistry.get_definition(world.region_id) as RegionDefinition
		if region != null:
			position = _configured_world_spawn(region.scene_path, world.entry_point_id, slot_index)
	return PlayerSpawnAssignment.create(GameSession.session_id, world.player_id, kind, position)

func _place_player_in_loaded_host_world(peer_id: int, assignment: PlayerSpawnAssignment) -> void:
	var world_id := GameSession.get_peer_world_id(peer_id)
	for node in get_tree().get_nodes_in_group(&"player_spawn_manager"):
		var manager := node as PlayerSpawnManager
		if manager != null and manager.authoritative_runtime and manager.world_id == world_id:
			manager.apply_authoritative_world_arrival(peer_id, assignment)
			return

# Read-only lifecycle audit used by integration probes and debug diagnostics.
# Detached canonical players intentionally have no entry in these runtime maps.
func validate_runtime_invariants() -> PackedStringArray:
	var errors := PackedStringArray()
	for peer_id in players:
		var player_id := player_id_for_peer(peer_id)
		if player_id.is_empty():
			errors.append("active peer %d has no player identity" % peer_id)
		elif player_to_peer.get(player_id, 0) != peer_id:
			errors.append("active peer %d has an asymmetric reverse identity mapping" % peer_id)
		if not GameSession.has_player(peer_id):
			errors.append("active peer %d has no GameSession attachment" % peer_id)
		elif GameSession.get_player_id(peer_id) != player_id:
			errors.append("active peer %d differs from its GameSession identity" % peer_id)
	for peer_id in peer_to_player:
		if not players.has(peer_id):
			errors.append("identity mapping references inactive peer %d" % peer_id)
	for player_id in player_to_peer:
		var peer_id: int = player_to_peer[player_id]
		if peer_to_player.get(peer_id, &"") != player_id:
			errors.append("player identity %s has an asymmetric peer mapping" % player_id)
	for peer_id in world_ready_peers:
		if not players.has(peer_id):
			errors.append("world-ready cache references inactive peer %d" % peer_id)
		elif not is_peer_world_ready(peer_id):
			errors.append("world-ready cache differs from peer %d assignment" % peer_id)
	for peer_id in _spawn_assignments:
		var assignment: PlayerSpawnAssignment = _spawn_assignments[peer_id]
		if not players.has(peer_id) or assignment == null \
				or assignment.player_id != player_id_for_peer(peer_id) \
				or assignment.session_id != GameSession.session_id:
			errors.append("spawn assignment cache is stale for peer %d" % peer_id)
	return errors

func _on_transport_peer_connected(peer_id: int) -> void:
	if is_server():
		print("[NET] Transport connected peer %d; awaiting protocol handshake" % peer_id)

func _on_transport_peer_disconnected(peer_id: int) -> void:
	# Clear quarantine even when a late disconnect signal arrives after the
	# transport state has already moved offline.
	_rejected_handshake_peers.erase(peer_id)
	if not is_server():
		return
	var was_active := players.has(peer_id) or peer_to_player.has(peer_id) or GameSession.has_player(peer_id)
	if GameSession.has_player(peer_id):
		GameSession.detach_player(peer_id)
	players.erase(peer_id)
	world_ready_peers.erase(peer_id)
	_replication_ready_after_msec.erase(peer_id)
	_spawn_assignments.erase(peer_id)
	_pending_world_transitions.erase(peer_id)
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
	# Invalidate every delayed callback from the transport being closed before
	# replacing its MultiplayerPeer. This is a lifecycle token, not a packet or
	# gameplay revision.
	_transport_generation += 1
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
	_received_world_assignment = false
	_accepting_handshakes = false
	_pending_host_port = 0
	players.clear()
	peer_to_player.clear()
	player_to_peer.clear()
	world_ready_peers.clear()
	_replication_ready_after_msec.clear()
	_returning_peers.clear()
	_spawn_assignments.clear()
	_pending_world_transitions.clear()
	_rejected_handshake_peers.clear()

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
	var host_world := GameSession.get_peer_world(1)
	if host_world == null:
		last_error = "Cannot initialize the host world state"
		_remove_identity(1)
		players.clear()
		return ERR_INVALID_DATA
	world_ready_peers[1] = PeerWorldReadyState.new(host_world.world_id, host_world.revision)
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
	if _rejected_handshake_peers.has(sender):
		return
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
	if spawn_assignment == null:
		spawn_assignment = _make_spawn_assignment_for_current_world(sender, was_persistent)
		if spawn_assignment != null and spawn_assignment.error_message.is_empty():
			register_authoritative_spawn_assignment(sender, spawn_assignment)
	if spawn_assignment == null or not spawn_assignment.error_message.is_empty():
		_rollback_peer_attachment(sender, player_id, was_persistent)
		_reject_remote_handshake(sender, "Cannot build authoritative spawn assignment")
		return
	var world_assignment := world_assignment_for_peer(sender)
	if not world_assignment.error_message.is_empty():
		_rollback_peer_attachment(sender, player_id, was_persistent)
		_reject_remote_handshake(sender, "Cannot build player world assignment")
		return
	_pending_world_transitions[sender] = world_assignment
	_receive_session_snapshot.rpc_id(sender, GameSession.to_network_snapshot(NETWORK_PROTOCOL_VERSION))
	_receive_private_player_state.rpc_id(sender, private_snapshot.to_payload())
	_receive_spawn_assignment.rpc_id(sender, spawn_assignment.to_payload())
	_receive_world_assignment.rpc_id(sender, world_assignment.to_payload())
	print("[NET] Connected peer %d" % sender)
	peer_joined.emit(sender)

func _reject_remote_handshake(peer_id: int, message: String) -> void:
	if peer_id <= 1 or _peer == null or _rejected_handshake_peers.has(peer_id):
		return
	_rejected_handshake_peers[peer_id] = true
	if can_send_to_peer(peer_id):
		_reject_handshake.rpc_id(peer_id, message)
	# Allow one network poll to flush the reliable rejection before transport
	# teardown. The peer is quarantined above and owns no identity/session state.
	var generation := _transport_generation
	get_tree().create_timer(0.1).timeout.connect(
		_disconnect_rejected_peer.bind(peer_id, generation), CONNECT_ONE_SHOT
	)

func _disconnect_rejected_peer(peer_id: int, generation: int) -> void:
	if generation != _transport_generation:
		return
	if not _rejected_handshake_peers.has(peer_id):
		return
	if OS.is_debug_build() and _rejected_disconnect_hook_for_test.is_valid():
		_rejected_handshake_peers.erase(peer_id)
		_rejected_disconnect_hook_for_test.call(peer_id)
		return
	if _peer == null or not multiplayer.get_peers().has(peer_id):
		return
	_rejected_handshake_peers.erase(peer_id)
	_peer.disconnect_peer(peer_id, false)

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
	if is_server():
		return
	if not _session_entered and (not _received_session_snapshot or not _received_private_player_state):
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
	if not _session_entered:
		_received_spawn_assignment = true
		_try_complete_client_sync()

@rpc("authority", "call_remote", "reliable")
func _receive_world_assignment(payload: Dictionary) -> void:
	if is_server() or not _received_session_snapshot:
		return
	var assignment := PlayerWorldAssignment.from_payload(
		payload, GameSession.session_id, local_profile_player_id()
	)
	if not assignment.error_message.is_empty() \
			or not GameSession.apply_player_world_assignment(assignment):
		if not _session_entered:
			_fail_client_sync(
				assignment.error_message if not assignment.error_message.is_empty() \
				else "Cannot apply player world assignment"
			)
		else:
			world_transition_failed.emit(
				assignment.error_message if not assignment.error_message.is_empty() \
				else "Cannot apply player world assignment"
			)
		return
	_received_world_assignment = true
	local_world_assignment_received.emit(assignment)
	_try_complete_client_sync()

func _try_complete_client_sync() -> void:
	if _session_entered or not _received_session_snapshot or not _received_private_player_state \
			or not _received_spawn_assignment or not _received_world_assignment:
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
	world_ready_peers.erase(peer_id)
	_spawn_assignments.erase(peer_id)
	_pending_world_transitions.erase(peer_id)
	_replication_ready_after_msec.erase(peer_id)
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
	_replication_ready_after_msec.erase(peer_id)
	_spawn_assignments.erase(peer_id)
	_pending_world_transitions.erase(peer_id)
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
