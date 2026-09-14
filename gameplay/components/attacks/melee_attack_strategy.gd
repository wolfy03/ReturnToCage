class_name MeleeAttackStrategy
extends AttackStrategy

func execute(
	_weapon: WeaponDefinition,
	attack: AttackDefinition,
	context: DamageContext,
	_actor: CharacterBody2D,
	hitbox: HitboxComponent,
	facing: float
) -> bool:
	if hitbox == null or attack == null:
		return false
	# Shape and facing only, read from the step that is executing. How long the
	# hitbox stays live is the ACTIVE phase, which CombatComponent owns — this
	# strategy never reads attack timing.
	if not hitbox.configure_geometry(attack.hitbox_size, attack.hitbox_offset, facing):
		return false
	hitbox.activate(context)
	return true
