class_name AttackStrategy
extends RefCounted
## How one attack step reaches the world.
##
## The current [AttackDefinition] is passed in rather than looked up from the
## weapon: a weapon owns a whole combo, so "the weapon's attack" is no longer a
## well-defined thing. Only the caller driving the timeline knows which step is
## executing, so only the caller may say.

func execute(
	_weapon: WeaponDefinition,
	_attack: AttackDefinition,
	_context: DamageContext,
	_actor: CharacterBody2D,
	_hitbox: HitboxComponent,
	_facing: float
) -> bool:
	return false
