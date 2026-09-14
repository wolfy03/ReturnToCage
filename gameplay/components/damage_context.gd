class_name DamageContext
extends RefCounted

var target_factions: Array[StringName] = []
var hit_effects: Array[EffectDefinition] = []

var amount: float
var damage_type: StringName
var source: Node
var source_faction: StringName
var knockback: Vector2
## Semantic hit-reaction policy, independent from physical knockback. Direct
## attacks default to hit-stun; periodic/environment ticks opt out explicitly.
var causes_hurt: bool = true
## Whether i-frames may turn this hit aside. Direct attacks are dodgeable;
## starvation and timed effects are not, so a dodge can never be used to sit out
## survival pressure. Independent from [member causes_hurt]: a hit can be
## evadable without causing hit-stun, and the reverse.
var can_be_evaded: bool = true

func _init(p_amount: float = 0.0, p_type: StringName = &"physical", p_source: Node = null, p_faction: StringName = &"neutral", p_knockback: Vector2 = Vector2.ZERO) -> void:
	amount = p_amount
	damage_type = p_type
	source = p_source
	source_faction = p_faction
	knockback = p_knockback
