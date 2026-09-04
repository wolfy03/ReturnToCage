class_name FacilityDefinition
extends ContentDefinition

@export var display_name: String = ""
@export_multiline var description: String = ""
@export_range(1, 20, 1) var max_level: int = 1
@export var levels: Array[FacilityLevelDefinition] = []
@export var prerequisite_facility_ids: Array[StringName] = []
@export var prerequisite_quest_ids: Array[StringName] = []

func get_level_data(level: int) -> FacilityLevelDefinition:
	for data in levels:
		if data.level == level:
			return data
	return null

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if levels.is_empty():
		errors.append("%s: facility has no level data" % id)
	for level_data in levels:
		if level_data.cost_item_ids.size() != level_data.cost_amounts.size():
			errors.append("%s: level %d cost arrays differ" % [id, level_data.level])
		for item_id in level_data.cost_item_ids:
			if not registry.has_id(item_id):
				errors.append("%s: missing cost item %s" % [id, item_id])
	for prerequisite in prerequisite_facility_ids:
		if not registry.has_id(prerequisite):
			errors.append("%s: missing prerequisite facility %s" % [id, prerequisite])
	for quest_id in prerequisite_quest_ids:
		if not registry.has_id(quest_id):
			errors.append("%s: missing prerequisite quest %s" % [id, quest_id])
	return errors
