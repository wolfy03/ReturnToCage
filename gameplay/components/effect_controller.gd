class_name EffectController
extends Node

signal effects_changed

var stats: StatBlock
var active_effects: Dictionary[StringName, ActiveEffect] = {}
var slot_effects: Dictionary[int, StringName] = {}

func configure(p_stats: StatBlock) -> void:
	stats = p_stats

func _process(delta: float) -> void:
	var expired: Array[StringName] = []
	for id in active_effects:
		var active: ActiveEffect = active_effects[id]
		if active.definition.duration_seconds > 0.0:
			active.remaining -= delta
			if active.remaining <= 0.0:
				expired.append(id)
	for id in expired:
		remove_effect(id)

func apply_item(definition: ItemDefinition) -> void:
	if definition.food_slot != ItemDefinition.FoodSlot.NONE and definition.food_slot != ItemDefinition.FoodSlot.INSTANT:
		var previous_id: StringName = slot_effects.get(definition.food_slot, &"")
		if not previous_id.is_empty() and not definition.effects.any(func(effect: EffectDefinition) -> bool: return effect.id == previous_id):
			remove_effect(previous_id)
	for effect in definition.effects:
		apply_effect(effect, definition.food_slot)

func apply_effect(definition: EffectDefinition, food_slot: ItemDefinition.FoodSlot = ItemDefinition.FoodSlot.NONE) -> void:
	var active: ActiveEffect = active_effects.get(definition.id)
	if active == null:
		active = ActiveEffect.new(definition, food_slot)
		active_effects[definition.id] = active
	else:
		match definition.stack_policy:
			EffectDefinition.StackPolicy.REPLACE:
				active.stacks = 1
				active.remaining = definition.duration_seconds
			EffectDefinition.StackPolicy.REFRESH:
				active.remaining = definition.duration_seconds
			EffectDefinition.StackPolicy.STACK:
				active.stacks = mini(definition.max_stacks, active.stacks + 1)
				active.remaining = definition.duration_seconds
	if food_slot != ItemDefinition.FoodSlot.NONE and food_slot != ItemDefinition.FoodSlot.INSTANT:
		slot_effects[food_slot] = definition.id
	_rebuild_modifier(active)
	effects_changed.emit()

func remove_effect(id: StringName) -> void:
	var active: ActiveEffect = active_effects.get(id)
	if active == null:
		return
	if stats != null:
		stats.remove_source(_source_id(id))
	if slot_effects.get(active.food_slot, &"") == id:
		slot_effects.erase(active.food_slot)
	active_effects.erase(id)
	effects_changed.emit()

func _rebuild_modifier(active: ActiveEffect) -> void:
	if stats == null or active.definition.kind != EffectDefinition.EffectKind.STAT_MODIFIER:
		return
	var source := _source_id(active.definition.id)
	stats.remove_source(source)
	var additive := active.definition.magnitude * active.stacks if active.definition.operation == EffectDefinition.Operation.ADD else 0.0
	var multiplier := pow(active.definition.magnitude, active.stacks) if active.definition.operation == EffectDefinition.Operation.MULTIPLY else 1.0
	stats.add_modifier(StatModifier.new(source, active.definition.target_stat, additive, multiplier))

func _source_id(id: StringName) -> StringName:
	return StringName("effect:%s" % id)

func descriptions() -> Array[String]:
	var result: Array[String] = []
	for active in active_effects.values():
		result.append("%s %.0fs" % [active.definition.display_name, active.remaining])
	return result
