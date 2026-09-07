class_name MeleeAttackStrategy
extends AttackStrategy

func execute(weapon: WeaponDefinition, context: DamageContext, _actor: CharacterBody2D, hitbox: HitboxComponent, facing: float) -> bool:
	if hitbox == null:
		return false
	hitbox.configure_range(weapon.attack_range, facing)
	hitbox.arm(context)
	return true
