class_name EffectRuntimeModel
extends RefCounted

signal changed
signal periodic(amount: float, damage: bool)

var paused: bool = false
var stats: StatBlock
var active_effects: Dictionary[StringName, ActiveEffect] = {}

func _init(p_stats: StatBlock = null) -> void:
	stats = p_stats

func apply_item(item: ItemDefinition) -> void:
	if item.food_slot != ItemDefinition.FoodSlot.NONE and item.food_slot != ItemDefinition.FoodSlot.INSTANT:
		for key in active_effects.keys():
			var active: ActiveEffect = active_effects[key]
			if not active.persistent and active.food_slot == item.food_slot and not item.effects.any(func(effect: EffectDefinition) -> bool: return effect.id == active.definition.id):
				remove_effect(key)
	for effect in item.effects:
		apply_effect(effect, item.food_slot, &"", false, item.id)

func apply_effect(definition: EffectDefinition, slot: ItemDefinition.FoodSlot = ItemDefinition.FoodSlot.NONE, source: StringName = &"", persistent: bool = false, applied_by: StringName = &"effect") -> void:
	if definition == null:
		return
	var key: StringName = definition.id if source.is_empty() else StringName("%s/%s" % [source, definition.id])
	var active: ActiveEffect = active_effects.get(key)
	if active == null:
		active = ActiveEffect.new(definition, slot)
		active.source_id = source
		active.modifier_source = StringName("effect:%s" % key)
		active.persistent = persistent
		active_effects[key] = active
	else:
		match definition.stack_policy:
			EffectDefinition.StackPolicy.REPLACE:
				active.stacks = 1
				active.tick_elapsed = 0.0
			EffectDefinition.StackPolicy.STACK:
				active.stacks = mini(definition.max_stacks, active.stacks + 1)
		active.remaining = definition.duration_seconds
		active.food_slot = slot
	active.applied_by = source if persistent else applied_by
	_rebuild(active)
	changed.emit()

func tick(delta: float) -> void:
	if paused:
		return
	for key in active_effects.keys():
		if paused:
			break
		var active: ActiveEffect = active_effects.get(key)
		if active == null:
			continue
		var step: float = delta if active.persistent or active.definition.duration_seconds <= 0.0 else minf(delta, active.remaining)
		if active.definition.kind != EffectDefinition.EffectKind.STAT_MODIFIER:
			active.tick_elapsed += step
			var interval: float = maxf(0.01, active.definition.tick_interval_seconds)
			while not paused and active.tick_elapsed + 0.000001 >= interval:
				active.tick_elapsed -= interval
				periodic.emit(active.definition.magnitude * active.stacks, active.definition.kind == EffectDefinition.EffectKind.PERIODIC_DAMAGE)
		if not active.persistent and active.definition.duration_seconds > 0.0:
			active.remaining = maxf(0.0, active.remaining - delta)
			if active.remaining <= 0.0:
				remove_effect(key)

func remove_effect(key: StringName) -> void:
	var active: ActiveEffect = active_effects.get(key)
	if active == null:
		return
	if stats != null:
		stats.remove_source(active.modifier_source)
	active_effects.erase(key)
	changed.emit()

func remove_source(source: StringName) -> void:
	for key in active_effects.keys():
		if active_effects[key].source_id == source:
			remove_effect(key)

func _rebuild(active: ActiveEffect) -> void:
	if stats == null or active.definition.kind != EffectDefinition.EffectKind.STAT_MODIFIER:
		return
	var additive: float = active.definition.magnitude * active.stacks if active.definition.operation == EffectDefinition.Operation.ADD else 0.0
	var multiplier: float = pow(active.definition.magnitude, active.stacks) if active.definition.operation == EffectDefinition.Operation.MULTIPLY else 1.0
	stats.replace_source(active.modifier_source, [StatModifier.new(active.modifier_source, active.definition.target_stat, additive, multiplier)])

func descriptions() -> Array[String]:
	var result: Array[String] = []
	for active in active_effects.values():
		result.append("%s %s" % [active.definition.display_name, "equipped" if active.persistent else "%.0fs" % active.remaining])
	return result

func to_array() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for active in active_effects.values():
		if not active.persistent:
			result.append({"effect_id": String(active.definition.id), "remaining": active.remaining, "stacks": active.stacks, "food_slot": active.food_slot, "source_id": String(active.source_id), "applied_by": String(active.applied_by), "tick_elapsed": active.tick_elapsed})
	return result

func restore(data: Array, resolver: Callable) -> PackedStringArray:
	paused = false
	var errors := PackedStringArray()
	var seen: Array[StringName] = []
	for key in active_effects.keys():
		remove_effect(key)
	for raw in data:
		if not raw is Dictionary:
			errors.append("invalid active effect record")
			continue
		var id := StringName(SaveData.text_value(raw, "effect_id", "", errors))
		var definition: EffectDefinition = resolver.call(id) as EffectDefinition
		if definition == null:
			errors.append("unknown saved effect: %s" % id)
			continue
		var remaining: float = SaveData.number(raw, "remaining", definition.duration_seconds, errors)
		if definition.duration_seconds > 0.0 and remaining <= 0.0:
			if remaining < 0.0:
				errors.append("negative effect remaining time ignored: %s" % id)
			continue
		var slot: int = int(SaveData.clamped_number(raw, "food_slot", 0, 0, ItemDefinition.FoodSlot.INSTANT, errors))
		var source := StringName(SaveData.text_value(raw, "source_id", "", errors))
		var key: StringName = id if source.is_empty() else StringName("%s/%s" % [source, id])
		if seen.has(key):
			errors.append("duplicate active effect ignored: %s" % key)
			continue
		seen.append(key)
		apply_effect(definition, slot as ItemDefinition.FoodSlot, source)
		var active: ActiveEffect = active_effects[key]
		active.applied_by = StringName(SaveData.text_value(raw, "applied_by", "effect", errors))
		active.remaining = minf(remaining, definition.duration_seconds) if definition.duration_seconds > 0.0 else 0.0
		if remaining != active.remaining:
			errors.append("effect remaining time clamped: %s" % id)
		active.stacks = int(SaveData.clamped_number(raw, "stacks", 1, 1, definition.max_stacks, errors))
		active.tick_elapsed = SaveData.clamped_number(raw, "tick_elapsed", 0.0, 0.0, definition.tick_interval_seconds, errors)
		_rebuild(active)
	return errors
