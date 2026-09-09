class_name EnemyRuntimeSnapshot
extends RefCounted

enum State { IDLE, MOVING, ATTACKING, HURT, DEAD }

var entity_id: int
var enemy_id: StringName
var position: Vector2
var velocity: Vector2
var facing: float = 1.0
var health: float
var max_health: float
var state: State = State.IDLE
var snapshot_sequence: int
var error_message: String = ""

func to_payload() -> Dictionary:
	return {"entity_id": entity_id, "enemy_id": String(enemy_id), "position": position,
		"velocity": velocity, "facing": facing, "health": health, "max_health": max_health,
		"state": int(state), "sequence": snapshot_sequence}

static func from_payload(payload: Dictionary, registry: Node = ContentRegistry) -> EnemyRuntimeSnapshot:
	var result := EnemyRuntimeSnapshot.new()
	if not payload.get("entity_id") is int or not payload.get("enemy_id") is String \
		or not payload.get("position") is Vector2 or not payload.get("velocity") is Vector2 \
		or not (payload.get("facing") is float or payload.get("facing") is int) \
		or not (payload.get("health") is float or payload.get("health") is int) \
		or not (payload.get("max_health") is float or payload.get("max_health") is int) \
		or not payload.get("state") is int or not payload.get("sequence") is int:
		result.error_message = "Malformed enemy snapshot"
		return result
	result.entity_id = payload["entity_id"]
	result.enemy_id = StringName(payload["enemy_id"])
	result.position = payload["position"]
	result.velocity = payload["velocity"]
	result.facing = float(payload["facing"])
	result.health = float(payload["health"])
	result.max_health = float(payload["max_health"])
	result.state = payload["state"] as State
	result.snapshot_sequence = payload["sequence"]
	if result.entity_id <= 0 or not registry.get_definition(result.enemy_id) is EnemyDefinition \
		or not result.position.is_finite() or not result.velocity.is_finite() or not is_finite(result.facing) \
		or not is_finite(result.health) or not is_finite(result.max_health) or result.max_health <= 0.0 \
		or result.health < 0.0 or result.health > result.max_health or int(result.state) < State.IDLE \
		or int(result.state) > State.DEAD or result.snapshot_sequence < 0:
		result.error_message = "Invalid enemy snapshot"
	return result
