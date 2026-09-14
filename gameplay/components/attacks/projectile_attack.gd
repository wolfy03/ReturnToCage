class_name ProjectileAttack
extends HitboxComponent

@export var speed: float = 360.0
var direction: float = 1.0
var distance_remaining: float = 0.0

## A projectile is live for its whole flight and frees itself when the travel
## distance runs out, so it needs no window from the attack timeline.
## Takes the executing [AttackDefinition] rather than the weapon: travel distance
## belongs to the step that fired, and a weapon may fire several different ones.
func launch(attack: AttackDefinition, damage: DamageContext, facing: float) -> void:
	direction = -1.0 if facing < 0.0 else 1.0
	distance_remaining = attack.range
	activate(damage)

func _physics_process(delta: float) -> void:
	var distance: float = minf(speed * delta, distance_remaining)
	position.x += direction * distance
	distance_remaining -= distance
	if distance_remaining <= 0.0:
		queue_free()
