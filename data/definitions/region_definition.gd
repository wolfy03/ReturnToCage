class_name RegionDefinition
extends ContentDefinition

@export var display_name: String = ""
@export_multiline var description: String = ""
@export_file("*.tscn") var scene_path: String = ""
@export_range(0, 10, 1) var danger_level: int = 1
@export var entry_point_ids: Array[StringName] = []
@export var escape_point_ids: Array[StringName] = []
@export var major_resource_ids: Array[StringName] = []
@export var enemy_ids: Array[StringName] = []
@export var unlock_flags: Array[StringName] = []
@export var recommended_gear: String = ""
@export var allow_return_item: bool = true

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		errors.append("%s: region scene does not exist: %s" % [id, scene_path])
	for reference in major_resource_ids + enemy_ids:
		if not registry.has_id(reference):
			errors.append("%s: missing region reference %s" % [id, reference])
	return errors
