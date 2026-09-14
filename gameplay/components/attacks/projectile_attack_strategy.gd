class_name ProjectileAttackStrategy
extends AttackStrategy

func execute(
	weapon: WeaponDefinition,
	attack: AttackDefinition,
	context: DamageContext,
	actor: CharacterBody2D,
	_hitbox: HitboxComponent,
	facing: float
) -> bool:
	if weapon == null or weapon.attack_scene == null or attack == null:
		return false
	var instance: Node = weapon.attack_scene.instantiate()
	if not instance is ProjectileAttack:
		instance.free()
		return false
	actor.get_parent().add_child(instance)
	instance.global_position = actor.global_position
	instance.launch(attack, context, facing)
	return true
