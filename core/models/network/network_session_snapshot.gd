class_name NetworkSessionSnapshot
extends RefCounted

var session_id: String = ""
var phase: int = 0
var difficulty_id: StringName = &""
var player_ids: Array[int] = []
var identities: Array[PlayerIdentityRecord] = []
var error_message: String = ""

static func from_payload(payload: Dictionary, expected_protocol: int, max_players: int) -> NetworkSessionSnapshot:
	var result := NetworkSessionSnapshot.new()
	if payload.get("protocol_version") != expected_protocol:
		result.error_message = "Incompatible multiplayer protocol version"
		return result
	if not payload.get("session_id", null) is String or String(payload.get("session_id", "")).is_empty():
		result.error_message = "Invalid multiplayer session id"
		return result
	if not payload.get("phase", null) is int:
		result.error_message = "Invalid multiplayer phase"
		return result
	if not payload.get("difficulty_id", null) is String and not payload.get("difficulty_id", null) is StringName:
		result.error_message = "Invalid multiplayer difficulty"
		return result
	if not payload.get("players", null) is Array:
		result.error_message = "Invalid multiplayer player list"
		return result
	var raw_players: Array = payload["players"]
	if raw_players.is_empty() or raw_players.size() > max_players:
		result.error_message = "Invalid multiplayer player count"
		return result
	var logical_ids: Array[StringName] = []
	for value in raw_players:
		var identity := PlayerIdentityRecord.from_payload(value)
		if not identity.error_message.is_empty() or result.player_ids.has(identity.peer_id) or logical_ids.has(identity.player_id):
			result.error_message = "Invalid or duplicate multiplayer player identity"
			return result
		result.player_ids.append(identity.peer_id)
		logical_ids.append(identity.player_id)
		result.identities.append(identity)
	result.session_id = payload["session_id"]
	result.phase = payload["phase"]
	result.difficulty_id = StringName(payload["difficulty_id"])
	return result
