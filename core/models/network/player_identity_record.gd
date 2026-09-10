class_name PlayerIdentityRecord
extends RefCounted

var peer_id: int
var player_id: StringName
var error_message: String = ""

func _init(p_peer_id: int = 0, p_player_id: StringName = &"") -> void:
	peer_id = p_peer_id
	player_id = p_player_id

func to_payload() -> Dictionary:
	return {"peer_id": peer_id, "player_id": String(player_id)}

static func from_payload(payload: Variant) -> PlayerIdentityRecord:
	var result := PlayerIdentityRecord.new()
	if not payload is Dictionary or not payload.get("peer_id") is int \
		or (not payload.get("player_id") is String and not payload.get("player_id") is StringName):
		result.error_message = "Malformed player identity"
		return result
	result.peer_id = payload["peer_id"]
	result.player_id = StringName(payload["player_id"])
	if result.peer_id <= 0 or not LocalPlayerProfile.is_valid_player_id(result.player_id):
		result.error_message = "Invalid player identity"
	return result
