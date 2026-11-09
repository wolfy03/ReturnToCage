class_name RegionDefinition
extends ContentDefinition

const FieldSceneChecks := preload("res://world/adventure/field_scene_checks.gd")

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
## Presentation-only EnvironmentDefinition path (res://world/environment/presets/...).
## Stored as a string on purpose: ContentRegistry loads every region at startup,
## including on headless servers, and must not pull background textures with it.
## Empty means the region shows only the presenter's fallback color.
@export_file("*.tres") var environment_path: String = ""
## Solid color shown before the environment preset finishes loading.
@export var environment_loading_color: Color = Color("091a24")

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	# Inspect existence and dependency metadata only; loading the preset here
	# would import its textures during headless/server content validation.
	if not environment_path.is_empty() and not ResourceLoader.exists(environment_path):
		errors.append("%s: region environment missing: %s" % [id, environment_path])
	elif not environment_path.is_empty():
		var expected_script := "res://world/environment/environment_definition.gd"
		var dependencies := ResourceLoader.get_dependencies(environment_path)
		var has_environment_script := false
		for dependency in dependencies:
			if dependency.contains(expected_script):
				has_environment_script = true
				break
		if not has_environment_script:
			errors.append("%s: region environment must be EnvironmentDefinition: %s" % [id, environment_path])
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
	errors.append_array(validate_scene(scene, registry))
	scene.free()
	return errors

## Validate authored nodes without entering the tree or starting simulation.
func validate_scene(scene: Node, registry: Node) -> PackedStringArray:
	return validate_field_nodes(self, scene, registry, false)

static func validate_field_nodes(definition: RegionDefinition, scene: Node, registry: Object, inspect_decoration_assets: bool = true) -> PackedStringArray:
	var id := definition.id if definition != null else scene.name
	var errors := PackedStringArray()
	if not scene is Node2D or not scene.has_method("configure_server_runtime"):
		errors.append("%s: invalid region scene root" % id)
	if not scene.get_node_or_null("PlayerSpawnManager") is PlayerSpawnManager:
		errors.append("%s: missing PlayerSpawnManager" % id)
	if not scene.get_node_or_null("EnemySpawnManager") is EnemySpawnManager:
		errors.append("%s: missing EnemySpawnManager" % id)
	if not scene.get_node_or_null("LootSpawnManager") is LootSpawnManager:
		errors.append("%s: missing LootSpawnManager" % id)
	if not scene.get_node_or_null("NetworkEntityRegistry") is NetworkEntityRegistry:
		errors.append("%s: missing NetworkEntityRegistry" % id)
	if definition != null and definition.entry_point_ids.is_empty():
		errors.append("%s: adventure requires at least one declared ENTRY marker" % id)
	var points: Array[RegionPoint] = []
	RegionPoint.collect(scene, points)
	var entries: Array[StringName] = []
	var escapes: Array[StringName] = []
	var entry_paths: Dictionary[StringName, NodePath] = {}
	var escape_paths: Dictionary[StringName, NodePath] = {}
	for point in points:
		var ids := entries if point.kind == RegionPoint.Kind.ENTRY else escapes
		var paths := entry_paths if point.kind == RegionPoint.Kind.ENTRY else escape_paths
		_check_unique_id(scene, point, point.point_id, "scene point", paths, errors)
		ids.append(point.point_id)
	if definition != null:
		for entry in definition.entry_point_ids:
			if not entries.has(entry):
				errors.append("%s: missing scene entry marker %s" % [id, entry])
		for escape in definition.escape_point_ids:
			if not escapes.has(escape):
				errors.append("%s: missing scene escape marker %s" % [id, escape])
		for entry in entries:
			if not definition.entry_point_ids.has(entry):
				errors.append("%s: undeclared scene entry marker %s at %s" % [id, entry, entry_paths.get(entry, NodePath("."))])
		for escape in escapes:
			if not definition.escape_point_ids.has(escape):
				errors.append("%s: undeclared scene escape marker %s at %s" % [id, escape, escape_paths.get(escape, NodePath("."))])
	var spawn_ids: Dictionary[StringName, NodePath] = {}
	var gather_ids: Dictionary[StringName, NodePath] = escape_paths.duplicate()
	for marker in scene.find_children("*", "Marker2D", true, false):
		var path := scene.get_path_to(marker)
		if marker is FieldEnemySpawnPoint:
			_check_unique_id(scene, marker, marker.spawn_id, "enemy spawn ID", spawn_ids, errors)
			if not registry.get_definition(marker.enemy_id) is EnemyDefinition:
				errors.append("%s: invalid spawn enemy ID: %s" % [path, marker.enemy_id])
		elif marker is FieldGatherPoint:
			_check_unique_id(scene, marker, marker.interaction_id, "gather ID", gather_ids, errors)
			if not registry.get_definition(marker.item_id) is ItemDefinition:
				errors.append("%s: invalid gather item ID: %s" % [path, marker.item_id])
			if marker.amount <= 0:
				errors.append("%s: nonpositive gather amount: %s" % [path, marker.interaction_id])
	errors.append_array(FieldSceneChecks.validate(scene, inspect_decoration_assets))
	return errors

static func _check_unique_id(root: Node, node: Node, key: StringName, label: String,
		seen: Dictionary[StringName, NodePath], errors: PackedStringArray) -> void:
	var path := root.get_path_to(node)
	if key.is_empty():
		errors.append("duplicate or empty %s: empty at %s" % [label, path])
	elif seen.has(key):
		errors.append("duplicate or empty %s: %s at %s and %s" % [label, key, seen[key], path])
	else:
		seen[key] = path
