class_name PeerWorldReadyState
extends RefCounted

var world_id: StringName = &""
var revision: int = 0

func _init(p_world_id: StringName = &"", p_revision: int = 0) -> void:
	world_id = p_world_id
	revision = p_revision

func matches(state: PlayerWorldState) -> bool:
	return state != null and world_id == state.world_id and revision == state.revision
