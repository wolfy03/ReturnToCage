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

func detached_copy() -> ActiveEffect:
	var copy := ActiveEffect.new(definition, food_slot)
	copy.source_id = source_id
	copy.applied_by = applied_by
	copy.modifier_source = modifier_source
	copy.tick_elapsed = tick_elapsed
	copy.persistent = persistent
	copy.remaining = remaining
	copy.stacks = stacks
	return copy

func _init(p_definition: EffectDefinition, p_slot: ItemDefinition.FoodSlot) -> void:
	definition = p_definition
	remaining = p_definition.duration_seconds
	food_slot = p_slot
