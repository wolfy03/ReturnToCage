class_name ActiveEffect
extends RefCounted

var definition: EffectDefinition
var remaining: float
var stacks: int = 1
var food_slot: ItemDefinition.FoodSlot = ItemDefinition.FoodSlot.NONE

func _init(p_definition: EffectDefinition, p_slot: ItemDefinition.FoodSlot) -> void:
	definition = p_definition
	remaining = p_definition.duration_seconds
	food_slot = p_slot
