class_name SettlementExitDefinition
extends ContentDefinition

@export var development_locked: bool = false
@export var required_facility_levels: Dictionary[StringName, int] = {}
@export var display_name: String = ""
@export var connected_region_ids: Array[StringName] = []
@export var required_flags: Array[StringName] = []
@export var prompt: String = "Enter"
@export_range(0, 10, 1) var upgrade_level: int = 0
@export var entry_point_id: StringName = &"entry"
@export var transition_key: StringName = &"fade"

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if connected_region_ids.is_empty() and not development_locked:
		errors.append("%s: implemented exit has no connected region" % id)
	for region_id in connected_region_ids:
		var region := registry.get_definition(region_id) as RegionDefinition
		if region == null:
			errors.append("%s: missing or mistyped region %s" % [id, region_id])
		elif not region.entry_point_ids.has(entry_point_id):
			errors.append("%s: entry point %s missing in region %s" % [id, entry_point_id, region_id])
	for facility_id in required_facility_levels:
		if not registry.get_definition(facility_id) is FacilityDefinition or required_facility_levels[facility_id] < 0:
			errors.append("%s: invalid required facility %s" % [id, facility_id])
	return errors
