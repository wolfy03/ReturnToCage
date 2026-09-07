class_name HurtboxComponent
extends Area2D

@export var faction: StringName = &"neutral"
@export var health_path: NodePath
var health: HealthComponent

func _ready() -> void:
	health = get_node_or_null(health_path) as HealthComponent
	if health == null:
		push_error("HurtboxComponent requires a HealthComponent")

func receive_hit(context: DamageContext) -> bool:
	if context.source_faction == faction or health == null:
		return false
	if not context.target_factions.is_empty() and not context.target_factions.has(faction):
		return false
	if not health.receive_damage(context):
		return false
	var effects := get_parent().get_node_or_null("Effects") as EffectController
	if effects != null:
		for effect in context.hit_effects:
			effects.apply_effect(effect)
	return true
