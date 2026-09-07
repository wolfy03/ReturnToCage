class_name ActiveEffect
extends RefCounted

var definition: EffectDefinition
var source_id: StringName
var applied_by: StringName = &"effect"
var modifier_source: StringName
var tick_elapsed: float = 0.0
var persistent: bool = false
var remaining: float
var stacks: int = 1
var food_slot: ItemDefinition.FoodSlot = ItemDefinition.FoodSlot.NONE

func _init(p_definition: EffectDefinition, p_slot: ItemDefinition.FoodSlot) -> void:
	definition = p_definition
	remaining = p_definition.duration_seconds
	food_slot = p_slot
