class_name PlayerCombatRuntimeSnapshot
extends RefCounted
## Throttled, unreliable mirror of one player's authoritative [CombatRuntimeState].
##
## Stamina regenerates continuously, so it must not ride the reliable
## [PlayerRuntimeSnapshot] path. This payload carries only the current pair plus
## a sequence, so a late packet can never overwrite a newer value.

var peer_id: int = 0
var stamina: float = 0.0
var max_stamina: float = 0.0
var sequence: int = 0
var error_message: String = ""

func to_payload() -> Dictionary:
	return {
		"peer_id": peer_id,
		"stamina": stamina,
		"max_stamina": max_stamina,
		"sequence": sequence,
	}

static func from_payload(payload: Dictionary) -> PlayerCombatRuntimeSnapshot:
	var result := PlayerCombatRuntimeSnapshot.new()
	for key in ["peer_id", "stamina", "max_stamina", "sequence"]:
		if not payload.has(key):
			result.error_message = "Missing player combat runtime field: %s" % key
			return result
	if not payload.peer_id is int or not payload.sequence is int:
		result.error_message = "Invalid player combat runtime identity"
		return result
	if not (payload.stamina is int or payload.stamina is float) \
		or not (payload.max_stamina is int or payload.max_stamina is float):
		result.error_message = "Invalid player combat runtime numeric value"
		return result
	result.peer_id = int(payload.peer_id)
	result.stamina = float(payload.stamina)
	result.max_stamina = float(payload.max_stamina)
	result.sequence = int(payload.sequence)
	if result.peer_id <= 0 or result.sequence < 0 \
		or not is_finite(result.stamina) or not is_finite(result.max_stamina) \
		or result.max_stamina < 0.0 or result.stamina < 0.0 or result.stamina > result.max_stamina:
		result.error_message = "Invalid player combat runtime snapshot"
	return result

## True when this payload is newer than the last applied one. Unreliable ordered
## delivery can still drop packets, so the receiver compares sequences instead of
## assuming arrival.
func is_valid_after(previous_sequence: int) -> bool:
	return error_message.is_empty() and sequence > previous_sequence
