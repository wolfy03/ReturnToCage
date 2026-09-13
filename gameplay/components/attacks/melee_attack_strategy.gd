class_name MeleeAttackStrategy
extends AttackStrategy

func execute(weapon: WeaponDefinition, context: DamageContext, _actor: CharacterBody2D, hitbox: HitboxComponent, facing: float) -> bool:
	if hitbox == null:
		return false
	if weapon.attack_definition == null:
		return false
	hitbox.configure_range(weapon.attack_range, facing)
	# The armed window is the weapon's ACTIVE phase; there is no default here.
	hitbox.arm(context, weapon.attack_definition.active_seconds)
	return true
