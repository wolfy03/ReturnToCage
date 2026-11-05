extends Node

signal registry_reloaded(errors: PackedStringArray)

const CONTENT_ROOT := "res://data/content"
const REQUIRED_START_ID: StringName = &"default_game_start"
var _definitions: Dictionary[StringName, ContentDefinition] = {}
var _definition_paths: Dictionary[StringName, String] = {}
var _load_errors := PackedStringArray()

func _ready() -> void:
	var errors := reload_all()
	print("[CONTENT] Registered %d definitions from %s (%s)" % [
		_definitions.size(), CONTENT_ROOT, "editor" if OS.has_feature("editor") else "export"])
	for error in errors:
		push_error("[CONTENT] %s" % error)

func reload_all() -> PackedStringArray:
	_definitions.clear()
	_definition_paths.clear()
	_load_errors.clear()
	_scan_directory(CONTENT_ROOT)
	var errors := validate_all()
	registry_reloaded.emit(errors)
	return errors

func _scan_directory(path: String) -> void:
	# Export remaps .tres to binary resources. ResourceLoader enumerates logical
	# resource names in both editor filesystems and exported packs.
	var entries := ResourceLoader.list_directory(path)
	entries.sort()
	if entries.is_empty():
		_load_errors.append("content directory empty or unavailable: %s; check Export resource filters" % path)
		return
	for entry in entries:
		var full_path := path.path_join(entry)
		if entry.ends_with("/"):
			_scan_directory(full_path)
		elif entry.get_extension().to_lower() in ["tres", "res"]:
			_register_resource(full_path, ResourceLoader.load(full_path))

func _register_resource(path: String, resource: Resource) -> void:
	if resource == null:
		_load_errors.append("cannot load content resource: %s" % path)
	elif not resource is ContentDefinition:
		_load_errors.append("invalid content resource type (expected ContentDefinition): %s" % path)
	elif resource.id.is_empty():
		_load_errors.append("empty content id: %s" % path)
	elif _definitions.has(resource.id):
		_load_errors.append("duplicate content id %s: %s (first registered from %s)" % [
			resource.id, path, _definition_paths.get(resource.id, "unknown")])
	else:
		_definitions[resource.id] = resource
		_definition_paths[resource.id] = path

func get_definition(id: StringName) -> ContentDefinition:
	return _definitions.get(id)

func get_item(id: StringName) -> ItemDefinition:
	return _definitions.get(id) as ItemDefinition

func has_id(id: StringName) -> bool:
	return _definitions.has(id)

func all_definitions() -> Array[ContentDefinition]:
	var result: Array[ContentDefinition] = []
	for definition in _definitions.values():
		result.append(definition)
	return result

func validate_all() -> PackedStringArray:
	var errors := _load_errors.duplicate()
	if not get_definition(REQUIRED_START_ID) is GameStartDefinition:
		errors.append("Missing or invalid GameStartDefinition: %s under %s" % [REQUIRED_START_ID, CONTENT_ROOT])
	if not get_definition(&"normal") is DifficultyDefinition:
		errors.append("Missing or invalid DifficultyDefinition: normal under %s" % CONTENT_ROOT)
	for definition in _definitions.values():
		errors.append_array(definition.validate_definition(self))
	return errors

func validate_batch(resources: Array[ContentDefinition]) -> PackedStringArray:
	var errors := PackedStringArray()
	var seen: Dictionary[StringName, bool] = {}
	for definition in resources:
		if definition.id.is_empty():
			errors.append("empty content id in batch")
		elif seen.has(definition.id):
			errors.append("duplicate content id in batch: %s" % definition.id)
		else:
			seen[definition.id] = true
		errors.append_array(definition.validate_definition(self))
	return errors
