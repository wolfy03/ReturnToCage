class_name MeleeAttackStrategy
extends AttackStrategy

func execute(weapon: WeaponDefinition, context: DamageContext, _actor: CharacterBody2D, hitbox: HitboxComponent, facing: float) -> bool:
	if hitbox == null:
		return false
	# Shape and facing only. How long the hitbox stays live is the ACTIVE phase,
	# which CombatComponent owns — this strategy never reads attack timing.
	var attack_definition := weapon.attack_definition
	if attack_definition == null or not hitbox.configure_geometry(
		attack_definition.hitbox_size,
		attack_definition.hitbox_offset,
		facing
	):
		return false
	hitbox.activate(context)
	return true
