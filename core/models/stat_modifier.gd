class_name StatModifier
extends RefCounted

var source_id: StringName
var stat_id: StringName
var additive: float
var multiplier: float

func _init(p_source_id: StringName, p_stat_id: StringName, p_additive: float = 0.0, p_multiplier: float = 1.0) -> void:
	source_id = p_source_id
	stat_id = p_stat_id
	additive = p_additive
	multiplier = p_multiplier
