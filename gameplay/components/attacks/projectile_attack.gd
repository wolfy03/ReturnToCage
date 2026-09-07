class_name ProjectileAttack
extends HitboxComponent

@export var speed: float = 360.0
var direction: float = 1.0
var distance_remaining: float = 0.0

func launch(weapon: WeaponDefinition, damage: DamageContext, facing: float) -> void:
	direction = signf(facing)
	distance_remaining = weapon.attack_range
	arm(damage, distance_remaining / maxf(1.0, speed))

func _physics_process(delta: float) -> void:
	var distance: float = minf(speed * delta, distance_remaining)
	position.x += direction * distance
	distance_remaining -= distance
	if distance_remaining <= 0.0:
		queue_free()
