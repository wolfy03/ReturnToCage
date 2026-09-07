class_name AdventureRulesSnapshot
extends RefCounted
## Callers receive copies; the captured rules cannot be mutated through the API.
var _definition: DifficultyDefinition

func _init(effective: DifficultyDefinition) -> void:
	_definition = effective.duplicate(true) as DifficultyDefinition

func effective() -> DifficultyDefinition:
	return _definition.duplicate(true) as DifficultyDefinition
