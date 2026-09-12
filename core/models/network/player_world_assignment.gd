class_name PlayerWorldAssignment
extends RefCounted

var session_id: String = ""
var player_id: StringName = &""
var revision: int = 0
var world_kind: PlayerWorldState.WorldKind = PlayerWorldState.WorldKind.NONE
var world_id: StringName = &""
var region_id: StringName = &""
var entry_point_id: StringName = &""
var error_message: String = ""

static func from_world_state(p_session_id: String, state: PlayerWorldState) -> PlayerWorldAssignment:
	var result := PlayerWorldAssignment.new()
	if state == null:
		result.error_message = "Missing player world state"
		return result
	result.session_id = p_session_id
	result.player_id = state.player_id
	result.revision = state.revision
	result.world_kind = state.world_kind
	result.world_id = state.world_id
	result.region_id = state.region_id
	result.entry_point_id = state.entry_point_id
	if result.session_id.is_empty() or not state.is_valid():
		result.error_message = "Invalid player world assignment"
	return result

func to_payload() -> Dictionary:
	return {
		"session_id": session_id,
		"player_id": String(player_id),
		"revision": revision,
		"world_kind": int(world_kind),
		"world_id": String(world_id),
		"region_id": String(region_id),
		"entry_point_id": String(entry_point_id),
	}

static func from_payload(
	payload: Dictionary,
	expected_session_id: String = "",
	expected_player_id: StringName = &""
) -> PlayerWorldAssignment:
	var result := PlayerWorldAssignment.new()
	for field in ["session_id", "player_id", "world_id", "region_id", "entry_point_id"]:
		if not SaveData.is_text(payload.get(field, null)):
			result.error_message = "Invalid player world assignment fields"
			return result
	if not SaveData.is_integer(payload.get("revision", null)) \
			or not SaveData.is_integer(payload.get("world_kind", null)):
		result.error_message = "Invalid player world assignment fields"
		return result
	result.session_id = String(payload["session_id"])
	result.player_id = StringName(payload["player_id"])
	result.revision = int(payload["revision"])
	var kind_value := int(payload["world_kind"])
	result.world_id = StringName(payload["world_id"])
	result.region_id = StringName(payload["region_id"])
	result.entry_point_id = StringName(payload["entry_point_id"])
	if kind_value < PlayerWorldState.WorldKind.SETTLEMENT \
			or kind_value > PlayerWorldState.WorldKind.ADVENTURE:
		result.error_message = "Invalid player world assignment kind"
		return result
	result.world_kind = kind_value as PlayerWorldState.WorldKind
	var state := result.to_world_state()
	if result.session_id.is_empty() or not state.is_valid() \
			or not expected_session_id.is_empty() and result.session_id != expected_session_id \
			or not expected_player_id.is_empty() and result.player_id != expected_player_id:
		result.error_message = "Invalid player world assignment identity or session"
	return result

func to_world_state() -> PlayerWorldState:
	return PlayerWorldState.create(
		player_id, world_kind, world_id, region_id, entry_point_id, revision
	)

func to_adventure_context(difficulty_id: StringName) -> AdventureContext:
	if world_kind != PlayerWorldState.WorldKind.ADVENTURE or not error_message.is_empty():
		return null
	return AdventureContext.new(region_id, &"", entry_point_id, difficulty_id, session_id)
