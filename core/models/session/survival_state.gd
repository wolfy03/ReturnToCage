class_name SurvivalState
extends RefCounted

var _max_hunger: float = 100.0
var _max_thirst: float = 100.0

var hunger: float = 100.0
var thirst: float = 100.0
var progression_reduction: float = 0.0

func reset(start: GameStartDefinition) -> void:
	if start.survival_config != null:
		_max_hunger = start.survival_config.max_hunger
		_max_thirst = start.survival_config.max_thirst
	hunger = start.hunger
	thirst = start.thirst
	progression_reduction = start.progression_reduction

func to_dict() -> Dictionary:
	return {"hunger": hunger, "thirst": thirst, "progression_reduction": progression_reduction}

func restore(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	hunger = SaveData.clamped_number(data, "hunger", hunger, 0.0, _max_hunger, errors)
	thirst = SaveData.clamped_number(data, "thirst", thirst, 0.0, _max_thirst, errors)
	progression_reduction = SaveData.clamped_number(data, "progression_reduction", progression_reduction, 0.0, 0.9, errors)
	return errors
