class_name HitboxComponent
extends Area2D

var context: DamageContext
var active: bool = false

func _ready() -> void:
	area_entered.connect(_on_area_entered)

func arm(p_context: DamageContext, seconds: float = 0.12) -> void:
	context = p_context
	active = true
	monitoring = true
	await get_tree().create_timer(seconds).timeout
	active = false
	monitoring = false

func _on_area_entered(area: Area2D) -> void:
	if active and area is HurtboxComponent:
		area.receive_hit(context)
