class_name SettlementExitDefinition
extends ContentDefinition

@export var display_name: String = ""
@export var connected_region_ids: Array[StringName] = []
@export var required_flags: Array[StringName] = []
@export var prompt: String = "Enter"
@export_range(0, 10, 1) var upgrade_level: int = 0
@export var entry_point_id: StringName = &"entry"
@export var transition_key: StringName = &"fade"

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	for region_id in connected_region_ids:
		if not registry.has_id(region_id):
			errors.append("%s: missing region %s" % [id, region_id])
	return errors
