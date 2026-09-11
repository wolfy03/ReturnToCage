class_name PlayerPrivateStateSnapshot
extends RefCounted

var player_id: StringName = &""
var stats: Dictionary = {}
var survival: Dictionary = {}
var effects: Array[Dictionary] = []
var last_safe_position: Vector2 = Vector2.ZERO
var error_message: String = ""

func to_payload() -> Dictionary:
	return {
		"player_id": String(player_id),
		"stats": stats.duplicate(true),
		"survival": survival.duplicate(true),
		"effects": effects.duplicate(true),
		"last_safe_position": [last_safe_position.x, last_safe_position.y],
	}

static func from_state(owner_player_id: StringName, state: PlayerState) -> PlayerPrivateStateSnapshot:
	var result := PlayerPrivateStateSnapshot.new()
	if not LocalPlayerProfile.is_valid_player_id(owner_player_id) or state == null:
		result.error_message = "Player private snapshot requires a valid owner and state"
		return result
	result.player_id = owner_player_id
	result.stats = state.stats.to_dict()
	result.survival = state.survival.to_dict()
	result.effects = state.effects.to_array()
	result.last_safe_position = state.last_safe_position
	if not result.last_safe_position.is_finite():
		result.error_message = "Player private snapshot has an invalid safe position"
	return result

static func from_payload(
	payload: Dictionary,
	registry: Node,
	start: GameStartDefinition,
	expected_player_id: StringName
) -> PlayerPrivateStateSnapshot:
	var result := PlayerPrivateStateSnapshot.new()
	if not SaveData.is_text(payload.get("player_id", null)) \
			or not payload.get("stats", null) is Dictionary \
			or not payload.get("survival", null) is Dictionary \
			or not payload.get("effects", null) is Array \
			or not payload.get("last_safe_position", null) is Array:
		result.error_message = "Invalid player private snapshot fields"
		return result
	result.player_id = StringName(payload["player_id"])
	if not LocalPlayerProfile.is_valid_player_id(result.player_id) \
			or result.player_id != expected_player_id or registry == null or start == null:
		result.error_message = "Invalid player private snapshot owner"
		return result

	var errors := PackedStringArray()
	var staged_stats := StatBlock.new()
	staged_stats.base_values = start.player_stats.duplicate()
	errors.append_array(staged_stats.restore(payload["stats"]))
	if staged_stats.value(&"max_health") <= 0.0:
		errors.append("invalid private max_health")
	var staged_survival := SurvivalState.new()
	staged_survival.reset(start)
	errors.append_array(staged_survival.restore(payload["survival"]))
	var staged_effects := EffectRuntimeModel.new(staged_stats)
	errors.append_array(staged_effects.restore(payload["effects"], Callable(registry, "get_definition")))
	var position_errors := PackedStringArray()
	var position := SaveData.position(payload, "last_safe_position", start.last_safe_position, position_errors)
	errors.append_array(position_errors)
	if not errors.is_empty():
		result.error_message = "Invalid player private snapshot data: %s" % "; ".join(errors)
		return result
	result.stats = staged_stats.to_dict()
	result.survival = staged_survival.to_dict()
	result.effects = staged_effects.to_array()
	result.last_safe_position = position
	return result
