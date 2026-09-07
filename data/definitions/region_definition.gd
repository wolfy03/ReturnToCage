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
	var errors: PackedStringArray = super.validate_definition(registry)
	for reference in major_resource_ids:
		if not registry.get_definition(reference) is ItemDefinition:
			errors.append("%s: region resource must be ItemDefinition: %s" % [id, reference])
	for reference in enemy_ids:
		if not registry.get_definition(reference) is EnemyDefinition:
			errors.append("%s: region enemy must be EnemyDefinition: %s" % [id, reference])
	for ids in [entry_point_ids, escape_point_ids]:
		var seen: Array[StringName] = []
		for point_id in ids:
			if point_id.is_empty() or seen.has(point_id):
				errors.append("%s: duplicate or empty region point %s" % [id, point_id])
			seen.append(point_id)
	var packed: PackedScene = load(scene_path) as PackedScene if not scene_path.is_empty() and ResourceLoader.exists(scene_path) else null
	if packed == null:
		errors.append("%s: region scene missing: %s" % [id, scene_path])
		return errors
	var scene: Node = packed.instantiate()
	var points: Array[RegionPoint] = []
	RegionPoint.collect(scene, points)
	var entries: Array[StringName] = []
	var escapes: Array[StringName] = []
	for point in points:
		var ids: Array[StringName] = entries if point.kind == RegionPoint.Kind.ENTRY else escapes
		if ids.has(point.point_id):
			errors.append("%s: duplicate scene point: %s" % [id, point.point_id])
		ids.append(point.point_id)
	for entry in entry_point_ids:
		if not entries.has(entry):
			errors.append("%s: missing scene entry marker %s" % [id, entry])
	for escape in escape_point_ids:
		if not escapes.has(escape):
			errors.append("%s: missing scene escape marker %s" % [id, escape])
	for entry in entries:
		if not entry_point_ids.has(entry):
			errors.append("%s: undeclared scene entry marker %s" % [id, entry])
	for escape in escapes:
		if not escape_point_ids.has(escape):
			errors.append("%s: undeclared scene escape marker %s" % [id, escape])
	scene.free()
	return errors
