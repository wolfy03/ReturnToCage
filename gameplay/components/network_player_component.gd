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

func _process(_delta: float) -> void:
	if actor == null or not NetworkManager.is_multiplayer_active() or not actor.is_local_player():
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
	_snapshot_accumulator += delta
	if _snapshot_accumulator < SNAPSHOT_INTERVAL:
		return
	_snapshot_accumulator = fmod(_snapshot_accumulator, SNAPSHOT_INTERVAL)
	_snapshot_sequence += 1
	for peer_id in NetworkManager.ready_remote_peer_ids():
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

@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _submit_move_input(sequence: int, move_axis: float, vertical_axis: float, jump_pressed: bool) -> void:
	if not NetworkManager.is_server() or actor == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not NetworkProtocol.valid_command_sender(sender, actor.peer_id, GameSession.has_player(sender) and NetworkManager.has_peer(sender)):
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
