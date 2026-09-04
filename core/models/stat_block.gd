class_name StatBlock
extends RefCounted

signal stat_changed(stat_id: StringName, value: float)

var base_values: Dictionary[StringName, float] = {
	&"max_health": 100.0, &"move_speed": 190.0, &"attack_power": 5.0,
	&"defense": 0.0, &"max_stamina": 100.0, &"stamina_regen": 18.0
}
var _modifiers: Array[StatModifier] = []

func value(stat_id: StringName) -> float:
	var additive := 0.0
	var multiplier := 1.0
	for modifier in _modifiers:
		if modifier.stat_id == stat_id:
			additive += modifier.additive
			multiplier *= modifier.multiplier
	return (base_values.get(stat_id, 0.0) + additive) * multiplier

func set_base(stat_id: StringName, amount: float) -> void:
	base_values[stat_id] = amount
	stat_changed.emit(stat_id, value(stat_id))

func add_modifier(modifier: StatModifier) -> void:
	_modifiers.append(modifier)
	stat_changed.emit(modifier.stat_id, value(modifier.stat_id))

func remove_source(source_id: StringName) -> void:
	var affected: Array[StringName] = []
	for index in range(_modifiers.size() - 1, -1, -1):
		if _modifiers[index].source_id == source_id:
			affected.append(_modifiers[index].stat_id)
			_modifiers.remove_at(index)
	for stat_id in affected:
		stat_changed.emit(stat_id, value(stat_id))

func to_dict() -> Dictionary:
	var result: Dictionary = {}
	for key in base_values:
		result[String(key)] = base_values[key]
	return result

func restore(data: Dictionary) -> void:
	for key in data:
		base_values[StringName(str(key))] = float(data[key])
