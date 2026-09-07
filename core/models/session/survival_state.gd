class_name SurvivalState
extends RefCounted

var hunger: float = 100.0
var thirst: float = 100.0
var progression_reduction: float = 0.0

func reset(start: GameStartDefinition) -> void:
	hunger = start.hunger
	thirst = start.thirst
	progression_reduction = start.progression_reduction

func to_dict() -> Dictionary:
	return {"hunger": hunger, "thirst": thirst, "progression_reduction": progression_reduction}

func restore(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	hunger = SaveData.number(data, "hunger", hunger, errors)
	thirst = SaveData.number(data, "thirst", thirst, errors)
	progression_reduction = SaveData.number(data, "progression_reduction", progression_reduction, errors)
	return errors
