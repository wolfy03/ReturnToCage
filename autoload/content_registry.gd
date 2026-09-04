extends Node

signal registry_reloaded(errors: PackedStringArray)

const CONTENT_ROOT := "res://data/content"
var _definitions: Dictionary[StringName, ContentDefinition] = {}
var _load_errors := PackedStringArray()

func _ready() -> void:
	reload_all()

func reload_all() -> PackedStringArray:
	_definitions.clear()
	_load_errors.clear()
	_scan_directory(CONTENT_ROOT)
	var errors := validate_all()
	registry_reloaded.emit(errors)
	return errors

func _scan_directory(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		_load_errors.append("cannot open content directory: %s" % path)
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var full_path := path.path_join(entry)
		if directory.current_is_dir():
			_scan_directory(full_path)
		elif entry.get_extension() == "tres":
			var resource := ResourceLoader.load(full_path)
			if not resource is ContentDefinition:
				_load_errors.append("invalid content resource type: %s" % full_path)
			elif resource.id.is_empty():
				_load_errors.append("empty content id: %s" % full_path)
			elif _definitions.has(resource.id):
				_load_errors.append("duplicate content id %s: %s" % [resource.id, full_path])
			else:
				_definitions[resource.id] = resource
		entry = directory.get_next()
	directory.list_dir_end()

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
