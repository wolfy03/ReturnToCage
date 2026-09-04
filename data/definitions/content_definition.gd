class_name ContentDefinition
extends Resource

@export var id: StringName

func validate_definition(_registry: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty():
		errors.append("content id must not be empty")
	return errors
