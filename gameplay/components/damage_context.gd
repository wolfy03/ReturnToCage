class_name DamageContext
extends RefCounted

var amount: float
var damage_type: StringName
var source: Node
var source_faction: StringName
var knockback: Vector2

func _init(p_amount: float = 0.0, p_type: StringName = &"physical", p_source: Node = null, p_faction: StringName = &"neutral", p_knockback: Vector2 = Vector2.ZERO) -> void:
	amount = p_amount
	damage_type = p_type
	source = p_source
	source_faction = p_faction
	knockback = p_knockback
