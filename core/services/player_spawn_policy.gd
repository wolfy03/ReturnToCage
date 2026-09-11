class_name PlayerSpawnPolicy
extends RefCounted

static func decide(
	session_id: String,
	player_id: StringName,
	returning: bool,
	last_safe_position: Vector2,
	fresh_positions: Array[Vector2],
	fallback_positions: Array[Vector2],
	validator: Callable
) -> PlayerSpawnAssignment:
	if session_id.is_empty() or not LocalPlayerProfile.is_valid_player_id(player_id) or not validator.is_valid():
		return _failure("Spawn policy requires a session, player identity and validator")
	if returning:
		var safe_issue := _validation_issue(last_safe_position, validator)
		if safe_issue.is_empty():
			return PlayerSpawnAssignment.create(
				session_id, player_id, PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION,
				last_safe_position
			)
		for fallback in fallback_positions:
			if _validation_issue(fallback, validator).is_empty():
				return PlayerSpawnAssignment.create(
					session_id, player_id, PlayerSpawnAssignment.SpawnKind.SETTLEMENT_FALLBACK,
					fallback, true, safe_issue
				)
		return _failure("No valid Settlement fallback spawn is configured")
	for position in fresh_positions:
		if _validation_issue(position, validator).is_empty():
			return PlayerSpawnAssignment.create(
				session_id, player_id, PlayerSpawnAssignment.SpawnKind.FRESH_SLOT, position
			)
	return _failure("No valid fresh player spawn slot is available")

static func _validation_issue(position: Vector2, validator: Callable) -> String:
	if not position.is_finite():
		return "NON_FINITE"
	var value: Variant = validator.call(position)
	return String(value) if value != null else "INVALID"

static func _failure(message: String) -> PlayerSpawnAssignment:
	var result := PlayerSpawnAssignment.new()
	result.error_message = message
	return result
