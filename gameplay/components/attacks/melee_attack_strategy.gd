class_name MeleeAttackStrategy
extends AttackStrategy

func execute(weapon: WeaponDefinition, context: DamageContext, _actor: CharacterBody2D, hitbox: HitboxComponent, facing: float) -> bool:
	if hitbox == null:
		return false
	# Shape and facing only. How long the hitbox stays live is the ACTIVE phase,
	# which CombatComponent owns — this strategy never reads attack timing.
	hitbox.configure_range(weapon.attack_range, facing)
	hitbox.activate(context)
	return true
