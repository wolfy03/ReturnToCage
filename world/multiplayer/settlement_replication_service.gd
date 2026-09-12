class_name SettlementReplicationService
extends Node

signal craft_result(success: bool, message: String)
signal facility_upgrade_result(success: bool, message: String)

enum CommandType { CRAFT, UPGRADE_FACILITY }

static var _next_local_sequence: int = 0
static var _last_command_sequences: Dictionary[int, int] = {}

var _flush_scheduled: bool = false
var _last_settlement_revision: int = -1
var _last_progression_revision: int = -1

func _ready() -> void:
	add_to_group(&"settlement_replication_service")
	GameSession.settlement_state_changed.connect(_on_shared_state_changed)
	GameSession.shared_progression_changed.connect(_on_shared_state_changed)
	NetworkManager.peer_world_ready.connect(_on_peer_world_ready)
	NetworkManager.peer_left.connect(_on_peer_left)

func _exit_tree() -> void:
	if GameSession.settlement_state_changed.is_connected(_on_shared_state_changed):
		GameSession.settlement_state_changed.disconnect(_on_shared_state_changed)
	if GameSession.shared_progression_changed.is_connected(_on_shared_state_changed):
		GameSession.shared_progression_changed.disconnect(_on_shared_state_changed)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)
	if NetworkManager.peer_left.is_connected(_on_peer_left):
		NetworkManager.peer_left.disconnect(_on_peer_left)

func request_craft(recipe_id: StringName) -> void:
	var sequence := _next_sequence()
	if NetworkManager.is_authoritative_simulation():
		_server_execute(CommandType.CRAFT, NetworkManager.local_peer_id(), GameSession.get_local_player_id(), recipe_id, sequence, true)
	elif NetworkManager.is_session_connected():
		_request_craft.rpc_id(1, recipe_id, sequence)

func request_upgrade_facility(facility_id: StringName) -> void:
	var sequence := _next_sequence()
	if NetworkManager.is_authoritative_simulation():
		_server_execute(CommandType.UPGRADE_FACILITY, NetworkManager.local_peer_id(), GameSession.get_local_player_id(), facility_id, sequence, true)
	elif NetworkManager.is_session_connected():
		_request_upgrade_facility.rpc_id(1, facility_id, sequence)

@rpc("any_peer", "call_remote", "reliable")
func _request_craft(recipe_id: StringName, sequence: int) -> void:
	_server_receive(CommandType.CRAFT, recipe_id, sequence)

@rpc("any_peer", "call_remote", "reliable")
func _request_upgrade_facility(facility_id: StringName, sequence: int) -> void:
	_server_receive(CommandType.UPGRADE_FACILITY, facility_id, sequence)

func _server_receive(command_type: CommandType, target_id: StringName, sequence: int) -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var player_id := NetworkManager.player_id_for_peer(sender)
	if sender <= 1 or not NetworkManager.has_peer(sender) or not GameSession.has_player(sender) or player_id.is_empty():
		return
	if not _accept_sequence(sender, sequence):
		_send_result(sender, command_type, false, "Settlement command rejected: stale sequence")
		return
	_server_execute(command_type, sender, player_id, target_id, sequence, false)

func _server_execute(
	command_type: CommandType,
	peer_id: int,
	player_id: StringName,
	target_id: StringName,
	sequence: int,
	local_result: bool
) -> void:
	if not NetworkManager.is_authoritative_simulation():
		return
	if local_result and not _accept_sequence(peer_id, sequence):
		_emit_result(command_type, false, "Settlement command rejected: stale sequence")
		return
	var runtime := GameSession.get_player_runtime(peer_id)
	var result: CommandResult
	if player_id.is_empty() or not GameSession.has_player(peer_id):
		result = CommandResult.make(false, "Unknown settlement command player")
	elif not _has_player_actor(peer_id):
		result = CommandResult.make(false, "Settlement command player actor is unavailable")
	elif not GameSession.is_peer_in_settlement(peer_id) or not NetworkManager.is_peer_world_ready(peer_id):
		result = CommandResult.make(false, "Settlement command player is not ready in the settlement")
	elif runtime == null or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE:
		result = CommandResult.make(false, "Only a living player can use settlement commands")
	elif GameSession.phase != GameSession.Phase.SETTLEMENT:
		result = CommandResult.make(false, "Settlement commands require settlement state")
	elif command_type == CommandType.CRAFT:
		result = GameSession.execute_craft_command(target_id, player_id)
	else:
		result = GameSession.execute_facility_upgrade_command(target_id, player_id)
	if result.success:
		# Both domain commits finish before either reliable mirror is sent. This
		# also coalesces storage + facility + unlock changes into one pair.
		_broadcast_current_state()
	if local_result:
		_emit_result(command_type, result.success, result.message)
	else:
		_send_result(peer_id, command_type, result.success, result.message)

func _has_player_actor(peer_id: int) -> bool:
	for candidate in get_tree().get_nodes_in_group(&"player"):
		if candidate is PlayerActor and candidate.peer_id == peer_id and candidate.is_simulation_authority():
			return true
	return false

func _accept_sequence(peer_id: int, sequence: int) -> bool:
	if peer_id <= 0 or sequence <= 0 or sequence > 0x7fffffff:
		return false
	var previous: int = _last_command_sequences.get(peer_id, 0)
	if sequence <= previous:
		return false
	# Consume a valid sequence before gameplay validation so a replay cannot
	# become valid later after phase/resources change.
	_last_command_sequences[peer_id] = sequence
	return true

func _next_sequence() -> int:
	_next_local_sequence += 1
	if _next_local_sequence <= 0 or _next_local_sequence > 0x7fffffff:
		_next_local_sequence = 1
	return _next_local_sequence

func _on_shared_state_changed(_revision: int) -> void:
	if not NetworkManager.is_authoritative_simulation() or _flush_scheduled:
		return
	_flush_scheduled = true
	call_deferred("_flush_shared_state")

func _flush_shared_state() -> void:
	_flush_scheduled = false
	if NetworkManager.is_authoritative_simulation():
		_broadcast_current_state()

func _broadcast_current_state() -> void:
	var settlement_snapshot := GameSession.make_settlement_snapshot()
	var progression_snapshot := GameSession.make_shared_progression_snapshot()
	if settlement_snapshot == null or progression_snapshot == null:
		return
	if settlement_snapshot.revision == _last_settlement_revision \
			and progression_snapshot.revision == _last_progression_revision:
		return
	_last_settlement_revision = settlement_snapshot.revision
	_last_progression_revision = progression_snapshot.revision
	for peer_id in NetworkManager.ready_remote_peer_ids():
		_send_current_to_peer(peer_id, settlement_snapshot, progression_snapshot)

func _on_peer_world_ready(peer_id: int) -> void:
	if not NetworkManager.is_server() or not NetworkManager.can_send_to_peer(peer_id) \
			or not GameSession.are_peers_in_same_world(NetworkManager.local_peer_id(), peer_id):
		return
	var settlement_snapshot := GameSession.make_settlement_snapshot()
	var progression_snapshot := GameSession.make_shared_progression_snapshot()
	if settlement_snapshot != null and progression_snapshot != null:
		_send_current_to_peer(peer_id, settlement_snapshot, progression_snapshot)

func _send_current_to_peer(
	peer_id: int,
	settlement_snapshot: SettlementStateSnapshot,
	progression_snapshot: SharedProgressionSnapshot
) -> void:
	if not NetworkManager.can_send_to_peer(peer_id):
		return
	_receive_settlement_snapshot.rpc_id(peer_id, settlement_snapshot.to_payload())
	_receive_progression_snapshot.rpc_id(peer_id, progression_snapshot.to_payload())

func _on_peer_left(peer_id: int) -> void:
	_last_command_sequences.erase(peer_id)

func _send_result(peer_id: int, command_type: CommandType, success: bool, message: String) -> void:
	if NetworkManager.can_send_to_peer(peer_id):
		_receive_command_result.rpc_id(peer_id, int(command_type), success, message)

func _emit_result(command_type: CommandType, success: bool, message: String) -> void:
	GameSession.last_message = message
	if command_type == CommandType.CRAFT:
		craft_result.emit(success, message)
	else:
		facility_upgrade_result.emit(success, message)

@rpc("authority", "call_remote", "reliable")
func _receive_settlement_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server():
		return
	var snapshot := SettlementStateSnapshot.from_payload(payload, ContentRegistry)
	if snapshot.error_message.is_empty():
		GameSession.apply_settlement_network_snapshot(snapshot)

@rpc("authority", "call_remote", "reliable")
func _receive_progression_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server():
		return
	var snapshot := SharedProgressionSnapshot.from_payload(payload, ContentRegistry)
	if snapshot.error_message.is_empty():
		GameSession.apply_shared_progression_network_snapshot(snapshot)

@rpc("authority", "call_remote", "reliable")
func _receive_command_result(command_type: int, success: bool, message: String) -> void:
	if command_type < CommandType.CRAFT or command_type > CommandType.UPGRADE_FACILITY:
		return
	_emit_result(command_type as CommandType, success, message)
