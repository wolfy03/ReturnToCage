class_name PlayerWorldState
extends RefCounted

enum WorldKind {
	NONE,
	SETTLEMENT,
	ADVENTURE,
}

const SETTLEMENT_WORLD_ID: StringName = &"settlement"
const ADVENTURE_WORLD_PREFIX := "adventure:"

var player_id: StringName = &""
var world_kind: WorldKind = WorldKind.NONE
var world_id: StringName = &""
var region_id: StringName = &""
var entry_point_id: StringName = &""
var revision: int = 0

static func settlement(p_player_id: StringName, p_revision: int = 1) -> PlayerWorldState:
	return create(p_player_id, WorldKind.SETTLEMENT, SETTLEMENT_WORLD_ID, &"", &"", p_revision)

static func adventure(
	p_player_id: StringName,
	p_region_id: StringName,
	p_entry_point_id: StringName,
	p_revision: int
) -> PlayerWorldState:
	return create(
		p_player_id,
		WorldKind.ADVENTURE,
		adventure_world_id(p_region_id),
		p_region_id,
		p_entry_point_id,
		p_revision
	)

static func create(
	p_player_id: StringName,
	p_world_kind: WorldKind,
	p_world_id: StringName,
	p_region_id: StringName = &"",
	p_entry_point_id: StringName = &"",
	p_revision: int = 1
) -> PlayerWorldState:
	var result := PlayerWorldState.new()
	result.player_id = p_player_id
	result.world_kind = p_world_kind
	result.world_id = p_world_id
	result.region_id = p_region_id
	result.entry_point_id = p_entry_point_id
	result.revision = p_revision
	return result

static func adventure_world_id(p_region_id: StringName) -> StringName:
	return StringName(ADVENTURE_WORLD_PREFIX + String(p_region_id)) if not p_region_id.is_empty() else &""

func is_valid() -> bool:
	if not LocalPlayerProfile.is_valid_player_id(player_id) or revision < 1 or world_id.is_empty():
		return false
	match world_kind:
		WorldKind.SETTLEMENT:
			return world_id == SETTLEMENT_WORLD_ID and region_id.is_empty() and entry_point_id.is_empty()
		WorldKind.ADVENTURE:
			return not region_id.is_empty() and not entry_point_id.is_empty() \
					and world_id == adventure_world_id(region_id)
	return false

func copy() -> PlayerWorldState:
	return create(player_id, world_kind, world_id, region_id, entry_point_id, revision)
