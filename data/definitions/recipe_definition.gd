class_name RecipeDefinition
extends ContentDefinition

@export var input_item_ids: Array[StringName] = []
@export var input_amounts: Array[int] = []
@export var output_item_ids: Array[StringName] = []
@export var output_amounts: Array[int] = []
@export var required_facility_id: StringName
@export_range(0, 99, 1) var required_facility_level: int = 0
@export_range(0.0, 3600.0, 0.1) var craft_seconds: float = 0.0
@export var unlock_flags: Array[StringName] = []

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if input_item_ids.size() != input_amounts.size() or output_item_ids.size() != output_amounts.size():
		errors.append("%s: recipe item and amount arrays differ" % id)
	for item_id in input_item_ids + output_item_ids:
		if not registry.has_id(item_id):
			errors.append("%s: missing item reference %s" % [id, item_id])
	if not required_facility_id.is_empty() and not registry.has_id(required_facility_id):
		errors.append("%s: missing facility %s" % [id, required_facility_id])
	return errors
