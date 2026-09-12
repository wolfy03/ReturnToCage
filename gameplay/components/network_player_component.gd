class_name NetworkPlayerComponent
extends Node

const SNAPSHOT_INTERVAL := 1.0 / 20.0
const INTERPOLATION_SPEED := 14.0
const TELEPORT_DISTANCE := 500.0

var actor: PlayerActor
var input: PlayerInputComponent
var movement: MovementComponent
var _local_sequence: int = 0
var _last_received_sequence: int = -1
var _snapshot_sequence: int = 0
var _snapshot_accumulator: float = 0.0
var _has_snapshot: bool = false
var _target_position: Vector2
var _target_velocity: Vector2
var _target_facing: float = 1.0
var _target_movement_mode: int = MovementComponent.Mode.AIR

func configure(p_actor: PlayerActor, p_input: PlayerInputComponent, p_movement: MovementComponent) -> void:
	actor = p_actor
	input = p_input
	movement = p_movement
	var reads_local_input := actor.is_local_player()
	input.configure_input(reads_local_input, NetworkManager.is_authoritative_simulation())
	if NetworkManager.is_server():
		GameSession.player_health_changed.connect(_on_player_health_changed)
		GameSession.player_life_changed.connect(_on_player_life_changed)
		NetworkManager.peer_world_ready.connect(_on_peer_world_ready)
		call_deferred("_broadcast_runtime_snapshot")

func _exit_tree() -> void:
	if GameSession.player_health_changed.is_connected(_on_player_health_changed):
		GameSession.player_health_changed.disconnect(_on_player_health_changed)
	if GameSession.player_life_changed.is_connected(_on_player_life_changed):
		GameSession.player_life_changed.disconnect(_on_player_life_changed)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)

func _process(_delta: float) -> void:
	if actor == null or not NetworkManager.is_multiplayer_active() or not actor.is_local_player():
		return
	if not NetworkManager.is_local_world_ready():
		input.take_jump_pressed()
		return
	# 1/2 foundation: a client whose local world differs from the host's
	# presentation waits for the 2/2 background authoritative world runtime.
	if not NetworkManager.is_server() and not GameSession.are_peers_in_same_world(actor.peer_id, 1):
		input.take_jump_pressed()
		return
	if NetworkManager.is_server():
		input.take_jump_pressed()
		return
	_local_sequence += 1
	var command := PlayerMoveCommand.new(_local_sequence, input.move_axis, input.vertical_axis, input.take_jump_pressed())
	if command.is_valid_after(_local_sequence - 1):
		_submit_move_input.rpc_id(1, command.sequence, command.move_axis, command.vertical_axis, command.jump_pressed)

func server_snapshot_tick(delta: float) -> void:
	if actor == null or not NetworkManager.is_multiplayer_active() or not NetworkManager.is_server():
		return
	if not NetworkManager.is_peer_replication_ready(actor.peer_id):
		return
	_snapshot_accumulator += delta
	if _snapshot_accumulator < SNAPSHOT_INTERVAL:
		return
	_snapshot_accumulator = fmod(_snapshot_accumulator, SNAPSHOT_INTERVAL)
	_snapshot_sequence += 1
	for peer_id in NetworkManager.replication_ready_remote_peer_ids(GameSession.get_peer_world_id(actor.peer_id)):
		_receive_transform_snapshot.rpc_id(peer_id, actor.global_position, actor.velocity, actor.facing, int(movement.mode), _snapshot_sequence)

func presentation_tick(delta: float) -> void:
	if actor == null or NetworkManager.is_authoritative_simulation() or not _has_snapshot:
		return
	if actor.global_position.distance_to(_target_position) > TELEPORT_DISTANCE:
		actor.global_position = _target_position
	else:
		var weight := 1.0 - exp(-INTERPOLATION_SPEED * delta)
		actor.global_position = actor.global_position.lerp(_target_position, weight)
	actor.velocity = _target_velocity
	actor.facing = _target_facing
	movement.mode = _target_movement_mode as MovementComponent.Mode

func _on_player_health_changed(peer_id: int, _health: float, _max_health: float) -> void:
	if actor != null and peer_id == actor.peer_id:
		_broadcast_runtime_snapshot()

func _on_player_life_changed(peer_id: int, _life_id: int, _life_phase: int) -> void:
	if actor != null and peer_id == actor.peer_id:
		_broadcast_runtime_snapshot()

func _on_peer_world_ready(peer_id: int) -> void:
	# The central reliable roster RPC is queued before peer_world_ready. This
	# reliable health/life snapshot therefore cannot target a missing actor;
	# unreliable transforms remain behind the replication grace below.
	if not is_inside_tree() or actor == null or not actor.visible \
			or actor.process_mode == Node.PROCESS_MODE_DISABLED \
			or not GameSession.are_peers_in_same_world(actor.peer_id, peer_id):
		return
	_send_runtime_snapshot(peer_id)

func _runtime_snapshot() -> PlayerRuntimeSnapshot:
	if actor == null:
		return null
	var state := GameSession.get_player(actor.peer_id)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	if state == null or runtime == null:
		return null
	var snapshot := PlayerRuntimeSnapshot.new()
	snapshot.peer_id = actor.peer_id
	snapshot.health = state.health
	snapshot.max_health = maxf(1.0, state.stats.value(&"max_health"))
	snapshot.life_id = runtime.life_id
	snapshot.life_phase = runtime.life_phase
	snapshot.facing = actor.facing
	return snapshot

func _broadcast_runtime_snapshot() -> void:
	if not NetworkManager.is_server() or actor == null or not actor.visible \
			or actor.process_mode == Node.PROCESS_MODE_DISABLED \
			or not NetworkManager.is_peer_replication_ready(actor.peer_id):
		return
	for peer_id in NetworkManager.replication_ready_remote_peer_ids(GameSession.get_peer_world_id(actor.peer_id)):
		_send_runtime_snapshot(peer_id)

func _send_runtime_snapshot(peer_id: int) -> void:
	if not NetworkManager.can_send_to_peer(peer_id):
		return
	var snapshot := _runtime_snapshot()
	if snapshot != null:
		_receive_runtime_snapshot.rpc_id(peer_id, snapshot.to_payload())

@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _submit_move_input(sequence: int, move_axis: float, vertical_axis: float, jump_pressed: bool) -> void:
	if not NetworkManager.is_server() or actor == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not NetworkProtocol.valid_command_sender(sender, actor.peer_id, GameSession.has_player(sender) \
			and NetworkManager.has_peer(sender) and NetworkManager.is_peer_world_ready(sender)):
		return
	var command := PlayerMoveCommand.new(sequence, move_axis, vertical_axis, jump_pressed)
	if not command.is_valid_after(_last_received_sequence):
		return
	_last_received_sequence = sequence
	input.apply_move_command(command)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _receive_transform_snapshot(position: Vector2, replicated_velocity: Vector2, replicated_facing: float, movement_mode: int, sequence: int) -> void:
	if NetworkManager.is_server() or sequence <= _snapshot_sequence:
		return
	if not NetworkProtocol.valid_snapshot(position, replicated_velocity, replicated_facing, movement_mode):
		return
	_snapshot_sequence = sequence
	_target_position = position
	_target_velocity = replicated_velocity
	_target_facing = replicated_facing
	_target_movement_mode = movement_mode
	if not _has_snapshot:
		actor.global_position = position
		_has_snapshot = true

@rpc("authority", "call_remote", "reliable")
func _receive_runtime_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server() or actor == null:
		return
	var snapshot := PlayerRuntimeSnapshot.from_payload(payload)
	if not snapshot.error_message.is_empty() or snapshot.peer_id != actor.peer_id:
		return
	if GameSession.apply_player_runtime_snapshot(snapshot):
		actor.apply_runtime_presentation(snapshot)
