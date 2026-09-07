class_name StatBlock
extends RefCounted

signal stat_changed(stat_id: StringName, value: float)

var base_values: Dictionary[StringName, float] = {
	&"max_health": 100.0, &"move_speed": 190.0, &"attack_power": 5.0,
	&"defense": 0.0, &"max_stamina": 100.0, &"stamina_regen": 18.0
}
var _modifiers: Array[StatModifier] = []
var _update_depth: int = 0
var _pending_stats: Array[StringName] = []

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
	_notify(stat_id)

func add_modifier(modifier: StatModifier) -> void:
	_modifiers.append(modifier)
	_notify(modifier.stat_id)

func replace_source(source_id: StringName, replacements: Array[StatModifier]) -> void:
	# Observers only see the final value, never a temporary unbuffed maximum HP.
	var affected: Array[StringName] = []
	for index in range(_modifiers.size() - 1, -1, -1):
		if _modifiers[index].source_id == source_id:
			if not affected.has(_modifiers[index].stat_id):
				affected.append(_modifiers[index].stat_id)
			_modifiers.remove_at(index)
	for modifier in replacements:
		_modifiers.append(modifier)
		if not affected.has(modifier.stat_id):
			affected.append(modifier.stat_id)
	for stat_id in affected:
		_notify(stat_id)

func remove_source(source_id: StringName) -> void:
	var affected: Array[StringName] = []
	for index in range(_modifiers.size() - 1, -1, -1):
		if _modifiers[index].source_id == source_id:
			affected.append(_modifiers[index].stat_id)
			_modifiers.remove_at(index)
	for stat_id in affected:
		_notify(stat_id)

func to_dict() -> Dictionary:
	var result: Dictionary = {}
	for key in base_values:
		result[String(key)] = base_values[key]
	return result

func restore(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for key in data:
		if not SaveData.is_text(key) or not SaveData.is_number(data[key]):
			errors.append("invalid player stat in save: %s" % key)
			continue
		base_values[StringName(str(key))] = float(data[key])
	return errors

func begin_update() -> void:
	_update_depth += 1

func end_update() -> void:
	_update_depth = maxi(0, _update_depth - 1)
	if _update_depth > 0:
		return
	var pending: Array[StringName] = _pending_stats.duplicate()
	_pending_stats.clear()
	for stat_id in pending:
		stat_changed.emit(stat_id, value(stat_id))

func _notify(stat_id: StringName) -> void:
	if _update_depth > 0:
		if not _pending_stats.has(stat_id):
			_pending_stats.append(stat_id)
	else:
		stat_changed.emit(stat_id, value(stat_id))
