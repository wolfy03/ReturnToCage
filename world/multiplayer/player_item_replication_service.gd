class_name PlayerItemReplicationService
extends Node

signal equip_result(success: bool, message: String)
signal unequip_result(success: bool, message: String)
signal use_item_result(success: bool, message: String)
signal transfer_result(success: bool, message: String)

enum CommandType { EQUIP, UNEQUIP, USE_ITEM, TRANSFER }

static var _next_local_sequence: int = 0
static var _last_command_sequences: Dictionary[int, int] = {}

var _last_sent_revisions: Dictionary[int, int] = {}

func _ready() -> void:
	add_to_group(&"player_item_replication_service")
	GameSession.player_item_state_changed.connect(_on_player_item_state_changed)
	NetworkManager.peer_world_ready.connect(_on_peer_world_ready)
	NetworkManager.peer_left.connect(_on_peer_left)

func _exit_tree() -> void:
	if GameSession.player_item_state_changed.is_connected(_on_player_item_state_changed):
		GameSession.player_item_state_changed.disconnect(_on_player_item_state_changed)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)
	if NetworkManager.peer_left.is_connected(_on_peer_left):
		NetworkManager.peer_left.disconnect(_on_peer_left)

func request_equip(instance_id: String) -> void:
	_submit(CommandType.EQUIP, instance_id, -1, &"", "", 1)

func request_unequip(slot: int) -> void:
	_submit(CommandType.UNEQUIP, "", slot, &"", "", 1)

func request_use_item(item_id: StringName) -> void:
	_submit(CommandType.USE_ITEM, "", -1, item_id, "", 1)

func request_transfer(direction: int, item_id: StringName, amount: int, instance_id: String = "") -> void:
	_submit(CommandType.TRANSFER, "", direction, item_id, instance_id, amount)

func _submit(
	command_type: CommandType,
	identity: String,
	option: int,
	item_id: StringName,
	instance_id: String,
	amount: int
) -> void:
	var sequence := _next_sequence()
	if NetworkManager.is_authoritative_simulation():
		_server_execute(NetworkManager.local_peer_id(), command_type, identity, option, item_id, instance_id, amount, sequence, true)
	elif NetworkManager.is_session_connected():
		_request_item_command.rpc_id(1, int(command_type), identity, option, item_id, instance_id, amount, sequence)

@rpc("any_peer", "call_remote", "reliable")
func _request_item_command(
	command_type: int,
	identity: String,
	option: int,
	item_id: StringName,
	instance_id: String,
	amount: int,
	sequence: int
) -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not NetworkManager.has_peer(sender) or not GameSession.has_player(sender) \
			or NetworkManager.player_id_for_peer(sender).is_empty():
		return
	if command_type < CommandType.EQUIP or command_type > CommandType.TRANSFER:
		return
	if not _accept_sequence(sender, sequence):
		_send_result(sender, command_type as CommandType, false, "Item command rejected: stale sequence")
		return
	_server_execute(sender, command_type as CommandType, identity, option, item_id, instance_id, amount, sequence, false)

func _server_execute(
	peer_id: int,
	command_type: CommandType,
	identity: String,
	option: int,
	item_id: StringName,
	instance_id: String,
	amount: int,
	sequence: int,
	local_result: bool
) -> void:
	if not NetworkManager.is_authoritative_simulation():
		return
	if local_result and not _accept_sequence(peer_id, sequence):
		_emit_result(command_type, false, "Item command rejected: stale sequence")
		return
	var runtime := GameSession.get_player_runtime(peer_id)
	var actor := _player_actor(peer_id)
	var result: CommandResult
	if not GameSession.has_player(peer_id) or GameSession.get_player_id(peer_id).is_empty():
		result = CommandResult.make(false, "Unknown item command player")
	elif actor == null:
		result = CommandResult.make(false, "Item command player actor is unavailable")
	elif runtime == null or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE or actor.is_death_handled():
		result = CommandResult.make(false, "Only a living player can use item commands")
	elif command_type == CommandType.TRANSFER and GameSession.phase != GameSession.Phase.SETTLEMENT:
		result = CommandResult.make(false, "Storage transfer requires settlement state")
	elif GameSession.phase not in [GameSession.Phase.SETTLEMENT, GameSession.Phase.ADVENTURE]:
		result = CommandResult.make(false, "Item commands are unavailable in this phase")
	else:
		match command_type:
			CommandType.EQUIP:
				result = GameSession.execute_equip_command(peer_id, identity)
			CommandType.UNEQUIP:
				result = GameSession.execute_unequip_command(peer_id, option)
			CommandType.USE_ITEM:
				result = GameSession.execute_use_item_command(peer_id, item_id, actor.survival, actor.effects)
			CommandType.TRANSFER:
				result = GameSession.execute_item_transfer_command(peer_id, option, item_id, instance_id, amount)
	if result.success:
		_send_owner_snapshot(peer_id)
	if local_result:
		_emit_result(command_type, result.success, result.message)
	else:
		_send_result(peer_id, command_type, result.success, result.message)

func _player_actor(peer_id: int) -> PlayerActor:
	for candidate in get_tree().get_nodes_in_group(&"player"):
		if candidate is PlayerActor and candidate.peer_id == peer_id and candidate.is_simulation_authority():
			return candidate
	return null

func _on_player_item_state_changed(player_id: StringName, _revision: int) -> void:
	if not NetworkManager.is_server():
		return
	var peer_id := NetworkManager.peer_id_for_player(player_id)
	if peer_id > 1 and NetworkManager.world_ready_peers.has(peer_id):
		_send_owner_snapshot(peer_id)

func _on_peer_world_ready(peer_id: int) -> void:
	if NetworkManager.is_server():
		_send_owner_snapshot(peer_id, true)

func _send_owner_snapshot(peer_id: int, force: bool = false) -> void:
	if peer_id <= 1 or not NetworkManager.can_send_to_peer(peer_id):
		return
	var snapshot := GameSession.make_player_item_snapshot(peer_id)
	if snapshot == null or not snapshot.error_message.is_empty():
		return
	if not force and _last_sent_revisions.get(peer_id, -1) == snapshot.revision:
		return
	_last_sent_revisions[peer_id] = snapshot.revision
	_receive_item_snapshot.rpc_id(peer_id, snapshot.to_payload())

func _on_peer_left(peer_id: int) -> void:
	_last_command_sequences.erase(peer_id)
	_last_sent_revisions.erase(peer_id)

func _accept_sequence(peer_id: int, sequence: int) -> bool:
	if peer_id <= 0 or sequence <= 0 or sequence > 0x7fffffff:
		return false
	var previous: int = _last_command_sequences.get(peer_id, 0)
	if sequence <= previous:
		return false
	_last_command_sequences[peer_id] = sequence
	return true

func _next_sequence() -> int:
	_next_local_sequence += 1
	if _next_local_sequence <= 0 or _next_local_sequence > 0x7fffffff:
		_next_local_sequence = 1
	return _next_local_sequence

func _send_result(peer_id: int, command_type: CommandType, success: bool, message: String) -> void:
	if NetworkManager.can_send_to_peer(peer_id):
		_receive_command_result.rpc_id(peer_id, int(command_type), success, message)

func _emit_result(command_type: CommandType, success: bool, message: String) -> void:
	GameSession.last_message = message
	match command_type:
		CommandType.EQUIP:
			equip_result.emit(success, message)
		CommandType.UNEQUIP:
			unequip_result.emit(success, message)
		CommandType.USE_ITEM:
			use_item_result.emit(success, message)
		CommandType.TRANSFER:
			transfer_result.emit(success, message)

@rpc("authority", "call_remote", "reliable")
func _receive_item_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server():
		return
	var snapshot := PlayerItemStateSnapshot.from_payload(payload, ContentRegistry, GameSession.get_local_player_id())
	if snapshot.error_message.is_empty():
		GameSession.apply_player_item_network_snapshot(snapshot)

@rpc("authority", "call_remote", "reliable")
func _receive_command_result(command_type: int, success: bool, message: String) -> void:
	if command_type < CommandType.EQUIP or command_type > CommandType.TRANSFER:
		return
	_emit_result(command_type as CommandType, success, message)
