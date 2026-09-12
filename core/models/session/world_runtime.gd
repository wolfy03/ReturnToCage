class_name WorldRuntime
extends RefCounted

var world_id: StringName = &""
var world_kind: PlayerWorldState.WorldKind = PlayerWorldState.WorldKind.NONE
var region_id: StringName = &""
var elapsed_seconds: float = 0.0

func _init(
	p_world_id: StringName = &"",
	p_world_kind: PlayerWorldState.WorldKind = PlayerWorldState.WorldKind.NONE,
	p_region_id: StringName = &""
) -> void:
	world_id = p_world_id
	world_kind = p_world_kind
	region_id = p_region_id

func is_valid() -> bool:
	if world_id.is_empty():
		return false
	if world_kind == PlayerWorldState.WorldKind.SETTLEMENT:
		return world_id == PlayerWorldState.SETTLEMENT_WORLD_ID and region_id.is_empty()
	if world_kind == PlayerWorldState.WorldKind.ADVENTURE:
		return not region_id.is_empty() and world_id == PlayerWorldState.adventure_world_id(region_id)
	return false
