class_name PlayerSpawnAssignment
extends RefCounted

enum SpawnKind {
	RETURNING_SAFE_POSITION,
	FRESH_SLOT,
	SETTLEMENT_FALLBACK,
}

var session_id: String = ""
var player_id: StringName = &""
var spawn_kind: SpawnKind = SpawnKind.FRESH_SLOT
var position: Vector2 = Vector2.ZERO
var fallback_used: bool = false
var reason: String = ""
var error_message: String = ""

func to_payload() -> Dictionary:
	return {
		"session_id": session_id,
		"player_id": String(player_id),
		"spawn_kind": int(spawn_kind),
		"position": [position.x, position.y],
		"fallback_used": fallback_used,
		"reason": reason,
	}

static func create(
	p_session_id: String,
	p_player_id: StringName,
	p_spawn_kind: SpawnKind,
	p_position: Vector2,
	p_fallback_used: bool = false,
	p_reason: String = ""
) -> PlayerSpawnAssignment:
	var result := PlayerSpawnAssignment.new()
	result.session_id = p_session_id
	result.player_id = p_player_id
	result.spawn_kind = p_spawn_kind
	result.position = p_position
	result.fallback_used = p_fallback_used
	result.reason = p_reason.left(128)
	if result.session_id.is_empty() or not LocalPlayerProfile.is_valid_player_id(result.player_id) \
			or not result.position.is_finite():
		result.error_message = "Invalid authoritative spawn assignment"
	return result

static func from_payload(
	payload: Dictionary,
	expected_session_id: String,
	expected_player_id: StringName
) -> PlayerSpawnAssignment:
	var result := PlayerSpawnAssignment.new()
	if not SaveData.is_text(payload.get("session_id", null)) \
			or not SaveData.is_text(payload.get("player_id", null)) \
			or not SaveData.is_integer(payload.get("spawn_kind", null)) \
			or not payload.get("position", null) is Array \
			or not payload.get("fallback_used", null) is bool \
			or not SaveData.is_text(payload.get("reason", null)):
		result.error_message = "Invalid spawn assignment fields"
		return result
	var coordinates: Array = payload["position"]
	if coordinates.size() != 2 or not coordinates[0] is float and not coordinates[0] is int \
			or not coordinates[1] is float and not coordinates[1] is int:
		result.error_message = "Invalid spawn assignment position"
		return result
	result.session_id = String(payload["session_id"])
	result.player_id = StringName(payload["player_id"])
	var kind_value := int(payload["spawn_kind"])
	result.position = Vector2(float(coordinates[0]), float(coordinates[1]))
	result.fallback_used = payload["fallback_used"]
	result.reason = String(payload["reason"]).left(128)
	if result.session_id.is_empty() or result.session_id != expected_session_id \
			or not LocalPlayerProfile.is_valid_player_id(result.player_id) \
			or result.player_id != expected_player_id \
			or kind_value < SpawnKind.RETURNING_SAFE_POSITION \
			or kind_value > SpawnKind.SETTLEMENT_FALLBACK \
			or not result.position.is_finite():
		result.error_message = "Invalid spawn assignment identity or data"
		return result
	result.spawn_kind = kind_value as SpawnKind
	if result.fallback_used != (result.spawn_kind == SpawnKind.SETTLEMENT_FALLBACK):
		result.error_message = "Invalid spawn assignment fallback state"
	return result
