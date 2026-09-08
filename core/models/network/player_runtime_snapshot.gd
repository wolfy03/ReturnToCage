class_name PlayerRuntimeSnapshot
extends RefCounted

var peer_id: int = 0
var health: float = 0.0
var max_health: float = 1.0
var life_id: int = 0
var life_phase: int = PlayerRuntimeState.LifePhase.ALIVE
var facing: float = 1.0
var error_message: String = ""

func to_payload() -> Dictionary:
	return {
		"peer_id": peer_id,
		"health": health,
		"max_health": max_health,
		"life_id": life_id,
		"life_phase": life_phase,
		"facing": facing,
	}

static func from_payload(payload: Dictionary) -> PlayerRuntimeSnapshot:
	var result := PlayerRuntimeSnapshot.new()
	for key in ["peer_id", "health", "max_health", "life_id", "life_phase", "facing"]:
		if not payload.has(key):
			result.error_message = "Missing player runtime field: %s" % key
			return result
	if not payload.peer_id is int or not payload.life_id is int or not payload.life_phase is int:
		result.error_message = "Invalid player runtime identity"
		return result
	if not (payload.health is int or payload.health is float) \
		or not (payload.max_health is int or payload.max_health is float) \
		or not (payload.facing is int or payload.facing is float):
		result.error_message = "Invalid player runtime numeric value"
		return result
	result.peer_id = int(payload.peer_id)
	result.health = float(payload.health)
	result.max_health = float(payload.max_health)
	result.life_id = int(payload.life_id)
	result.life_phase = int(payload.life_phase)
	result.facing = float(payload.facing)
	if result.peer_id <= 0 or result.life_id < 0 \
		or not is_finite(result.health) or not is_finite(result.max_health) or not is_finite(result.facing) \
		or result.max_health <= 0.0 or result.health < 0.0 or result.health > result.max_health \
		or result.life_phase < PlayerRuntimeState.LifePhase.ALIVE \
		or result.life_phase > PlayerRuntimeState.LifePhase.RESPAWNING:
		result.error_message = "Invalid player runtime snapshot"
	return result
