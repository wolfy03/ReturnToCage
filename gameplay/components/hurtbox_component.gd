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
	return health.receive_damage(context)
