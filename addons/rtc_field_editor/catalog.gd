@tool
extends RefCounted

const Preset := preload("placement_preset.gd")

var regions: Array[RegionDefinition] = []
var entries: Array[Dictionary] = []
var definitions: Dictionary[StringName, ContentDefinition] = {}
var duplicates: Dictionary[StringName, bool] = {}

func get_definition(id: StringName) -> ContentDefinition:
	return definitions.get(id) if not duplicates.has(id) else null

func rebuild(directory: EditorFileSystemDirectory) -> void:
	regions.clear()
	entries.clear()
	definitions.clear()
	duplicates.clear()
	for spec in [["Terrain", "Platform", "platform"], ["Terrain", "Obstacle", "obstacle"],
			["Region Points", "Entry", "entry"], ["Region Points", "Escape", "escape"],
			["Spawns", "Player spawn slot", "player"]]:
		_add(spec[0], spec[1], spec[2])
	_scan(directory)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return ("%s|%s|%s|%s" % [a.category, a.label.to_lower(), a.path, a.kind]) < ("%s|%s|%s|%s" % [b.category, b.label.to_lower(), b.path, b.kind]))

func _scan(directory: EditorFileSystemDirectory) -> void:
	if directory == null:
		return
	for index in directory.get_file_count():
		var path := directory.get_file_path(index)
		var type := directory.get_file_type(index)
		if path.begins_with("res://data/content/") and path.get_extension() in ["tres", "res"]:
			var definition := load(path) as ContentDefinition
			if definition == null or definition.id.is_empty():
				continue
			if definition is RegionDefinition:
				regions.append(definition)
			if definitions.has(definition.id):
				duplicates[definition.id] = true
			definitions[definition.id] = definition
			if definition is EnemyDefinition:
				_add("Enemy", definition.display_name, "enemy", path, definition.id)
			elif definition is ItemDefinition:
				_add("Gather", definition.display_name, "gather", path, definition.id)
			elif definition is ClimbableDefinition:
				_add("Climbables", definition.display_name, "climb", path, definition.id)
		elif path.begins_with("res://addons/rtc_field_editor/presets/") and path.ends_with(".tres"):
			var preset := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Preset
			if preset != null:
				_add("Presets", preset.label, "preset", path)
		elif not path.begins_with("res://tests/") and not path.begins_with("res://addons/"):
			if ClassDB.is_parent_class(type, "Texture2D"):
				_add("Decorations", path.get_file().get_basename(), "texture", path)
			elif type == "PackedScene" and path.begins_with("res://world/decorations/"):
				_add("Decorations", path.get_file().get_basename(), "scene", path)
	for index in directory.get_subdir_count():
		_scan(directory.get_subdir(index))

func _add(category: String, label: String, kind: String, path := "", id: StringName = &"") -> void:
	entries.append({"category": category, "label": label if not label.is_empty() else String(id),
		"kind": kind, "path": path, "id": id})

func search(query: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in entries:
		var text := ("%s %s %s %s" % [entry.category, entry.label, entry.id, entry.path]).to_lower()
		if text.contains(query.strip_edges().to_lower()):
			result.append(entry)
	return result
