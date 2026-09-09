class_name NetworkEnemyComponent
extends Node

const SNAPSHOT_INTERVAL := 1.0 / 20.0
const INTERPOLATION_SPEED := 14.0
const TELEPORT_DISTANCE := 500.0

var actor: EnemyAgent
var _sequence: int = 0
var _last_received_sequence: int = -1
var _accumulator: float = 0.0
var _has_snapshot: bool = false
var _target_position: Vector2
var _target_velocity: Vector2

func configure(p_actor: EnemyAgent) -> void:
	actor = p_actor
	if actor.is_simulation_authority():
		actor.health.health_changed.connect(_on_health_changed)
		actor.state_changed.connect(_on_state_changed)

func _process(delta: float) -> void:
	if actor == null:
		return
	if actor.is_simulation_authority():
		if not NetworkManager.is_server():
			return
		_accumulator += delta
		if _accumulator >= SNAPSHOT_INTERVAL:
			_accumulator = fmod(_accumulator, SNAPSHOT_INTERVAL)
			_broadcast_snapshot(false)
	else:
		presentation_tick(delta)

func presentation_tick(delta: float) -> void:
	if not _has_snapshot:
		return
	if actor.global_position.distance_to(_target_position) > TELEPORT_DISTANCE:
		actor.global_position = _target_position
	else:
		actor.global_position = actor.global_position.lerp(_target_position, 1.0 - exp(-INTERPOLATION_SPEED * delta))
	actor.velocity = _target_velocity

func make_snapshot() -> EnemyRuntimeSnapshot:
	if actor == null or actor.definition == null:
		return null
	var snapshot := EnemyRuntimeSnapshot.new()
	snapshot.entity_id = actor.network_entity_id
	snapshot.enemy_id = actor.definition.id
	snapshot.position = actor.global_position
	snapshot.velocity = actor.velocity
	snapshot.facing = actor.facing
	snapshot.health = clampf(actor.health.current_health, 0.0, actor.health.max_health)
	snapshot.max_health = actor.health.max_health
	snapshot.state = _state_value(actor.current_state_id)
	snapshot.snapshot_sequence = _sequence
	return snapshot

func apply_snapshot(snapshot: EnemyRuntimeSnapshot) -> bool:
	if actor == null or snapshot == null or not snapshot.error_message.is_empty() \
		or snapshot.entity_id != actor.network_entity_id or snapshot.enemy_id != actor.definition.id \
		or snapshot.snapshot_sequence <= _last_received_sequence:
		return false
	_last_received_sequence = snapshot.snapshot_sequence
	_target_position = snapshot.position
	_target_velocity = snapshot.velocity
	actor.facing = snapshot.facing
	actor.apply_runtime_presentation(snapshot)
	if not _has_snapshot:
		actor.global_position = snapshot.position
		_has_snapshot = true
	return true

func _on_health_changed(_current: float, _maximum: float) -> void:
	_broadcast_snapshot(true)

func _on_state_changed(_state_id: StringName) -> void:
	_broadcast_snapshot(true)

func _broadcast_snapshot(reliable: bool) -> void:
	if not NetworkManager.is_server() or actor == null:
		return
	_sequence += 1
	var snapshot := make_snapshot()
	if snapshot == null:
		return
	for peer_id in NetworkManager.ready_remote_peer_ids():
		if not NetworkManager.can_send_to_peer(peer_id):
			continue
		if reliable:
			_receive_runtime_snapshot.rpc_id(peer_id, snapshot.to_payload())
		else:
			_receive_transform_snapshot.rpc_id(peer_id, snapshot.to_payload())

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _receive_transform_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server():
		return
	apply_snapshot(EnemyRuntimeSnapshot.from_payload(payload))

@rpc("authority", "call_remote", "reliable")
func _receive_runtime_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server():
		return
	apply_snapshot(EnemyRuntimeSnapshot.from_payload(payload))

static func _state_value(id: StringName) -> EnemyRuntimeSnapshot.State:
	match id:
		&"chase", &"patrol": return EnemyRuntimeSnapshot.State.MOVING
		&"attack": return EnemyRuntimeSnapshot.State.ATTACKING
		&"hurt": return EnemyRuntimeSnapshot.State.HURT
		&"dead": return EnemyRuntimeSnapshot.State.DEAD
		_: return EnemyRuntimeSnapshot.State.IDLE
